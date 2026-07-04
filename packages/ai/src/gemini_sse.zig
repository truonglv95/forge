const std = @import("std");
const provider_mod = @import("provider.zig");

pub const ChunkKind = enum {
    thought,
    text,
};

pub const Callbacks = struct {
    on_chunk: ?*const fn (?*anyopaque, ChunkKind, []const u8) void = null,
    context: ?*anyopaque = null,
};

const StreamEvent = struct {
    candidates: ?[]Candidate = null,
    usageMetadata: ?UsageMetadata = null,
    @"error": ?ApiError = null,

    const Candidate = struct {
        content: ?struct {
            parts: ?[]Part = null,
        } = null,
    };

    const Part = struct {
        text: ?[]const u8 = null,
        thought: ?bool = null,
    };

    const UsageMetadata = struct {
        promptTokenCount: ?i64 = null,
        candidatesTokenCount: ?i64 = null,
        totalTokenCount: ?i64 = null,
    };

    const ApiError = struct {
        message: ?[]const u8 = null,
        status: ?[]const u8 = null,
    };
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,
    assembled: std.ArrayList(u8) = .empty,
    callbacks: Callbacks,
    writer_buffer: [4096]u8 = undefined,
    writer: std.Io.Writer,
    terminal_error: ?provider_mod.ProviderError = null,
    latest_usage: provider_mod.TokenUsage = .{},

    pub fn init(allocator: std.mem.Allocator, callbacks: Callbacks) Parser {
        var self = Parser{
            .allocator = allocator,
            .callbacks = callbacks,
            .writer = undefined,
        };
        self.writer = std.Io.Writer{
            .buffer = self.writer_buffer[0..],
            .vtable = &sse_writer_vtable,
        };
        return self;
    }

    pub fn deinit(self: *Parser) void {
        self.pending.deinit(self.allocator);
        self.assembled.deinit(self.allocator);
    }

    pub fn ioWriter(self: *Parser) *std.Io.Writer {
        sse_active_parser = self;
        return &self.writer;
    }

    pub fn releaseWriter(self: *Parser) void {
        if (sse_active_parser == self) sse_active_parser = null;
    }

    fn flushWriterBuffer(self: *Parser, w: *std.Io.Writer) ParseError!void {
        if (w.end == 0) return;
        try self.feed(w.buffer[0..w.end]);
        w.end = 0;
    }

    pub fn finish(self: *Parser) ParseError!void {
        try self.flushWriterBuffer(&self.writer);
        if (self.pending.items.len > 0) {
            self.feed(self.pending.items) catch return error.MalformedResponse;
            self.pending.clearRetainingCapacity();
        }
        if (self.terminal_error) |err| switch (err) {
            error.AuthenticationFailed => return error.AuthenticationFailed,
            error.RateLimitExceeded => return error.RateLimitExceeded,
            else => return error.MalformedResponse,
        };
    }

    pub fn assembledText(self: *const Parser) []const u8 {
        return self.assembled.items;
    }

    fn feed(self: *Parser, bytes: []const u8) ParseError!void {
        self.pending.appendSlice(self.allocator, bytes) catch return error.MalformedResponse;
        while (true) {
            const delim = std.mem.indexOf(u8, self.pending.items, "\n\n") orelse
                std.mem.indexOf(u8, self.pending.items, "\r\n\r\n");
            if (delim == null) break;
            const line_end = delim.?;
            const raw_line = std.mem.trim(u8, self.pending.items[0..line_end], "\r\n");
            var consume: usize = line_end + 2;
            if (line_end < self.pending.items.len and self.pending.items[line_end] == '\r') {
                consume = line_end + 4;
            }
            const rest = self.allocator.dupe(u8, self.pending.items[consume..]) catch return error.MalformedResponse;
            defer self.allocator.free(rest);
            self.pending.clearRetainingCapacity();
            self.pending.appendSlice(self.allocator, rest) catch return error.MalformedResponse;
            if (raw_line.len == 0) continue;
            if (!std.mem.startsWith(u8, raw_line, "data:")) continue;
            const payload = std.mem.trim(u8, raw_line["data:".len..], " ");
            if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;
            try self.handlePayload(payload);
        }
    }

    fn handlePayload(self: *Parser, payload: []const u8) ParseError!void {
        var parsed = std.json.parseFromSlice(StreamEvent, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        if (parsed.value.@"error") |api_err| {
            if (api_err.status) |status| {
                if (std.mem.eql(u8, status, "UNAUTHENTICATED")) {
                    self.terminal_error = provider_mod.ProviderError.AuthenticationFailed;
                    return;
                }
                if (std.mem.eql(u8, status, "RESOURCE_EXHAUSTED")) {
                    self.terminal_error = provider_mod.ProviderError.RateLimitExceeded;
                    return;
                }
            }
            self.terminal_error = provider_mod.ProviderError.MalformedResponse;
            return;
        }

        if (parsed.value.usageMetadata) |usage| {
            self.latest_usage = .{
                .prompt_tokens = if (usage.promptTokenCount) |v| @intCast(v) else self.latest_usage.prompt_tokens,
                .completion_tokens = if (usage.candidatesTokenCount) |v| @intCast(v) else self.latest_usage.completion_tokens,
                .total_tokens = if (usage.totalTokenCount) |v| @intCast(v) else self.latest_usage.total_tokens,
            };
        }

        const candidates = parsed.value.candidates orelse return;
        for (candidates) |candidate| {
            const content = candidate.content orelse continue;
            const parts = content.parts orelse continue;
            for (parts) |part| {
                const text = part.text orelse continue;
                const kind: ChunkKind = if (part.thought == true) .thought else .text;
                if (kind == .text) self.assembled.appendSlice(self.allocator, text) catch return error.MalformedResponse;
                if (self.callbacks.on_chunk) |callback| callback(self.callbacks.context, kind, text);
            }
        }
    }

    fn writerDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self = sse_active_parser orelse return error.WriteFailed;
        if (data.len == 0) return 0;

        self.flushWriterBuffer(w) catch {
            self.terminal_error = provider_mod.ProviderError.MalformedResponse;
            return error.WriteFailed;
        };

        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            if (slice.len == 0) continue;
            self.feed(slice) catch {
                self.terminal_error = provider_mod.ProviderError.MalformedResponse;
                return error.WriteFailed;
            };
            total += slice.len;
        }

        const pattern = data[data.len - 1];
        if (pattern.len == 0) return total;

        var i: usize = 0;
        while (i < splat) : (i += 1) {
            self.feed(pattern) catch {
                self.terminal_error = provider_mod.ProviderError.MalformedResponse;
                return error.WriteFailed;
            };
            total += pattern.len;
        }
        return total;
    }

    fn writerFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self = sse_active_parser orelse return;
        self.flushWriterBuffer(w) catch return error.WriteFailed;
    }

    fn writerRebase(w: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        const self = sse_active_parser orelse return error.WriteFailed;
        self.flushWriterBuffer(w) catch return error.WriteFailed;
        if (w.buffer.len - w.end >= minimum_len) return;
        const preserved_head = w.end -| preserve;
        const preserved_len = w.end - preserved_head;
        if (preserved_len > 0) {
            @memmove(w.buffer[0..preserved_len], w.buffer[preserved_head..w.end]);
        }
        w.end = preserved_len;
    }
};

const sse_writer_vtable = std.Io.Writer.VTable{
    .drain = Parser.writerDrain,
    .flush = Parser.writerFlush,
    .rebase = Parser.writerRebase,
};

threadlocal var sse_active_parser: ?*Parser = null;

pub const ParseError = error{
    AuthenticationFailed,
    RateLimitExceeded,
    MalformedResponse,
};

test "Parser extracts thought and text chunks" {
    const allocator = std.testing.allocator;
    var thought_chunks: std.ArrayList([]const u8) = .empty;
    defer {
        for (thought_chunks.items) |item| allocator.free(item);
        thought_chunks.deinit(allocator);
    }
    var text_chunks: std.ArrayList([]const u8) = .empty;
    defer {
        for (text_chunks.items) |item| allocator.free(item);
        text_chunks.deinit(allocator);
    }

    const Context = struct {
        thought_chunks: *std.ArrayList([]const u8),
        text_chunks: *std.ArrayList([]const u8),
        allocator: std.mem.Allocator,

        fn onChunk(ctx: ?*anyopaque, kind: ChunkKind, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const owned = self.allocator.dupe(u8, chunk) catch return;
            switch (kind) {
                .thought => self.thought_chunks.append(self.allocator, owned) catch {},
                .text => self.text_chunks.append(self.allocator, owned) catch {},
            }
        }
    };

    var ctx = Context{
        .thought_chunks = &thought_chunks,
        .text_chunks = &text_chunks,
        .allocator = allocator,
    };

    var parser = Parser.init(allocator, .{
        .on_chunk = Context.onChunk,
        .context = &ctx,
    });
    defer parser.deinit();

    const fixture =
        \\data: {"candidates":[{"content":{"parts":[{"text":"plan step","thought":true}]}}]}
        \\
        \\data: {"candidates":[{"content":{"parts":[{"text":"{\"ok\":true}"}]}}]}
        \\
    ;
    try parser.feed(fixture);
    try parser.finish();
    parser.releaseWriter();
    try std.testing.expectEqual(@as(usize, 1), thought_chunks.items.len);
    try std.testing.expectEqual(@as(usize, 1), text_chunks.items.len);
    try std.testing.expectEqualStrings("{\"ok\":true}", parser.assembledText());
}

test "Parser io writer uses stable vtable" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();
    defer parser.releaseWriter();

    const fixture =
        \\data: {"candidates":[{"content":{"parts":[{"text":"{\"ok\":true}"}]}}]}
        \\
    ;
    try parser.ioWriter().writeAll(fixture);
    try parser.finish();
    try std.testing.expectEqualStrings("{\"ok\":true}", parser.assembledText());
}

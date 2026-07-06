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
        functionCall: ?struct {
            name: ?[]const u8 = null,
            args: ?std.json.Value = null,
        } = null,
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
    writer_initialized: bool = false,
    terminal_error: ?provider_mod.ProviderError = null,
    latest_usage: provider_mod.TokenUsage = .{},
    tool_call_name: ?[]u8 = null,
    tool_call_args_json: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, callbacks: Callbacks) Parser {
        return Parser{
            .allocator = allocator,
            .callbacks = callbacks,
            .writer = undefined,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.pending.deinit(self.allocator);
        self.assembled.deinit(self.allocator);
        if (self.tool_call_name) |name| self.allocator.free(name);
        if (self.tool_call_args_json) |args| self.allocator.free(args);
    }

    pub fn takeToolCall(self: *Parser) ?struct {
        name: []u8,
        args_json: []u8,
    } {
        const name = self.tool_call_name orelse return null;
        const args_json = self.tool_call_args_json orelse return null;
        self.tool_call_name = null;
        self.tool_call_args_json = null;
        return .{ .name = name, .args_json = args_json };
    }

    pub fn ioWriter(self: *Parser) *std.Io.Writer {
        self.writer = std.Io.Writer{
            .buffer = self.writer_buffer[0..],
            .vtable = &sse_writer_vtable,
        };
        self.writer_initialized = true;
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
        if (self.writer_initialized) try self.flushWriterBuffer(&self.writer);
        if (self.pending.items.len > 0) {
            const last_event = self.allocator.dupe(u8, std.mem.trim(u8, self.pending.items, "\r\n")) catch return error.MalformedResponse;
            defer self.allocator.free(last_event);
            self.pending.clearRetainingCapacity();
            if (last_event.len > 0) try self.handleEvent(last_event);
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
            const raw_line = self.allocator.dupe(u8, std.mem.trim(u8, self.pending.items[0..line_end], "\r\n")) catch return error.MalformedResponse;
            defer self.allocator.free(raw_line);
            var consume: usize = line_end + 2;
            if (line_end < self.pending.items.len and self.pending.items[line_end] == '\r') {
                consume = line_end + 4;
            }
            const rest = self.allocator.dupe(u8, self.pending.items[consume..]) catch return error.MalformedResponse;
            defer self.allocator.free(rest);
            self.pending.clearRetainingCapacity();
            self.pending.appendSlice(self.allocator, rest) catch return error.MalformedResponse;
            if (raw_line.len == 0) continue;
            try self.handleEvent(raw_line);
        }
    }

    fn handleEvent(self: *Parser, raw_line: []const u8) ParseError!void {
        if (!std.mem.startsWith(u8, raw_line, "data:")) return;

        var payload_buf: std.ArrayList(u8) = .empty;
        defer payload_buf.deinit(self.allocator);

        var line_it = std.mem.splitScalar(u8, raw_line, '\n');
        while (line_it.next()) |line| {
            var l = std.mem.trim(u8, line, "\r");
            if (std.mem.startsWith(u8, l, "data:")) {
                l = std.mem.trim(u8, l["data:".len..], " ");
            }
            if (l.len > 0) payload_buf.appendSlice(self.allocator, l) catch return error.MalformedResponse;
        }

        const payload = payload_buf.items;
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) return;
        try self.handlePayload(payload);
    }

    fn handlePayload(self: *Parser, payload: []const u8) ParseError!void {
        var parsed = std.json.parseFromSlice(StreamEvent, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse SSE payload: {any}, payload: {s}", .{ err, payload });
            return;
        };
        defer parsed.deinit();

        if (parsed.value.@"error") |api_err| {
            if (api_err.message) |msg| {
                std.log.err("Gemini API Error: {s} (status: {?s})", .{ msg, api_err.status });
            } else {
                std.log.err("Gemini API Error: Unknown (status: {?s})", .{api_err.status});
            }
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
                if (part.functionCall) |fc| {
                    const name = fc.name orelse continue;
                    if (self.tool_call_name) |owned| self.allocator.free(owned);
                    if (self.tool_call_args_json) |owned| self.allocator.free(owned);
                    self.tool_call_name = self.allocator.dupe(u8, name) catch return error.MalformedResponse;
                    self.tool_call_args_json = if (fc.args) |args_val|
                        std.json.Stringify.valueAlloc(self.allocator, args_val, .{}) catch return error.MalformedResponse
                    else
                        self.allocator.dupe(u8, "{}") catch return error.MalformedResponse;
                    continue;
                }
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

test "Parser captures streamed functionCall" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();

    const fixture =
        \\data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"search","args":{"term":"sample"}}}]}}]}
        \\
    ;
    try parser.feed(fixture);
    try parser.finish();

    const call = parser.takeToolCall() orelse return error.TestExpectedEqual;
    defer {
        allocator.free(call.name);
        allocator.free(call.args_json);
    }
    try std.testing.expectEqualStrings("search", call.name);
    try std.testing.expect(std.mem.indexOf(u8, call.args_json, "sample") != null);
}

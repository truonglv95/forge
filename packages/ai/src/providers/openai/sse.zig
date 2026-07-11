const std = @import("std");
const provider_mod = @import("../../provider.zig");

pub const Callbacks = struct {
    on_chunk: ?*const fn (?*anyopaque, []const u8) void = null,
    context: ?*anyopaque = null,
};

const StreamEvent = struct {
    choices: ?[]Choice = null,
    usage: ?Usage = null,
    @"error": ?ApiError = null,

    const Choice = struct {
        delta: ?Delta = null,
        message: ?Message = null,
        finish_reason: ?[]const u8 = null,
    };

    const Delta = struct {
        content: ?[]const u8 = null,
        tool_calls: ?[]ToolCallDelta = null,
    };

    const Message = struct {
        content: ?[]const u8 = null,
        tool_calls: ?[]ToolCallDelta = null,
    };

    const ToolCallDelta = struct {
        function: ?struct {
            name: ?[]const u8 = null,
            arguments: ?std.json.Value = null,
        } = null,
    };

    const Usage = struct {
        prompt_tokens: ?usize = null,
        completion_tokens: ?usize = null,
        total_tokens: ?usize = null,
    };

    const ApiError = struct {
        message: ?[]const u8 = null,
        code: ?std.json.Value = null,
        type: ?[]const u8 = null,
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
        return .{
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
        if (self.tool_call_name != null and self.tool_call_args_json == null) {
            self.tool_call_args_json = self.allocator.dupe(u8, "{}") catch return error.MalformedResponse;
        }
    }

    pub fn assembledText(self: *const Parser) []const u8 {
        return self.assembled.items;
    }

    pub fn takeToolCall(self: *Parser) ?struct { name: []u8, args_json: []u8 } {
        const name = self.tool_call_name orelse return null;
        const args_json = self.tool_call_args_json orelse return null;
        self.tool_call_name = null;
        self.tool_call_args_json = null;
        return .{ .name = name, .args_json = args_json };
    }

    fn flushWriterBuffer(self: *Parser, w: *std.Io.Writer) ParseError!void {
        if (w.end == 0) return;
        try self.feed(w.buffer[0..w.end]);
        w.end = 0;
    }

    fn feed(self: *Parser, bytes: []const u8) ParseError!void {
        self.pending.appendSlice(self.allocator, bytes) catch return error.MalformedResponse;
        while (true) {
            const delim = std.mem.indexOf(u8, self.pending.items, "\n\n") orelse
                std.mem.indexOf(u8, self.pending.items, "\r\n\r\n") orelse break;
            const raw = self.allocator.dupe(u8, std.mem.trim(u8, self.pending.items[0..delim], "\r\n")) catch return error.MalformedResponse;
            defer self.allocator.free(raw);
            const consume = if (delim < self.pending.items.len and self.pending.items[delim] == '\r') delim + 4 else delim + 2;
            const rest = self.allocator.dupe(u8, self.pending.items[consume..]) catch return error.MalformedResponse;
            defer self.allocator.free(rest);
            self.pending.clearRetainingCapacity();
            self.pending.appendSlice(self.allocator, rest) catch return error.MalformedResponse;
            if (raw.len > 0) try self.handleEvent(raw);
        }
    }

    fn handleEvent(self: *Parser, raw_event: []const u8) ParseError!void {
        var payload_buf: std.ArrayList(u8) = .empty;
        defer payload_buf.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, raw_event, '\n');
        while (lines.next()) |line| {
            var l = std.mem.trim(u8, line, "\r");
            if (!std.mem.startsWith(u8, l, "data:")) continue;
            l = std.mem.trim(u8, l["data:".len..], " ");
            if (l.len > 0) payload_buf.appendSlice(self.allocator, l) catch return error.MalformedResponse;
        }

        const payload = payload_buf.items;
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) return;
        try self.handlePayload(payload);
    }

    fn handlePayload(self: *Parser, payload: []const u8) ParseError!void {
        var parsed = std.json.parseFromSlice(StreamEvent, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("JSON ERROR: {any}\n", .{err});
            return;
        };
        defer parsed.deinit();

        if (parsed.value.@"error") |_| {
            self.terminal_error = provider_mod.ProviderError.ProviderInternalError;
            return;
        }

        if (parsed.value.usage) |usage| {
            self.latest_usage = .{
                .prompt_tokens = usage.prompt_tokens orelse self.latest_usage.prompt_tokens,
                .completion_tokens = usage.completion_tokens orelse self.latest_usage.completion_tokens,
                .total_tokens = usage.total_tokens orelse self.latest_usage.total_tokens,
            };
        }

        const choices = parsed.value.choices orelse return;
        for (choices) |choice| {
            if (choice.delta) |delta| {
                if (delta.tool_calls) |calls| try self.handleToolCallDeltas(calls);
                if (delta.content) |chunk| try self.appendText(chunk);
            }
            if (choice.message) |message| {
                if (message.tool_calls) |calls| try self.handleToolCallDeltas(calls);
                if (message.content) |chunk| try self.appendText(chunk);
            }
        }
    }

    fn handleToolCallDeltas(self: *Parser, calls: []const StreamEvent.ToolCallDelta) ParseError!void {
        if (calls.len == 0) return;
        const first = calls[0];
        const function = first.function orelse return;
        if (function.name) |name| {
            if (name.len > 0) {
                if (self.tool_call_name) |owned| self.allocator.free(owned);
                self.tool_call_name = self.allocator.dupe(u8, name) catch return error.MalformedResponse;
            }
        }
        if (function.arguments) |args_val| {
            var args_chunk: []const u8 = "";
            var dynamic_chunk = false;
            switch (args_val) {
                .string => |s| args_chunk = s,
                else => {
                    args_chunk = std.json.Stringify.valueAlloc(self.allocator, args_val, .{}) catch return error.MalformedResponse;
                    dynamic_chunk = true;
                },
            }

            if (self.tool_call_args_json == null) {
                self.tool_call_args_json = self.allocator.dupe(u8, "") catch return error.MalformedResponse;
            }
            const old = self.tool_call_args_json.?;
            const next = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ old, args_chunk }) catch return error.MalformedResponse;
            self.allocator.free(old);
            self.tool_call_args_json = next;

            if (dynamic_chunk) self.allocator.free(args_chunk);
        }
    }

    fn appendText(self: *Parser, chunk: []const u8) ParseError!void {
        if (chunk.len == 0) return;
        self.assembled.appendSlice(self.allocator, chunk) catch return error.MalformedResponse;
        if (self.callbacks.on_chunk) |callback| callback(self.callbacks.context, chunk);
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
            self.feed(slice) catch return error.WriteFailed;
            total += slice.len;
        }

        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            self.feed(pattern) catch return error.WriteFailed;
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
        if (preserved_len > 0) @memmove(w.buffer[0..preserved_len], w.buffer[preserved_head..w.end]);
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
    MalformedResponse,
    AuthenticationFailed,
    RateLimitExceeded,
};

test "Parser assembles OpenAI-compatible SSE content" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();

    const fixture =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5}}\n\n" ++
        "data: [DONE]\n\n";
    try parser.feed(fixture);
    try parser.finish();

    try std.testing.expectEqualStrings("Hello", parser.assembledText());
    try std.testing.expectEqual(@as(usize, 5), parser.latest_usage.total_tokens);
}

test "Parser captures streamed tool call arguments" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();

    const fixture =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"name\":\"search\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"{}\"}}]}}]}\n\n" ++
        "data: [DONE]\n\n";
    try parser.feed(fixture);
    try parser.finish();

    const call = parser.takeToolCall() orelse return error.TestExpectedEqual;
    defer {
        allocator.free(call.name);
        allocator.free(call.args_json);
    }
    try std.testing.expectEqualStrings("search", call.name);
    try std.testing.expectEqualStrings("{}{}", call.args_json);
}

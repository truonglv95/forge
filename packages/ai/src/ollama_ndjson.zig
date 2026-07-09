const std = @import("std");
const provider_mod = @import("provider.zig");

pub const Callbacks = struct {
    on_chunk: ?*const fn (?*anyopaque, []const u8) void = null,
    context: ?*anyopaque = null,
};

const StreamEvent = struct {
    message: ?struct {
        content: ?[]const u8 = null,
        tool_calls: ?[]struct {
            function: struct {
                name: []const u8,
                arguments: std.json.Value,
            },
        } = null,
    } = null,
    done: bool = false,
    prompt_eval_count: ?i64 = null,
    eval_count: ?i64 = null,
    @"error": ?[]const u8 = null,
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

    pub fn ioWriter(self: *Parser) *std.Io.Writer {
        self.writer = std.Io.Writer{
            .buffer = self.writer_buffer[0..],
            .vtable = &ndjson_writer_vtable,
        };
        self.writer_initialized = true;
        ndjson_active_parser = self;
        return &self.writer;
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

    pub fn releaseWriter(self: *Parser) void {
        if (ndjson_active_parser == self) ndjson_active_parser = null;
    }

    fn flushWriterBuffer(self: *Parser, w: *std.Io.Writer) ParseError!void {
        if (w.end == 0) return;
        try self.feed(w.buffer[0..w.end]);
        w.end = 0;
    }

    pub fn finish(self: *Parser) ParseError!void {
        if (self.writer_initialized) try self.flushWriterBuffer(&self.writer);
        if (self.pending.items.len > 0) {
            const last_line = self.allocator.dupe(u8, std.mem.trim(u8, self.pending.items, "\r\n")) catch return error.MalformedResponse;
            defer self.allocator.free(last_line);
            self.pending.clearRetainingCapacity();
            if (last_line.len > 0) try self.handleLine(last_line);
        }
        if (self.terminal_error != null) return error.MalformedResponse;
        try self.tryExtractToolCallFromContent();
    }

    pub fn assembledText(self: *const Parser) []const u8 {
        return self.assembled.items;
    }

    fn feed(self: *Parser, bytes: []const u8) ParseError!void {
        self.pending.appendSlice(self.allocator, bytes) catch return error.MalformedResponse;
        while (true) {
            const line_end = std.mem.indexOfScalar(u8, self.pending.items, '\n') orelse break;
            const raw_line = self.allocator.dupe(u8, std.mem.trim(u8, self.pending.items[0..line_end], "\r")) catch return error.MalformedResponse;
            defer self.allocator.free(raw_line);
            const rest = self.allocator.dupe(u8, self.pending.items[line_end + 1 ..]) catch return error.MalformedResponse;
            defer self.allocator.free(rest);
            self.pending.clearRetainingCapacity();
            self.pending.appendSlice(self.allocator, rest) catch return error.MalformedResponse;
            if (raw_line.len == 0) continue;
            try self.handleLine(raw_line);
        }
    }

    fn handleLine(self: *Parser, line: []const u8) ParseError!void {
        var parsed = std.json.parseFromSlice(StreamEvent, self.allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        if (parsed.value.@"error") |message| {
            _ = message;
            self.terminal_error = provider_mod.ProviderError.ProviderInternalError;
            return;
        }

        if (parsed.value.prompt_eval_count) |count| {
            self.latest_usage.prompt_tokens = @intCast(count);
        }
        if (parsed.value.eval_count) |count| {
            self.latest_usage.completion_tokens = @intCast(count);
        }
        self.latest_usage.total_tokens = self.latest_usage.prompt_tokens + self.latest_usage.completion_tokens;

        const content = parsed.value.message orelse return;
        if (content.tool_calls) |calls| {
            if (calls.len > 0) {
                const first = calls[0];
                if (self.tool_call_name) |owned| self.allocator.free(owned);
                if (self.tool_call_args_json) |owned| self.allocator.free(owned);
                self.tool_call_name = self.allocator.dupe(u8, first.function.name) catch return error.MalformedResponse;
                self.tool_call_args_json = std.json.Stringify.valueAlloc(self.allocator, first.function.arguments, .{}) catch return error.MalformedResponse;
            }
        }
        const chunk = content.content orelse return;
        if (chunk.len == 0) return;

        self.assembled.appendSlice(self.allocator, chunk) catch return error.MalformedResponse;
        if (self.callbacks.on_chunk) |callback| callback(self.callbacks.context, chunk);
    }

    fn tryExtractToolCallFromContent(self: *Parser) ParseError!void {
        if (self.tool_call_name != null) return;
        const trimmed = std.mem.trim(u8, self.assembled.items, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        if (trySalvageToolCall(self, trimmed)) {
            self.assembled.clearRetainingCapacity();
            return;
        }

        if (std.mem.indexOfScalar(u8, trimmed, '{')) |start| {
            if (trySalvageToolCall(self, trimmed[start..])) {
                self.assembled.clearRetainingCapacity();
            }
        }
    }

    fn trySalvageToolCall(self: *Parser, text: []const u8) bool {
        const json_text = extractLooseJsonObject(self.allocator, text) orelse return false;
        defer self.allocator.free(json_text);

        const NamedPayload = struct {
            name: ?[]const u8 = null,
            arguments: ?std.json.Value = null,
            parameters: ?std.json.Value = null,
        };
        if (std.json.parseFromSlice(NamedPayload, self.allocator, json_text, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.name) |name| {
                if (name.len > 0) {
                    const args = parsed.value.arguments orelse parsed.value.parameters orelse return false;
                    return storeSalvagedCall(self, name, args);
                }
            }
        } else |_| {}

        const BarePayload = struct {
            query: ?[]const u8 = null,
            term: ?[]const u8 = null,
            pattern: ?[]const u8 = null,
            path: ?[]const u8 = null,
            depth: ?usize = null,
            start_line: ?usize = null,
            end_line: ?usize = null,
            command: ?[]const u8 = null,
            url: ?[]const u8 = null,
        };
        var bare = std.json.parseFromSlice(BarePayload, self.allocator, json_text, .{ .ignore_unknown_fields = true }) catch return false;
        defer bare.deinit();

        if (bare.value.query != null) {
            return storeSalvagedArgs(self, "codebase_search", json_text);
        }
        if (bare.value.term != null or bare.value.pattern != null) {
            return storeSalvagedArgs(self, "search", json_text);
        }
        if (bare.value.command != null) {
            return storeSalvagedArgs(self, "run_command", json_text);
        }
        if (bare.value.url != null) {
            return storeSalvagedArgs(self, "fetch_url", json_text);
        }
        if (bare.value.path != null or bare.value.start_line != null or bare.value.end_line != null) {
            return storeSalvagedArgs(self, "read_file", json_text);
        }
        if (bare.value.depth != null) {
            const args = std.fmt.allocPrint(self.allocator, "{{\"path\":\".\",\"depth\":{d}}}", .{bare.value.depth.?}) catch return false;
            defer self.allocator.free(args);
            return storeSalvagedArgs(self, "list_tree", args);
        }
        return false;
    }

    fn storeSalvagedCall(self: *Parser, name: []const u8, args: std.json.Value) bool {
        if (self.tool_call_name) |owned| self.allocator.free(owned);
        if (self.tool_call_args_json) |owned| self.allocator.free(owned);
        self.tool_call_name = self.allocator.dupe(u8, name) catch return false;
        self.tool_call_args_json = std.json.Stringify.valueAlloc(self.allocator, args, .{}) catch return false;
        return true;
    }

    fn storeSalvagedArgs(self: *Parser, name: []const u8, args_json: []const u8) bool {
        if (self.tool_call_name) |owned| self.allocator.free(owned);
        if (self.tool_call_args_json) |owned| self.allocator.free(owned);
        self.tool_call_name = self.allocator.dupe(u8, name) catch return false;
        self.tool_call_args_json = self.allocator.dupe(u8, args_json) catch return false;
        return true;
    }

    fn extractLooseJsonObject(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
        const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
        const start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return null;
        const braced = firstJsonObject(trimmed[start..]) orelse trimmed[start..];

        var slice = braced;
        while (slice.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{ .ignore_unknown_fields = true });
            if (parsed) |p| {
                p.deinit();
                return allocator.dupe(u8, slice) catch null;
            } else |_| {}
            if (slice.len == 0 or slice[slice.len - 1] != '}') return null;
            slice = slice[0 .. slice.len - 1];
        }
        return null;
    }

    fn firstJsonObject(text: []const u8) ?[]const u8 {
        if (text.len == 0 or text[0] != '{') return null;
        var depth: i32 = 0;
        var in_string = false;
        var escape = false;
        for (text, 0..) |byte, offset| {
            if (in_string) {
                if (escape) {
                    escape = false;
                } else switch (byte) {
                    '\\' => escape = true,
                    '"' => in_string = false,
                    else => {},
                }
                continue;
            }
            switch (byte) {
                '"' => in_string = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return text[0 .. offset + 1];
                },
                else => {},
            }
        }
        return null;
    }

    fn writerDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self = ndjson_active_parser orelse return error.WriteFailed;
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
        const self = ndjson_active_parser orelse return;
        self.flushWriterBuffer(w) catch return error.WriteFailed;
    }

    fn writerRebase(w: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        const self = ndjson_active_parser orelse return error.WriteFailed;
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

const ndjson_writer_vtable = std.Io.Writer.VTable{
    .drain = Parser.writerDrain,
    .flush = Parser.writerFlush,
    .rebase = Parser.writerRebase,
};

threadlocal var ndjson_active_parser: ?*Parser = null;

pub const ParseError = error{
    MalformedResponse,
    ProviderInternalError,
};

test "Parser assembles streamed NDJSON chunks" {
    const allocator = std.testing.allocator;
    var chunks: std.ArrayList([]const u8) = .empty;
    defer {
        for (chunks.items) |item| allocator.free(item);
        chunks.deinit(allocator);
    }

    const Context = struct {
        chunks: *std.ArrayList([]const u8),
        allocator: std.mem.Allocator,

        fn onChunk(ctx: ?*anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const owned = self.allocator.dupe(u8, chunk) catch return;
            self.chunks.append(self.allocator, owned) catch {};
        }
    };

    var ctx = Context{ .chunks = &chunks, .allocator = allocator };

    var parser = Parser.init(allocator, .{
        .on_chunk = Context.onChunk,
        .context = &ctx,
    });
    defer parser.deinit();

    const fixture =
        \\{"message":{"role":"assistant","content":"Hel"},"done":false}
        \\{"message":{"role":"assistant","content":"lo"},"done":true,"prompt_eval_count":3,"eval_count":2}
        \\
    ;
    try parser.feed(fixture);
    try parser.finish();
    try std.testing.expectEqualStrings("Hello", parser.assembledText());
    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqual(@as(usize, 3), parser.latest_usage.prompt_tokens);
    try std.testing.expectEqual(@as(usize, 2), parser.latest_usage.completion_tokens);
}

test "Parser captures streamed tool_calls" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();

    const fixture =
        \\{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"search","arguments":{"term":"sample"}}}]},"done":true}
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

test "Parser salvages bare query JSON with trailing brace" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();

    const fixture =
        \\{"message":{"role":"assistant","content":"Let's search more.\n{\"query\":\"engine\"}}"},"done":true}
        \\
    ;
    try parser.feed(fixture);
    try parser.finish();

    const call = parser.takeToolCall() orelse return error.TestExpectedEqual;
    defer {
        allocator.free(call.name);
        allocator.free(call.args_json);
    }
    try std.testing.expectEqualStrings("codebase_search", call.name);
    try std.testing.expect(std.mem.indexOf(u8, call.args_json, "engine") != null);
}

test "Parser salvages bare depth JSON as list_tree" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();

    const fixture =
        \\{"message":{"role":"assistant","content":"{\"depth\":1}}"},"done":true}
        \\
    ;
    try parser.feed(fixture);
    try parser.finish();

    const call = parser.takeToolCall() orelse return error.TestExpectedEqual;
    defer {
        allocator.free(call.name);
        allocator.free(call.args_json);
    }
    try std.testing.expectEqualStrings("list_tree", call.name);
    try std.testing.expect(std.mem.indexOf(u8, call.args_json, "\"depth\":1") != null);
}

test "Parser captures tool call JSON emitted in content" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, .{});
    defer parser.deinit();

    const fixture =
        \\{"message":{"role":"assistant","content":"{\"name\":\"search\",\"arguments\":{\"query\":\"sample\"}}"},"done":true}
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
    try std.testing.expectEqual(@as(usize, 0), parser.assembledText().len);
}

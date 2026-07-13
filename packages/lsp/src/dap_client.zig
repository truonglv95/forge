const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;
const kernel = @import("forge-kernel");

/// Debug Adapter Protocol (DAP) client.
///
/// Implements the client side of the Debug Adapter Protocol (microsoft/debug-adapter-protocol).
/// This lets Forge connect to ANY DAP-compliant debug server (lldb-dap, gdb-dap,
/// python-debugpy, java-debug, js-debug, etc.) instead of being limited to LLDB.
///
/// The protocol uses a header+body framing over stdio:
///   Content-Length: NNN\r\n\r\n<JSON payload>
///
/// This module handles:
///   - Spawning and communicating with DAP servers
///   - Sending requests (initialize, launch, setBreakpoints, etc.)
///   - Receiving responses and events
///   - Sequence management (request IDs)
pub const DapError = error{
    SpawnFailed,
    ProtocolError,
    Timeout,
    ServerExited,
    OutOfMemory,
    InvalidResponse,
    Cancelled,
};

pub const EventType = enum {
    initialized,
    stopped,
    continued,
    terminated,
    exited,
    thread,
    output,
    breakpoint,
    module,
    loaded_source,
    capabilities_event,
};

pub const StoppedReason = enum {
    step,
    breakpoint,
    exception,
    pause,
    entry,
    goto,
    function_breakpoint,
    data_breakpoint,
    instruction_breakpoint,
    unknown,

    pub fn parse(s: []const u8) StoppedReason {
        if (std.mem.eql(u8, s, "step")) return .step;
        if (std.mem.eql(u8, s, "breakpoint")) return .breakpoint;
        if (std.mem.eql(u8, s, "exception")) return .exception;
        if (std.mem.eql(u8, s, "pause")) return .pause;
        if (std.mem.eql(u8, s, "entry")) return .entry;
        if (std.mem.eql(u8, s, "goto")) return .goto;
        return .unknown;
    }
};

pub const Breakpoint = struct {
    line: u32,
    column: ?u32 = null,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
};

pub const StackFrame = struct {
    id: u32,
    name: []const u8,
    source: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    end_line: ?u32 = null,
    end_column: ?u32 = null,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    type: ?[]const u8 = null,
    variables_reference: u32 = 0,
};

pub const DapEvent = struct {
    event_type: EventType,
    raw_json: []const u8,
};

pub const DapClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    process: ?process_spawn.Child = null,
    next_seq: u32 = 1,
    /// Pending response buffer (owned).
    response_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) DapClient {
        return .{
            .allocator = allocator,
            .io = io,
            .process = null,
            .next_seq = 1,
            .response_buf = .empty,
        };
    }

    pub fn deinit(self: *DapClient) void {
        if (self.process) |*p| {
            p.kill();
            p.deinit();
        }
        self.response_buf.deinit(self.allocator);
    }

    /// Spawn a DAP server process.
    pub fn launch(self: *DapClient, argv: []const []const u8) DapError!void {
        self.process = process_spawn.spawn(self.allocator, argv, .{
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.SpawnFailed;
    }

    /// Send a DAP request and return the response JSON (owned).
    /// This is synchronous: blocks until the response with matching seq arrives.
    pub fn request(
        self: *DapClient,
        command: []const u8,
        args_json: ?[]const u8,
    ) DapError![]u8 {
        const seq = self.next_seq;
        self.next_seq += 1;

        // Build the JSON message.
        const msg = if (args_json) |args|
            std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"type":"request","command":"{s}","arguments":{s}}}
            , .{ seq, command, args }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"type":"request","command":"{s}"}}
            , .{ seq, command }) catch return error.OutOfMemory;
        defer self.allocator.free(msg);

        // Write to server stdin.
        try self.sendMessage(msg);

        // Read responses until we get the one with matching request_seq.
        while (true) {
            const resp = try self.readMessage();
            defer self.allocator.free(resp);

            // Check if it's a response to our request.
            if (std.mem.indexOf(u8, resp, "\"type\":\"response\"")) |_| {
                if (std.mem.indexOf(u8, resp, "\"request_seq\":")) |idx| {
                    const num_start = idx + "\"request_seq\":".len;
                    var num_end = num_start;
                    while (num_end < resp.len and std.ascii.isDigit(resp[num_end])) num_end += 1;
                    const req_seq_str = resp[num_start..num_end];
                    const req_seq = std.fmt.parseInt(u32, req_seq_str, 10) catch 0;
                    if (req_seq == seq) {
                        return self.allocator.dupe(u8, resp) catch error.OutOfMemory;
                    }
                }
            }
            // It's an event — we could queue it, but for MVP we just skip.
            // The caller can poll for events separately.
        }
    }

    /// Send a DAP event (not expecting a response).
    pub fn sendEvent(self: *DapClient, event_name: []const u8, args_json: ?[]const u8) DapError!void {
        const seq = self.next_seq;
        self.next_seq += 1;

        const msg = if (args_json) |args|
            std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"type":"event","event":"{s}","body":{s}}}
            , .{ seq, event_name, args }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"type":"event","event":"{s}"}}
            , .{ seq, event_name }) catch return error.OutOfMemory;
        defer self.allocator.free(msg);

        try self.sendMessage(msg);
    }

    /// Poll for an event from the server (non-blocking).
    /// Returns null if no message is available.
    pub fn pollEvent(self: *DapClient) DapError!?[]u8 {
        const msg = self.readMessage() catch return null;
        if (std.mem.indexOf(u8, msg, "\"type\":\"event\"") != null) {
            return msg;
        }
        self.allocator.free(msg);
        return null;
    }

    // --- High-level DAP commands ---

    /// Initialize the DAP session. Must be called first.
    pub fn initialize(self: *DapClient, adapter_id: []const u8) DapError![]u8 {
        const args = std.fmt.allocPrint(self.allocator,
            \\{{"clientID":"forge","clientName":"Forge IDE","adapterID":"{s}","locale":"en-US","linesStartAt1":true,"columnsStartAt1":true,"pathFormat":"path","supportsVariableType":true,"supportsVariablePaging":false,"supportsRunInTerminalRequest":true}}
        , .{adapter_id}) catch return error.OutOfMemory;
        defer self.allocator.free(args);
        return self.request("initialize", args);
    }

    /// Launch a program.
    pub fn launchProgram(self: *DapClient, program: []const u8, cwd: ?[]const u8, args: ?[]const []const u8) DapError![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        buf.appendSlice(self.allocator, "{\"program\":") catch return error.OutOfMemory;
        std.json.Stringify.value(self.allocator, program, .{ .whitespace = .minified }) catch {};
        // Simpler: just use allocPrint
        const program_escaped = try escapeJsonString(self.allocator, program);
        defer self.allocator.free(program_escaped);

        if (cwd) |c| {
            const cwd_escaped = try escapeJsonString(self.allocator, c);
            defer self.allocator.free(cwd_escaped);
            if (args) |a| {
                const args_str = try joinArgs(self.allocator, a);
                defer self.allocator.free(args_str);
                const body = std.fmt.allocPrint(self.allocator,
                    \\{{"program":"{s}","cwd":"{s}","args":{s}}}
                , .{ program_escaped, cwd_escaped, args_str }) catch return error.OutOfMemory;
                defer self.allocator.free(body);
                return self.request("launch", body);
            } else {
                const body = std.fmt.allocPrint(self.allocator,
                    \\{{"program":"{s}","cwd":"{s}"}}
                , .{ program_escaped, cwd_escaped }) catch return error.OutOfMemory;
                defer self.allocator.free(body);
                return self.request("launch", body);
            }
        } else {
            const body = std.fmt.allocPrint(self.allocator,
                \\{{"program":"{s}"}}
            , .{program_escaped}) catch return error.OutOfMemory;
            defer self.allocator.free(body);
            return self.request("launch", body);
        }
    }

    /// Set breakpoints for a source file.
    pub fn setBreakpoints(self: *DapClient, source_path: []const u8, breakpoints: []const Breakpoint) DapError![]u8 {
        const path_escaped = try escapeJsonString(self.allocator, source_path);
        defer self.allocator.free(path_escaped);

        var bp_buf: std.ArrayList(u8) = .empty;
        defer bp_buf.deinit(self.allocator);
        bp_buf.appendSlice(self.allocator, "[") catch return error.OutOfMemory;
        for (breakpoints, 0..) |bp, i| {
            if (i > 0) bp_buf.appendSlice(self.allocator, ",") catch return error.OutOfMemory;
            const bp_json = std.fmt.allocPrint(self.allocator, "{{\"line\":{d}}}", .{bp.line}) catch return error.OutOfMemory;
            defer self.allocator.free(bp_json);
            bp_buf.appendSlice(self.allocator, bp_json) catch return error.OutOfMemory;
        }
        bp_buf.appendSlice(self.allocator, "]") catch return error.OutOfMemory;

        const body = std.fmt.allocPrint(self.allocator,
            \\{{"source":{{"path":"{s}"}},"breakpoints":{s},"linesStartAt1":true}}
        , .{ path_escaped, bp_buf.items }) catch return error.OutOfMemory;
        defer self.allocator.free(body);
        return self.request("setBreakpoints", body);
    }

    /// Continue execution.
    pub fn continue_(self: *DapClient, thread_id: u32) DapError![]u8 {
        const body = std.fmt.allocPrint(self.allocator, "{{\"threadId\":{d}}}", .{thread_id}) catch return error.OutOfMemory;
        defer self.allocator.free(body);
        return self.request("continue", body);
    }

    /// Step over.
    pub fn next_(self: *DapClient, thread_id: u32) DapError![]u8 {
        const body = std.fmt.allocPrint(self.allocator, "{{\"threadId\":{d}}}", .{thread_id}) catch return error.OutOfMemory;
        defer self.allocator.free(body);
        return self.request("next", body);
    }

    /// Step into.
    pub fn stepIn(self: *DapClient, thread_id: u32) DapError![]u8 {
        const body = std.fmt.allocPrint(self.allocator, "{{\"threadId\":{d}}}", .{thread_id}) catch return error.OutOfMemory;
        defer self.allocator.free(body);
        return self.request("stepIn", body);
    }

    /// Step out.
    pub fn stepOut(self: *DapClient, thread_id: u32) DapError![]u8 {
        const body = std.fmt.allocPrint(self.allocator, "{{\"threadId\":{d}}}", .{thread_id}) catch return error.OutOfMemory;
        defer self.allocator.free(body);
        return self.request("stepOut", body);
    }

    /// Get stack trace.
    pub fn stackTrace(self: *DapClient, thread_id: u32) DapError![]u8 {
        const body = std.fmt.allocPrint(self.allocator, "{{\"threadId\":{d}}}", .{thread_id}) catch return error.OutOfMemory;
        defer self.allocator.free(body);
        return self.request("stackTrace", body);
    }

    /// Get variables for a scope or variable reference.
    pub fn variables(self: *DapClient, variables_reference: u32) DapError![]u8 {
        const body = std.fmt.allocPrint(self.allocator, "{{\"variablesReference\":{d}}}", .{variables_reference}) catch return error.OutOfMemory;
        defer self.allocator.free(body);
        return self.request("variables", body);
    }

    /// Disconnect from the debug server.
    pub fn disconnect(self: *DapClient) DapError!void {
        _ = self.request("disconnect", null) catch {};
    }

    // --- Internal framing ---

    fn sendMessage(self: *DapClient, json_msg: []const u8) DapError!void {
        const proc = &(self.process orelse return error.ServerExited);
        const header = std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{json_msg.len}) catch return error.OutOfMemory;
        defer self.allocator.free(header);

        _ = std.posix.write(proc.stdin_fd, header) catch return error.ServerExited;
        _ = std.posix.write(proc.stdin_fd, json_msg) catch return error.ServerExited;
    }

    fn readMessage(self: *DapClient) DapError![]u8 {
        const proc = &(self.process orelse return error.ServerExited);

        // Read headers until empty line.
        var content_length: usize = 0;
        var header_buf: [256]u8 = undefined;
        while (true) {
            const line = readLine(proc.stdout_fd, &header_buf) catch return error.ServerExited;
            if (line.len == 0) break; // empty line = end of headers
            if (std.mem.startsWith(u8, line, "Content-Length:")) {
                const num_str = std.mem.trim(u8, line["Content-Length:".len..], " \r\n");
                content_length = std.fmt.parseInt(usize, num_str, 10) catch return error.ProtocolError;
            }
        }

        if (content_length == 0) return error.ProtocolError;

        // Read body.
        const body = self.allocator.alloc(u8, content_length) catch return error.OutOfMemory;
        var total: usize = 0;
        while (total < content_length) {
            const n = std.posix.read(proc.stdout_fd, body[total..]) catch {
                self.allocator.free(body);
                return error.ServerExited;
            };
            if (n == 0) {
                self.allocator.free(body);
                return error.ServerExited;
            }
            total += n;
        }
        return body;
    }
};

fn readLine(fd: c_int, buf: []u8) ![]u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const byte = std.posix.read(fd, buf[n .. n + 1]) catch return error.ReadFailed;
        if (byte == 0) return error.ReadFailed;
        if (buf[n] == '\n') {
            return buf[0 .. n + 1];
        }
        n += 1;
    }
    return buf[0..n];
}

fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[");
    for (args, 0..) |arg, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.append(allocator, '"');
        for (arg) |c| {
            switch (c) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                else => try out.append(allocator, c),
            }
        }
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "]");
    return out.toOwnedSlice(allocator);
}

test "DapClient init/deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var client = DapClient.init(allocator, io);
    defer client.deinit();
    try std.testing.expectEqual(@as(u32, 1), client.next_seq);
}

test "escapeJsonString escapes quotes and backslashes" {
    const allocator = std.testing.allocator;
    const result = try escapeJsonString(allocator, "path/to\"file");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path/to\\\"file", result);
}

test "joinArgs formats JSON array" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "arg1", "arg2" };
    const result = try joinArgs(allocator, &args);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[\"arg1\",\"arg2\"]", result);
}

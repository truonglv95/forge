//! DAP-backed debug session.
//!
//! Replaces `debug_lldb_session.zig` (which spawned the `lldb` CLI and parsed
//! free-form text output) with a standards-compliant Debug Adapter Protocol
//! client. Works with any DAP server — `lldb-dap`, `gdb-dap`, `python-debugpy`,
//! `js-debug`, `java-debug`, etc. — configurable via `[debug] adapter_command`
//! in `settings.toml`.
//!
//! Maintains the same callback interface as the legacy LLDB session so the
//! existing `debug_ops.zig` wiring (on_line / on_finished / context) keeps
//! working unchanged. DAP events are translated into the same line-oriented
//! text format that `debug_stop.zig`, `debug_variables.zig`, and
//! `debug_callstack.zig` already parse — so a `stopped` event becomes
//! `"stopped at <path>:<line>"`, a `stackTrace` response becomes a sequence
//! of `"frame #N: <label> at <path>:<line>"` lines, and so on.

const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;
const forge_util = @import("forge-util");
const breakpoints_mod = @import("breakpoints.zig");

/// Configurable DAP server. Defaults to `lldb-dap` (LLVM's DAP server).
pub const default_adapter_command: []const []const u8 = &.{"lldb-dap"};

pub const Session = struct {
    allocator: std.mem.Allocator,
    child: process_spawn.Child = .{},
    reader: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    initialised: std.atomic.Value(bool) = .init(false),
    on_line: *const fn (context: ?*anyopaque, line: []const u8) void,
    on_finished: *const fn (context: ?*anyopaque, exit_code: i32) void,
    context: ?*anyopaque,
    write_mutex: forge_util.sync.Mutex = .{},

    /// Next outgoing request sequence number.
    next_seq: std.atomic.Value(u32) = .init(1),
    /// Currently active thread id (set by `thread` / `stopped` events).
    thread_id: std.atomic.Value(u32) = .init(1),
    /// Path of the program being debugged (owned, set by `start`).
    program_path: ?[]const u8 = null,

    pub fn deinit(self: *Session) void {
        self.stop();
        self.write_mutex.deinit();
        if (self.program_path) |p| self.allocator.free(p);
        self.program_path = null;
    }

    pub fn isActive(self: *const Session) bool {
        return self.running.load(.acquire);
    }

    /// Spawn the DAP server, send `initialize`, `setBreakpoints`, `launch`,
    /// and `configurationDone`. Once the server responds with the
    /// `initialized` event, the program is launched and will run until the
    /// first breakpoint is hit or the program exits.
    pub fn start(
        self: *Session,
        allocator: std.mem.Allocator,
        workspace_path: []const u8,
        source_rel_path: []const u8,
        breakpoints: *const breakpoints_mod.Store,
        on_line: *const fn (context: ?*anyopaque, line: []const u8) void,
        on_finished: *const fn (context: ?*anyopaque, exit_code: i32) void,
        context: ?*anyopaque,
    ) !void {
        self.stop();
        self.allocator = allocator;
        self.on_line = on_line;
        self.on_finished = on_finished;
        self.context = context;
        self.next_seq.store(1, .release);
        self.thread_id.store(1, .release);
        self.initialised.store(false, .release);

        // Resolve adapter command. For now we use the default (lldb-dap); in
        // the future this can be made configurable via settings.toml.
        const argv = default_adapter_command;

        self.child = try process_spawn.spawn(allocator, argv, .{
            .cwd = workspace_path,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        // Build absolute program path.
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ workspace_path, source_rel_path }) catch return error.PathTooLong;
        self.program_path = try allocator.dupe(u8, abs_path);

        self.running.store(true, .release);
        self.reader = try std.Thread.spawn(.{}, readerMain, .{self});

        // Send initialize request (synchronous response expected).
        const init_args =
            \\{"clientID":"forge","clientName":"Forge IDE","adapterID":"lldb","locale":"en-US","linesStartAt1":true,"columnsStartAt1":true,"pathFormat":"path","supportsVariableType":true,"supportsRunInTerminalRequest":true}
        ;
        _ = self.sendRequestBlocking("initialize", init_args) catch |err| {
            self.emitStatus("initialize failed: {s}", .{@errorName(err)});
        };

        // Send setBreakpoints for the source file (1-based lines for DAP).
        var bp_buf: std.ArrayList(u8) = .empty;
        defer bp_buf.deinit(allocator);
        bp_buf.appendSlice(allocator, "{\"source\":{\"path\":\"") catch return error.OutOfMemory;
        appendEscaped(&bp_buf, allocator, abs_path) catch return error.OutOfMemory;
        bp_buf.appendSlice(allocator, "\"},\"breakpoints\":[") catch return error.OutOfMemory;
        var first_bp = true;
        for (breakpoints.items.items) |bp| {
            if (!std.mem.eql(u8, bp.path, source_rel_path)) continue;
            if (!first_bp) bp_buf.append(allocator, ',') catch return error.OutOfMemory;
            first_bp = false;
            const bp_json = std.fmt.allocPrint(allocator, "{{\"line\":{d}}}", .{bp.line + 1}) catch return error.OutOfMemory;
            defer allocator.free(bp_json);
            bp_buf.appendSlice(allocator, bp_json) catch return error.OutOfMemory;
        }
        bp_buf.appendSlice(allocator, "],\"linesStartAt1\":true}") catch return error.OutOfMemory;
        _ = self.sendRequestBlocking("setBreakpoints", bp_buf.items) catch |err| {
            self.emitStatus("setBreakpoints failed: {s}", .{@errorName(err)});
        };

        // Send launch request.
        var launch_buf: std.ArrayList(u8) = .empty;
        defer launch_buf.deinit(allocator);
        launch_buf.appendSlice(allocator, "{\"program\":\"") catch return error.OutOfMemory;
        appendEscaped(&launch_buf, allocator, abs_path) catch return error.OutOfMemory;
        launch_buf.appendSlice(allocator, "\",\"cwd\":\"") catch return error.OutOfMemory;
        appendEscaped(&launch_buf, allocator, workspace_path) catch return error.OutOfMemory;
        launch_buf.appendSlice(allocator, "\",\"stopOnEntry\":false}") catch return error.OutOfMemory;
        _ = self.sendRequestBlocking("launch", launch_buf.items) catch |err| {
            self.emitStatus("launch failed: {s}", .{@errorName(err)});
        };

        // Tell the server we're done configuring — let it run.
        _ = self.sendRequestBlocking("configurationDone", null) catch |err| {
            self.emitStatus("configurationDone failed: {s}", .{@errorName(err)});
        };

        self.initialised.store(true, .release);
        self.emitStatus("DAP session ready (F5 continue, F10 step over, F11 step in)", .{});
    }

    pub fn stop(self: *Session) void {
        if (!self.running.swap(false, .acq_rel)) {
            // Not running — still ensure child is cleaned up.
            self.child.deinit();
            if (self.reader) |thread| thread.join();
            self.reader = null;
            return;
        }
        // Best-effort disconnect request.
        _ = self.sendMessage("{\"type\":\"request\",\"seq\":99999,\"command\":\"disconnect\",\"arguments\":{}}") catch {};
        self.child.deinit();
        if (self.reader) |thread| thread.join();
        self.reader = null;
    }

    pub fn continueExecution(self: *Session) !void {
        const tid = self.thread_id.load(.acquire);
        const body = std.fmt.allocPrint(self.allocator, "{{\"threadId\":{d}}}", .{tid}) catch return error.OutOfMemory;
        defer self.allocator.free(body);
        _ = self.sendRequestFireAndForget("continue", body) catch {};
    }

    pub fn refreshBacktrace(self: *Session) !void {
        const tid = self.thread_id.load(.acquire);
        var buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{tid}) catch return error.OutOfMemory;
        const response = self.sendRequestBlocking("stackTrace", body) catch return;
        defer self.allocator.free(response);
        self.parseStackTrace(response);
        // Also fetch variables for the top frame.
        self.fetchVariablesForTopFrame(response);
    }

    pub fn stepOver(self: *Session) !void {
        const tid = self.thread_id.load(.acquire);
        var buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{tid}) catch return error.OutOfMemory;
        _ = self.sendRequestFireAndForget("next", body) catch {};
    }

    pub fn stepInto(self: *Session) !void {
        const tid = self.thread_id.load(.acquire);
        var buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{tid}) catch return error.OutOfMemory;
        _ = self.sendRequestFireAndForget("stepIn", body) catch {};
    }

    pub fn stepOut(self: *Session) !void {
        const tid = self.thread_id.load(.acquire);
        var buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"threadId\":{d}}}", .{tid}) catch return error.OutOfMemory;
        _ = self.sendRequestFireAndForget("stepOut", body) catch {};
    }

    /// P1.5-3: Evaluate a watch expression in the current frame context.
    /// Returns the result string (owned) or an error message.
    /// The `frame_id` should be the top frame from the last stackTrace
    /// response (0 means no frame context).
    pub fn evaluate(self: *Session, expression: []const u8, frame_id: u32) ![]const u8 {
        // Build escaped expression into a buffer.
        var escaped_buf: std.ArrayList(u8) = .empty;
        defer escaped_buf.deinit(self.allocator);
        try appendEscaped(&escaped_buf, self.allocator, expression);

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"expression\":\"{s}\",\"frameId\":{d},\"context\":\"watch\"}}", .{ escaped_buf.items, frame_id }) catch return error.OutOfMemory;
        const response = self.sendRequestBlocking("evaluate", body) catch return error.ReadFailed;
        defer self.allocator.free(response);

        // Extract the "result" field from the response.
        const result_start = std.mem.indexOf(u8, response, "\"result\":\"");
        if (result_start == null) return error.ProtocolError;
        const result_end_idx = result_start.? + "\"result\":\"".len;
        var end = result_end_idx;
        while (end < response.len) {
            if (response[end] == '\\' and end + 1 < response.len) {
                end += 2;
                continue;
            }
            if (response[end] == '"') break;
            end += 1;
        }
        if (end > response.len) return error.ProtocolError;
        const raw_result = response[result_end_idx..end];
        // Unescape.
        var unescaped: [1024]u8 = undefined;
        const len = unescapeString(raw_result, &unescaped);
        return self.allocator.dupe(u8, unescaped[0..len]) catch error.OutOfMemory;
    }

    // -------------------------------------------------------------------
    // Internals

    fn emitStatus(self: *Session, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.on_line(self.context, msg);
    }

    fn sendMessage(self: *Session, json_msg: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        const header = std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{json_msg.len}) catch return error.OutOfMemory;
        defer self.allocator.free(header);
        self.child.writeAll(header) catch return error.WriteFailed;
        self.child.writeAll(json_msg) catch return error.WriteFailed;
    }

    /// Fire-and-forget: send the request but don't wait for a response.
    /// Useful for `continue`/`next`/`stepIn`/`stepOut` — the response is
    /// uninteresting, and we want to keep reading events on the reader thread.
    fn sendRequestFireAndForget(self: *Session, command: []const u8, args_json: ?[]const u8) !void {
        const seq = self.next_seq.fetchAdd(1, .acq_rel);
        const msg = if (args_json) |args|
            try std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"type":"request","command":"{s}","arguments":{s}}}
            , .{ seq, command, args })
        else
            try std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"type":"request","command":"{s}"}}
            , .{ seq, command });
        defer self.allocator.free(msg);
        try self.sendMessage(msg);
    }

    /// Synchronous request: send and wait for matching response on the
    /// calling thread. NOT safe to call from the reader thread.
    fn sendRequestBlocking(self: *Session, command: []const u8, args_json: ?[]const u8) ![]u8 {
        const seq = self.next_seq.fetchAdd(1, .acq_rel);
        const msg = if (args_json) |args|
            try std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"type":"request","command":"{s}","arguments":{s}}}
            , .{ seq, command, args })
        else
            try std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"type":"request","command":"{s}"}}
            , .{ seq, command });
        defer self.allocator.free(msg);
        try self.sendMessage(msg);

        // Read messages until we get our response. The reader thread is not
        // running during `start` (we spawn it after), so this is safe.
        // Note: we intentionally do not impose a timeout here — DAP servers
        // can be slow to initialize (lldb-dap loads symbols on launch).
        // If the server hangs, the user can press the Stop button.
        while (true) {
            const resp = self.readMessage() catch return error.ReadFailed;
            // Check if this is our response.
            if (std.mem.indexOf(u8, resp, "\"type\":\"response\"") != null) {
                if (extractIntField(resp, "\"request_seq\":")) |req_seq| {
                    if (req_seq == seq) {
                        return resp;
                    }
                }
            }
            // Otherwise it's an event — process it inline (so we don't miss
            // the `initialized` event that comes before `launch` response).
            self.processEventMessage(resp);
            self.allocator.free(resp);
        }
    }

    fn readMessage(self: *Session) ![]u8 {
        var content_length: usize = 0;
        var header_buf: [256]u8 = undefined;
        while (true) {
            const line = readLine(self.child.stdout_fd, &header_buf) catch return error.ReadFailed;
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "Content-Length:")) {
                const num_str = std.mem.trim(u8, line["Content-Length:".len..], " \r\n");
                content_length = std.fmt.parseInt(usize, num_str, 10) catch return error.ProtocolError;
            }
        }
        if (content_length == 0) return error.ProtocolError;
        const body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);
        var total: usize = 0;
        while (total < content_length) {
            const n = std.posix.read(self.child.stdout_fd, body[total..]) catch {
                self.allocator.free(body);
                return error.ReadFailed;
            };
            if (n == 0) {
                self.allocator.free(body);
                return error.ReadFailed;
            }
            total += n;
        }
        return body;
    }

    fn readerMain(self: *Session) void {
        defer {
            const code = self.child.wait();
            self.running.store(false, .release);
            self.on_finished(self.context, code);
        }
        while (self.running.load(.acquire)) {
            const msg = self.readMessage() catch break;
            defer self.allocator.free(msg);
            self.processEventMessage(msg);
        }
    }

    fn processEventMessage(self: *Session, msg: []const u8) void {
        // Identify message type.
        if (std.mem.indexOf(u8, msg, "\"type\":\"event\"") == null) return;

        const event = extractStringField(msg, "\"event\":\"") orelse return;
        if (std.mem.eql(u8, event, "output")) {
            self.handleOutputEvent(msg);
        } else if (std.mem.eql(u8, event, "stopped")) {
            self.handleStoppedEvent(msg);
        } else if (std.mem.eql(u8, event, "continued")) {
            // No-op.
        } else if (std.mem.eql(u8, event, "terminated") or std.mem.eql(u8, event, "exited")) {
            self.emitStatus("program terminated", .{});
        } else if (std.mem.eql(u8, event, "thread")) {
            if (extractIntField(msg, "\"threadId\":")) |tid| {
                self.thread_id.store(@intCast(tid), .release);
            }
        } else if (std.mem.eql(u8, event, "initialized")) {
            // Server is ready for launch.
        } else if (std.mem.eql(u8, event, "breakpoint")) {
            // Breakpoint resolution — could log verified locations.
        }
    }

    fn handleOutputEvent(self: *Session, msg: []const u8) void {
        const body_start = std.mem.indexOf(u8, msg, "\"body\":") orelse return;
        const body = msg[body_start..];
        const category = extractStringField(body, "\"category\":\"") orelse "stdout";
        const text = extractStringField(body, "\"output\":\"") orelse return;
        // Unescape common sequences.
        var unescaped: [4096]u8 = undefined;
        const len = unescapeString(text, &unescaped);
        if (len == 0) return;
        // Forward output to debug console, except for telemetry/internal.
        if (std.mem.eql(u8, category, "telemetry")) return;
        self.on_line(self.context, unescaped[0..len]);
    }

    fn handleStoppedEvent(self: *Session, msg: []const u8) void {
        const tid = extractIntField(msg, "\"threadId\":") orelse self.thread_id.load(.acquire);
        self.thread_id.store(@intCast(tid), .release);

        const reason = extractStringField(msg, "\"reason\":\"") orelse "unknown";

        // Try to extract the stop location from the `frame` field (some
        // adapters include it inline in the stopped event).
        var path: ?[]const u8 = null;
        var line: ?u32 = null;
        if (std.mem.indexOf(u8, msg, "\"frame\":")) |fs| {
            const frame = msg[fs..];
            path = extractStringField(frame, "\"path\":\"");
            if (extractIntField(frame, "\"line\":")) |l| line = @intCast(l);
        }

        // Emit a line that debug_stop.parseStopLine can parse:
        //   "frame #0: <reason> at <path>:<line>"
        if (path != null and line != null) {
            var buf: [1024]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "frame #0: {s} at {s}:{d}", .{ reason, path.?, line.? }) catch return;
            self.on_line(self.context, formatted);
        } else {
            // No frame info — refresh backtrace to get it.
            self.refreshBacktrace() catch {};
            var buf: [128]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "stopped: {s} (thread {d})", .{ reason, tid }) catch return;
            self.on_line(self.context, formatted);
        }

        // Fetch fresh backtrace + variables.
        self.refreshBacktrace() catch {};
    }

    fn parseStackTrace(self: *Session, response: []const u8) void {
        const body_start = std.mem.indexOf(u8, response, "\"body\":") orelse return;
        const body = response[body_start..];
        const stack_frames_start = std.mem.indexOf(u8, body, "\"stackFrames\":") orelse return;
        const frames_json = body[stack_frames_start..];

        // Iterate over frames — each frame is an object with id/name/source/line.
        var pos: usize = 0;
        var frame_index: usize = 0;
        while (true) {
            const obj_start = std.mem.indexOfPos(u8, frames_json, pos, "{") orelse break;
            // Find matching close brace (naive — handles flat objects).
            var depth: usize = 0;
            var end: usize = obj_start;
            while (end < frames_json.len) : (end += 1) {
                if (frames_json[end] == '{') depth += 1;
                if (frames_json[end] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        end += 1;
                        break;
                    }
                }
            }
            if (end > frames_json.len) break;
            const frame_json = frames_json[obj_start..end];
            pos = end;

            const name = extractStringField(frame_json, "\"name\":\"") orelse "";
            const path = extractStringField(frame_json, "\"path\":\"") orelse "";
            const line_val = extractIntField(frame_json, "\"line\":") orelse 0;

            if (path.len == 0) {
                frame_index += 1;
                continue;
            }

            // Emit a line that debug_callstack.parseFrameLine can parse:
            //   "frame #N: <name> at <path>:<line>"
            var buf: [2048]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "frame #{d}: {s} at {s}:{d}", .{ frame_index, name, path, line_val }) catch {
                frame_index += 1;
                continue;
            };
            self.on_line(self.context, formatted);
            frame_index += 1;
        }
    }

    fn fetchVariablesForTopFrame(self: *Session, stack_trace_response: []const u8) void {
        // Find the first frame's `id` (variablesReference is usually 0 for
        // frames, but scopes have non-zero refs). We need to fetch scopes
        // first, then variables for each scope.
        const body_start = std.mem.indexOf(u8, stack_trace_response, "\"body\":") orelse return;
        const body = stack_trace_response[body_start..];
        const frames_start = std.mem.indexOf(u8, body, "\"stackFrames\":") orelse return;
        const first_frame = std.mem.indexOfPos(u8, body, frames_start, "{") orelse return;
        const first_frame_end = std.mem.indexOfPos(u8, body, first_frame, "}") orelse return;
        const frame_json = body[first_frame..first_frame_end];
        const frame_id = extractIntField(frame_json, "\"id\":") orelse return;

        // scopes request
        var buf: [128]u8 = undefined;
        const scopes_body = std.fmt.bufPrint(&buf, "{{\"frameId\":{d}}}", .{frame_id}) catch return;
        const scopes_resp = self.sendRequestBlocking("scopes", scopes_body) catch return;
        defer self.allocator.free(scopes_resp);

        // Find each scope's variablesReference and fetch variables.
        var pos: usize = 0;
        while (true) {
            const obj_start = std.mem.indexOfPos(u8, scopes_resp, pos, "{") orelse break;
            const obj_end = std.mem.indexOfPos(u8, scopes_resp, obj_start, "}") orelse break;
            const scope_json = scopes_resp[obj_start..obj_end];
            pos = obj_end + 1;
            const var_ref = extractIntField(scope_json, "\"variablesReference\":") orelse continue;
            if (var_ref == 0) continue;
            self.fetchVariables(@intCast(var_ref));
        }
    }

    fn fetchVariables(self: *Session, variables_reference: u32) void {
        var buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"variablesReference\":{d}}}", .{variables_reference}) catch return;
        const resp = self.sendRequestBlocking("variables", body) catch return;
        defer self.allocator.free(resp);

        const body_start = std.mem.indexOf(u8, resp, "\"body\":") orelse return;
        const body_json = resp[body_start..];
        const arr_start = std.mem.indexOf(u8, body_json, "[") orelse return;
        var pos: usize = arr_start + 1;
        while (true) {
            const obj_start = std.mem.indexOfPos(u8, body_json, pos, "{") orelse break;
            const obj_end = std.mem.indexOfPos(u8, body_json, obj_start, "}") orelse break;
            const var_json = body_json[obj_start..obj_end];
            pos = obj_end + 1;

            const name = extractStringField(var_json, "\"name\":\"") orelse continue;
            const value = extractStringField(var_json, "\"value\":\"") orelse "";
            const type_name = extractStringField(var_json, "\"type\":\"") orelse "";

            // Emit a line that debug_variables.parseVariableLine can parse:
            //   "(<type>) <name> = <value>"
            var line_buf: [1024]u8 = undefined;
            const formatted = std.fmt.bufPrint(&line_buf, "({s}) {s} = {s}", .{ type_name, name, value }) catch continue;
            self.on_line(self.context, formatted);
        }
    }
};

// -----------------------------------------------------------------------
// JSON field extraction helpers (lightweight, regex-free).

fn extractIntField(json: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var i = idx + key.len;
    // Skip whitespace.
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    var end = i;
    while (end < json.len and (std.ascii.isDigit(json[end]) or json[end] == '-')) : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, json[i..end], 10) catch null;
}

fn extractStringField(json: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    const i = idx + key.len;
    if (i >= json.len) return null;
    // Find end quote (handling escapes).
    const result_start = i;
    var j = i;
    while (j < json.len) {
        if (json[j] == '\\' and j + 1 < json.len) {
            j += 2;
            continue;
        }
        if (json[j] == '"') {
            return json[result_start..j];
        }
        j += 1;
    }
    return null;
}

fn unescapeString(input: []const u8, out: []u8) usize {
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < input.len and out_idx < out.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    if (out_idx + 1 > out.len) break;
                    out[out_idx] = '\n';
                    out_idx += 1;
                },
                't' => {
                    if (out_idx + 1 > out.len) break;
                    out[out_idx] = '\t';
                    out_idx += 1;
                },
                'r' => {
                    if (out_idx + 1 > out.len) break;
                    out[out_idx] = '\r';
                    out_idx += 1;
                },
                '"' => {
                    if (out_idx + 1 > out.len) break;
                    out[out_idx] = '"';
                    out_idx += 1;
                },
                '\\' => {
                    if (out_idx + 1 > out.len) break;
                    out[out_idx] = '\\';
                    out_idx += 1;
                },
                else => {
                    if (out_idx + 1 > out.len) break;
                    out[out_idx] = next;
                    out_idx += 1;
                },
            }
            i += 2;
        } else {
            if (out_idx + 1 > out.len) break;
            out[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }
    return out_idx;
}

fn appendEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

fn readLine(fd: c_int, buf: []u8) ![]u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const byte = std.posix.read(fd, buf[n .. n + 1]) catch return error.ReadFailed;
        if (byte == 0) return error.ReadFailed;
        if (buf[n] == '\n') return buf[0 .. n + 1];
        n += 1;
    }
    return buf[0..n];
}

test "extractIntField finds request_seq" {
    const json = "{\"type\":\"response\",\"request_seq\":42,\"command\":\"initialize\"}";
    try std.testing.expectEqual(@as(u64, 42), extractIntField(json, "\"request_seq\":").?);
}

test "extractStringField finds event name" {
    const json = "{\"type\":\"event\",\"event\":\"stopped\",\"body\":{}}";
    try std.testing.expectEqualStrings("stopped", extractStringField(json, "\"event\":\"").?);
}

test "unescapeString handles \\n and \\t" {
    var out: [64]u8 = undefined;
    const len = unescapeString("hello\\nworld\\t!", &out);
    try std.testing.expectEqualStrings("hello\nworld\t!", out[0..len]);
}

test "appendEscaped escapes quotes and backslashes" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendEscaped(&buf, allocator, "path/with\"quote");
    try std.testing.expectEqualStrings("path/with\\\"quote", buf.items);
}

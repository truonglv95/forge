const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const registry = @import("registry.zig");
const diagnostics = @import("diagnostics.zig");
const process_spawn = @import("forge-util").process_spawn;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});
const core = @import("forge-core");
const telemetry = core.telemetry;

pub const SessionError = error{
    SpawnFailed,
    WriteFailed,
    ReadFailed,
    ResponseTooLarge,
    InvalidConfig,
    OutOfMemory,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    language_id: []const u8,
    child: process_spawn.Child,
    initialized: bool = false,
    supports_semantic_tokens: bool = false,
    supports_workspace_symbol: bool = false,
    next_id: i32 = 1,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: registry.ServerConfig,
        workspace_path: []const u8,
    ) SessionError!Session {
        _ = io;
        if (config.server.len == 0) return error.InvalidConfig;

        var argv: std.ArrayList([]const u8) = .empty;
        errdefer argv.deinit(allocator);
        try argv.append(allocator, config.server);
        if (config.args.len > 0) {
            var parts = std.mem.tokenizeScalar(u8, config.args, ' ');
            while (parts.next()) |part| {
                if (part.len > 0) try argv.append(allocator, part);
            }
        }

        var child = process_spawn.spawn(allocator, argv.items, .{
            .cwd = workspace_path,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch |err| {
            std.debug.print("[lsp][session] spawn failed language={s} server={s} args={s} cwd={s} error={}\n", .{
                config.language_id,
                config.server,
                config.args,
                workspace_path,
                err,
            });
            return error.SpawnFailed;
        };
        if (childExited(child.pid)) {
            std.debug.print("[lsp][session] server exited immediately language={s} server={s} cwd={s}\n", .{
                config.language_id,
                config.server,
                workspace_path,
            });
            child.deinit();
            return error.SpawnFailed;
        }
        std.debug.print("[lsp][session] started language={s} server={s} cwd={s}\n", .{
            config.language_id,
            config.server,
            workspace_path,
        });

        return .{
            .allocator = allocator,
            .workspace_path = try allocator.dupe(u8, workspace_path),
            .language_id = try allocator.dupe(u8, config.language_id),
            .child = child,
        };
    }

    pub fn deinit(self: *Session, io: std.Io) void {
        _ = io;
        self.child.deinit();
        self.allocator.free(self.workspace_path);
        self.allocator.free(self.language_id);
        self.* = undefined;
    }

    pub fn sendRawRequest(self: *Session, request_json: []const u8, response_out: []u8) SessionError!usize {
        var span = telemetry.startSpan("lsp", "sendRawRequest");
        defer span.end();
        if (!self.initialized) {
            const init_id = self.next_id;
            self.next_id += 1;
            const root_uri = diagnostics.fileUri(self.allocator, self.workspace_path, "") catch return error.OutOfMemory;
            defer self.allocator.free(root_uri);
            const init_req = try std.fmt.allocPrint(self.allocator,
                \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"processId":null,"clientInfo":{{"name":"Forge IDE","version":"0.1.0"}},"rootUri":"{s}","workspaceFolders":[{{"uri":"{s}","name":"workspace"}}],"capabilities":{{"workspace":{{"symbol":{{"dynamicRegistration":true}}}}}}}}}}
            , .{ init_id, root_uri, root_uri });
            defer self.allocator.free(init_req);
            try self.writeMessage(init_req);
            const init_resp = try self.readResponseForId(init_id, 1024 * 1024);
            defer self.allocator.free(init_resp);
            if (init_resp.len == 0) return error.ReadFailed;

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, init_resp, .{}) catch null;
            if (parsed != null) {
                defer parsed.?.deinit();
                const root = parsed.?.value;
                if (root == .object) {
                    if (root.object.get("result")) |result| {
                        if (result == .object) {
                            if (result.object.get("capabilities")) |caps| {
                                if (caps == .object) {
                                    self.supports_semantic_tokens = caps.object.contains("semanticTokensProvider");
                                    self.supports_workspace_symbol = caps.object.contains("workspaceSymbolProvider");
                                }
                            }
                        }
                    }
                }
            }

            const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
            try self.writeMessage(initialized);
            self.initialized = true;
        }

        try self.writeMessage(request_json);
        const expected_id = requestId(request_json) orelse return 0;

        const response = try self.readResponseForId(expected_id, response_out.len);
        defer self.allocator.free(response);
        if (response.len > response_out.len) return error.ResponseTooLarge;
        @memcpy(response_out[0..response.len], response);
        return response.len;
    }

    fn writeMessage(self: *Session, payload: []const u8) SessionError!void {
        const framed = jsonrpc.encodeMessage(self.allocator, payload) catch return error.OutOfMemory;
        defer self.allocator.free(framed);
        self.child.writeAll(framed) catch return error.WriteFailed;
    }

    fn readResponse(self: *Session, max_payload: usize) SessionError![]u8 {
        return jsonrpc.readMessageFd(self.child.stdout_fd, self.allocator, max_payload) catch |err| switch (err) {
            error.PayloadTooLarge => error.ResponseTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            error.ReadTimeout => error.ReadFailed,
            else => error.ReadFailed,
        };
    }

    fn readResponseForId(self: *Session, id: i64, max_payload: usize) SessionError![]u8 {
        var skipped: u8 = 0;
        while (skipped < 32) : (skipped += 1) {
            const response = try self.readResponse(max_payload);
            if (responseMatchesId(self.allocator, response, id)) return response;
            self.allocator.free(response);
        }
        return error.ReadFailed;
    }

    fn childExited(pid: c.pid_t) bool {
        if (pid <= 0) return true;
        var status: c_int = 0;
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        return waited != 0;
    }

    fn requestId(payload: []const u8) ?i64 {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return null;
        const id = root.object.get("id") orelse return null;
        return switch (id) {
            .integer => |value| value,
            else => null,
        };
    }

    fn responseMatchesId(allocator: std.mem.Allocator, payload: []const u8, expected_id: i64) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return false;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return false;
        const id = root.object.get("id") orelse return false;
        return switch (id) {
            .integer => |value| value == expected_id,
            else => false,
        };
    }
};

test "session extracts json-rpc request ids" {
    try std.testing.expectEqual(@as(?i64, 42), Session.requestId("{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"x\"}"));
    try std.testing.expectEqual(@as(?i64, null), Session.requestId("{\"jsonrpc\":\"2.0\",\"method\":\"x\"}"));
}

test "session response id matching ignores notifications" {
    try std.testing.expect(!Session.responseMatchesId(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{}}", 7));
    try std.testing.expect(Session.responseMatchesId(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":null}", 7));
    try std.testing.expect(!Session.responseMatchesId(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":null}", 7));
}

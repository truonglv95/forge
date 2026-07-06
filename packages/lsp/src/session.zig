const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const registry = @import("registry.zig");
const diagnostics = @import("diagnostics.zig");
const process_spawn = @import("forge-util").process_spawn;

const c = @cImport({
    @cInclude("sys/wait.h");
});

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
        }) catch return error.SpawnFailed;
        if (childExited(child.pid)) {
            child.deinit();
            return error.SpawnFailed;
        }

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
        if (!self.initialized) {
            const init_id = self.next_id;
            self.next_id += 1;
            const root_uri = diagnostics.fileUri(self.allocator, self.workspace_path, "") catch return error.OutOfMemory;
            defer self.allocator.free(root_uri);
            const init_req = try std.fmt.allocPrint(self.allocator,
                \\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"processId":null,"rootUri":"{s}","capabilities":{{}}}}}}
            , .{ init_id, root_uri });
            defer self.allocator.free(init_req);
            try self.writeMessage(init_req);
            const init_resp = try self.readResponse(65536);
            defer self.allocator.free(init_resp);
            if (init_resp.len == 0) return error.ReadFailed;

            const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
            try self.writeMessage(initialized);
            self.initialized = true;
        }

        try self.writeMessage(request_json);
        if (!expectsResponse(request_json)) return 0;

        const response = try self.readResponse(response_out.len);
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

    fn childExited(pid: c.pid_t) bool {
        if (pid <= 0) return true;
        var status: c_int = 0;
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        return waited != 0;
    }

    fn expectsResponse(payload: []const u8) bool {
        return std.mem.indexOf(u8, payload, "\"id\":") != null;
    }
};

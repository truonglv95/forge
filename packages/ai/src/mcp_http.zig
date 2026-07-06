const std = @import("std");
const mcp_config = @import("mcp_config.zig");

pub const HttpError = error{
    RequestFailed,
    ProtocolError,
    OutOfMemory,
};

pub const HttpSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []mcp_config.Header,
    session_id: ?[]u8 = null,
    next_id: i64 = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, url: []const u8, headers: []mcp_config.Header) HttpError!HttpSession {
        var owned_headers: std.ArrayList(mcp_config.Header) = .empty;
        errdefer {
            for (owned_headers.items) |hdr| {
                allocator.free(hdr.name);
                allocator.free(hdr.value);
            }
            owned_headers.deinit(allocator);
        }
        for (headers) |hdr| {
            try owned_headers.append(allocator, .{
                .name = try allocator.dupe(u8, hdr.name),
                .value = try allocator.dupe(u8, hdr.value),
            });
        }
        return .{
            .allocator = allocator,
            .io = io,
            .url = try allocator.dupe(u8, url),
            .headers = try owned_headers.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *HttpSession) void {
        self.allocator.free(self.url);
        for (self.headers) |hdr| {
            self.allocator.free(hdr.name);
            self.allocator.free(hdr.value);
        }
        self.allocator.free(self.headers);
        if (self.session_id) |sid| self.allocator.free(sid);
        self.* = undefined;
    }

    pub fn request(self: *HttpSession, method: []const u8, params_json: []const u8) HttpError![]u8 {
        const id = self.next_id;
        self.next_id += 1;
        const body = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json });
        defer self.allocator.free(body);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(self.allocator);
        try extra_headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" });
        try extra_headers.append(self.allocator, .{ .name = "Accept", .value = "application/json, text/event-stream" });
        if (self.session_id) |sid| {
            const header_val = try std.fmt.allocPrint(self.allocator, "{s}", .{sid});
            defer self.allocator.free(header_val);
            try extra_headers.append(self.allocator, .{ .name = "Mcp-Session-Id", .value = header_val });
        }
        for (self.headers) |hdr| {
            try extra_headers.append(self.allocator, .{ .name = hdr.name, .value = hdr.value });
        }

        var response_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer response_alloc.deinit();

        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = body,
            .extra_headers = extra_headers.items,
            .response_writer = &response_alloc.writer,
        }) catch return error.RequestFailed;

        if (result.status != .ok) return error.RequestFailed;

        const response_body = response_alloc.writer.buffer[0..response_alloc.writer.end];
        return try parseResponse(self.allocator, response_body, id);
    }

    fn parseResponse(allocator: std.mem.Allocator, body: []const u8, id: i64) HttpError![]u8 {
        if (std.mem.startsWith(u8, body, "event:") or std.mem.indexOf(u8, body, "data:") != null) {
            var lines = std.mem.splitScalar(u8, body, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, "\r");
                if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
                const payload = std.mem.trim(u8, trimmed["data:".len..], " ");
                if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;
                return try parseJsonRpcResult(allocator, payload, id);
            }
            return error.ProtocolError;
        }
        return parseJsonRpcResult(allocator, body, id);
    }

    fn parseJsonRpcResult(allocator: std.mem.Allocator, json_text: []const u8, id: i64) HttpError![]u8 {
        const Response = struct {
            id: ?std.json.Value = null,
            result: ?std.json.Value = null,
            @"error": ?std.json.Value = null,
        };
        var parsed = std.json.parseFromSlice(Response, allocator, json_text, .{ .ignore_unknown_fields = true }) catch return error.ProtocolError;
        defer parsed.deinit();
        if (parsed.value.@"error" != null) return error.ProtocolError;
        if (parsed.value.id) |id_val| {
            const matches = switch (id_val) {
                .integer => |n| n == id,
                .float => |n| @as(i64, @intFromFloat(n)) == id,
                else => false,
            };
            if (!matches) return error.ProtocolError;
        }
        const result_val = parsed.value.result orelse return error.ProtocolError;
        return std.json.Stringify.valueAlloc(allocator, result_val, .{}) catch return error.OutOfMemory;
    }
};

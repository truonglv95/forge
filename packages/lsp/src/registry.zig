const std = @import("std");
const root = @import("root.zig");

pub const ServerConfig = struct {
    language_id: []const u8,
    server: []const u8,
    args: []const u8,
    file_pattern: []const u8,
    extension_id: []const u8,
    state: root.ServerState = .configured,
};

pub const Registry = struct {
    servers: std.ArrayList(ServerConfig),

    pub fn init(_: std.mem.Allocator) Registry {
        return .{ .servers = .empty };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.servers.items) |item| {
            allocator.free(item.language_id);
            allocator.free(item.server);
            allocator.free(item.args);
            allocator.free(item.file_pattern);
            allocator.free(item.extension_id);
        }
        self.servers.deinit(allocator);
    }

    pub fn clear(self: *Registry, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.* = init(allocator);
    }

    pub fn add(self: *Registry, allocator: std.mem.Allocator, config: ServerConfig) !void {
        try self.servers.append(allocator, .{
            .language_id = try allocator.dupe(u8, config.language_id),
            .server = try allocator.dupe(u8, config.server),
            .args = try allocator.dupe(u8, config.args),
            .file_pattern = try allocator.dupe(u8, config.file_pattern),
            .extension_id = try allocator.dupe(u8, config.extension_id),
            .state = config.state,
        });
    }

    pub fn findForPath(self: *const Registry, path: []const u8) ?*const ServerConfig {
        var best: ?*const ServerConfig = null;
        for (self.servers.items) |*server| {
            if (matchesPattern(path, server.file_pattern)) {
                best = server;
            }
        }
        return best;
    }

    pub fn findByLanguageId(self: *const Registry, language_id: []const u8) ?ServerConfig {
        for (self.servers.items) |server| {
            if (std.mem.eql(u8, server.language_id, language_id)) return server;
        }
        return null;
    }
};

fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[1..];
        return path.len >= suffix.len and std.mem.endsWith(u8, path, suffix);
    }
    return std.mem.endsWith(u8, path, pattern);
}

test "registry matches glob file patterns" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit(allocator);

    try registry.add(allocator, .{
        .language_id = "zig",
        .server = "zig",
        .args = "language-server",
        .file_pattern = "*.zig",
        .extension_id = "forge.lsp.zig",
    });

    try std.testing.expect(registry.findForPath("src/main.zig") != null);
    try std.testing.expect(registry.findForPath("README.md") == null);
}

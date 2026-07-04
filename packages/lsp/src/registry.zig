const std = @import("std");
const forge_util = @import("forge-util");
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
    mutex: forge_util.sync.Mutex = .{},

    pub fn init(_: std.mem.Allocator) Registry {
        return .{ .servers = .empty };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.freeServers(allocator);
    }

    fn freeServers(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.servers.items) |item| {
            allocator.free(item.language_id);
            allocator.free(item.server);
            allocator.free(item.args);
            allocator.free(item.file_pattern);
            allocator.free(item.extension_id);
        }
        self.servers.deinit(allocator);
        self.servers = .empty;
    }

    pub fn clear(self: *Registry, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.freeServers(allocator);
    }

    pub fn add(self: *Registry, allocator: std.mem.Allocator, config: ServerConfig) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.servers.append(allocator, .{
            .language_id = try allocator.dupe(u8, config.language_id),
            .server = try allocator.dupe(u8, config.server),
            .args = try allocator.dupe(u8, config.args),
            .file_pattern = try allocator.dupe(u8, config.file_pattern),
            .extension_id = try allocator.dupe(u8, config.extension_id),
            .state = config.state,
        });
    }

    pub fn findForPath(self: *Registry, path: []const u8) ?*const ServerConfig {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.findForPathUnlocked(path);
    }

    pub fn findForPathUnlocked(self: *const Registry, path: []const u8) ?*const ServerConfig {
        var best: ?*const ServerConfig = null;
        for (self.servers.items) |*server| {
            if (matchesPattern(path, server.file_pattern)) {
                best = server;
            }
        }
        return best;
    }

    pub fn findByLanguageId(self: *Registry, language_id: []const u8) ?ServerConfig {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.servers.items) |server| {
            if (std.mem.eql(u8, server.language_id, language_id)) return server;
        }
        return null;
    }

    pub fn copyMatchForPath(self: *Registry, allocator: std.mem.Allocator, path: []const u8) !?ServerConfig {
        self.mutex.lock();
        defer self.mutex.unlock();
        const match = self.findForPathUnlocked(path) orelse return null;
        return .{
            .language_id = try allocator.dupe(u8, match.language_id),
            .server = try allocator.dupe(u8, match.server),
            .args = try allocator.dupe(u8, match.args),
            .file_pattern = try allocator.dupe(u8, match.file_pattern),
            .extension_id = try allocator.dupe(u8, match.extension_id),
            .state = match.state,
        };
    }

    pub fn freeConfig(allocator: std.mem.Allocator, config: ServerConfig) void {
        allocator.free(config.language_id);
        allocator.free(config.server);
        allocator.free(config.args);
        allocator.free(config.file_pattern);
        allocator.free(config.extension_id);
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

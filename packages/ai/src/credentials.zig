const std = @import("std");

pub const gemini_env_vars = &[_][]const u8{ "GEMINI_API_KEY", "GOOGLE_API_KEY" };
pub const keychain_service = "forge-gemini";
pub const keychain_account = "default";

pub const Credentials = struct {
    allocator: std.mem.Allocator,
    api_key: []u8,
    source: Source,

    pub const Source = enum {
        environment,
        keychain,
    };

    pub fn loadFromEnvMap(
        allocator: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        env_var: []const u8,
    ) !Credentials {
        const value = environ_map.get(env_var) orelse return error.NotFound;
        return Credentials{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, value),
            .source = .environment,
        };
    }

    /// Tries GEMINI_API_KEY / GOOGLE_API_KEY, then macOS Keychain (`forge-gemini` / `default`).
    pub fn loadGemini(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: ?*const std.process.Environ.Map,
    ) !Credentials {
        if (environ_map) |map| {
            for (gemini_env_vars) |env_var| {
                if (loadFromEnvMap(allocator, map, env_var)) |creds| {
                    return creds;
                } else |err| switch (err) {
                    error.NotFound => {},
                    else => return err,
                }
            }
        }

        return loadFromKeychain(allocator, io, keychain_service, keychain_account);
    }

    pub fn loadFromKeychain(
        allocator: std.mem.Allocator,
        io: std.Io,
        service: []const u8,
        account: []const u8,
    ) !Credentials {
        if (@import("builtin").os.tag != .macos) return error.NotFound;

        var child = try std.process.spawn(io, .{
            .argv = &.{
                "security",
                "find-generic-password",
                "-s",
                service,
                "-a",
                account,
                "-w",
            },
            .cwd = .inherit,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);

        const stdout = child.stdout orelse return error.NotFound;
        var reader = stdout.reader(io, &.{});
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        _ = reader.interface.streamRemaining(&output.writer) catch return error.NotFound;

        const term = try child.wait(io);
        switch (term) {
            .exited => |code| {
                if (code != 0) return error.NotFound;
            },
            else => return error.NotFound,
        }

        const raw = output.writer.buffer[0..output.writer.end];
        const trimmed = std.mem.trim(u8, raw, "\r\n");
        if (trimmed.len == 0) return error.NotFound;

        return Credentials{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, trimmed),
            .source = .keychain,
        };
    }

    pub fn deinit(self: *Credentials) void {
        std.crypto.secureZero(u8, self.api_key);
        self.allocator.free(self.api_key);
    }
};

test "Credentials secure zeroing" {
    const allocator = std.testing.allocator;

    const dummy_key = try allocator.alloc(u8, 12);
    std.mem.copyForwards(u8, dummy_key, "secret123456");

    var creds = Credentials{
        .allocator = allocator,
        .api_key = dummy_key,
        .source = .environment,
    };

    creds.deinit();
}

test "Credentials load from environ map" {
    const allocator = std.testing.allocator;
    var map = std.process.Environ.Map.init(allocator);
    defer map.deinit();

    try map.put("GEMINI_API_KEY", "test-key-value");

    var creds = try Credentials.loadFromEnvMap(allocator, &map, "GEMINI_API_KEY");
    defer creds.deinit();

    try std.testing.expectEqualStrings("test-key-value", creds.api_key);
    try std.testing.expect(creds.source == .environment);
}

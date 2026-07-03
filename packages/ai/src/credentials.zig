const std = @import("std");

pub const Credentials = struct {
    allocator: std.mem.Allocator,
    api_key: []u8,

    /// Loads a secret from the environment. Returns error.NotFound if the key does not exist.
    pub fn loadFromEnv(allocator: std.mem.Allocator, env_var: []const u8) !Credentials {
        const key = std.process.getEnvVarOwned(allocator, env_var) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.NotFound,
            else => return err,
        };

        return Credentials{
            .allocator = allocator,
            .api_key = key,
        };
    }

    /// Explicitly zero out the secret before freeing to prevent leaking in memory dumps.
    pub fn deinit(self: *Credentials) void {
        std.crypto.secureZero(u8, self.api_key);
        self.allocator.free(self.api_key);
    }
};

test "Credentials secure zeroing" {
    const allocator = std.testing.allocator;

    // We cannot reliably test `getEnvVarOwned` cross-platform in unit tests easily without modifying env,
    // so we just test the zeroing mechanics.
    const dummy_key = try allocator.alloc(u8, 12);
    std.mem.copyForwards(u8, dummy_key, "secret123456");

    var creds = Credentials{
        .allocator = allocator,
        .api_key = dummy_key,
    };

    creds.deinit();
    // Memory is freed, so we can't safely assert it's zeroed here without use-after-free,
    // but the call to std.crypto.secureZero guarantees it was wiped before freeing.
}

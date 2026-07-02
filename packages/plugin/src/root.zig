//! Plugin compatibility contracts. Runtime implementation is deferred until M6.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.plugin;

pub const ApiVersion = struct {
    major: u16,
    minor: u16,

    pub fn isCompatible(host: ApiVersion, guest: ApiVersion) bool {
        return host.major == guest.major and host.minor >= guest.minor;
    }
};

test "plugin API compatibility requires matching major versions" {
    const host = ApiVersion{ .major = 1, .minor = 2 };
    try std.testing.expect(host.isCompatible(.{ .major = 1, .minor = 1 }));
    try std.testing.expect(!host.isCompatible(.{ .major = 2, .minor = 0 }));
}

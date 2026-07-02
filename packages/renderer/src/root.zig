//! Renderer contracts. Backend selection will follow the M0 renderer spike.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.renderer;

pub const Backend = enum {
    metal,
    vulkan,
    direct3d12,
    software,
};

pub fn preferredBackend(os: std.Target.Os.Tag) Backend {
    return switch (os) {
        .macos, .ios => .metal,
        .windows => .direct3d12,
        .linux => .vulkan,
        else => .software,
    };
}

test "macOS prefers Metal" {
    try std.testing.expectEqual(Backend.metal, preferredBackend(.macos));
}

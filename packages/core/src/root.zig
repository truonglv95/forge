//! Stable domain types shared across Forge subsystems.

const std = @import("std");
const util = @import("forge-util");

pub const version = "0.1.0-dev";

pub const Subsystem = enum {
    kernel,
    workspace,
    editor,
    renderer,
    lsp,
    ai,
    plugin,

    pub fn parse(value: []const u8) ?Subsystem {
        inline for (std.meta.fields(Subsystem)) |field| {
            if (util.eqlIgnoreAsciiCase(value, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

pub const CommandId = struct {
    value: u64,

    pub fn next(self: CommandId) CommandId {
        return .{ .value = self.value +| 1 };
    }
};

test "subsystem names are parsed case-insensitively" {
    try std.testing.expectEqual(Subsystem.workspace, Subsystem.parse("WORKSPACE").?);
    try std.testing.expect(Subsystem.parse("unknown") == null);
}

test "command IDs saturate instead of wrapping" {
    const last = CommandId{ .value = std.math.maxInt(u64) };
    try std.testing.expectEqual(std.math.maxInt(u64), last.next().value);
}

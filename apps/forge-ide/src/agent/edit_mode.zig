const std = @import("std");

pub const Mode = enum {
    review,
    auto_edit,
    trusted,

    pub fn parse(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "review")) return .review;
        if (std.mem.eql(u8, value, "auto_edit")) return .auto_edit;
        if (std.mem.eql(u8, value, "trusted")) return .trusted;
        return null;
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .review => "Review",
            .auto_edit => "Auto Edit",
            .trusted => "Trusted",
        };
    }

    pub fn next(self: Mode) Mode {
        return switch (self) {
            .review => .auto_edit,
            .auto_edit => .trusted,
            .trusted => .review,
        };
    }
};

test "Mode parses persisted values" {
    try std.testing.expectEqual(Mode.review, Mode.parse("review").?);
    try std.testing.expectEqual(Mode.auto_edit, Mode.parse("auto_edit").?);
    try std.testing.expectEqual(Mode.trusted, Mode.parse("trusted").?);
    try std.testing.expect(Mode.parse("unknown") == null);
}

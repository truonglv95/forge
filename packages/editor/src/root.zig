//! Editor-domain value types. Buffer implementation begins in M2.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.editor;

pub const Position = struct {
    line: u32,
    column: u32,
};

pub const TextRange = struct {
    start: Position,
    end: Position,

    pub fn isEmpty(self: TextRange) bool {
        return std.meta.eql(self.start, self.end);
    }
};

test "text range reports an empty selection" {
    const position = Position{ .line = 3, .column = 7 };
    try std.testing.expect((TextRange{ .start = position, .end = position }).isEmpty());
}

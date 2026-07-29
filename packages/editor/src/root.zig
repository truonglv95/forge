//! Editor-domain value types and text buffer.

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

pub const buffer = @import("buffer.zig");
pub const Buffer = buffer.Buffer;
pub const Cursor = buffer.Cursor;
pub const search = @import("search.zig");
pub const Match = search.Match;
pub const document = @import("document.zig");
pub const Document = document.Document;
pub const TabGroup = document.TabGroup;
pub const multi_cursor = @import("multi_cursor.zig");
pub const MultiCursor = multi_cursor.MultiCursor;
pub const folding = @import("folding.zig");
pub const FoldController = folding.FoldController;
pub const FoldRange = folding.FoldRange;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(buffer);
    std.testing.refAllDecls(document);
    std.testing.refAllDecls(search);
    std.testing.refAllDecls(multi_cursor);
    std.testing.refAllDecls(folding);
}

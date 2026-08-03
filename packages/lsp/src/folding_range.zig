const std = @import("std");

/// Folding range support (textDocument/foldingRange).
/// Returns foldable ranges for code folding in the editor.
pub const FoldingRange = struct {
    start_line: u32,
    end_line: u32,
    start_character: ?u32 = null,
    end_character: ?u32 = null,
    kind: ?[]const u8 = null,
};

pub const FoldingRangeList = struct {
    items: []FoldingRange,

    pub fn deinit(self: *FoldingRangeList, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            if (item.kind) |k| allocator.free(k);
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn buildFoldingRangeRequest(allocator: std.mem.Allocator, request_id: i32, uri: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/foldingRange","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{ request_id, uri });
}

pub fn parseFoldingRangeResponse(allocator: std.mem.Allocator, response_json: []const u8) !FoldingRangeList {
    const Item = struct {
        startLine: u32,
        endLine: u32,
        startCharacter: ?u32 = null,
        endCharacter: ?u32 = null,
        kind: ?[]const u8 = null,
    };
    const Wrapper = struct { result: ?[]const Item = null };
    var parsed = try std.json.parseFromSlice(Wrapper, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const items = parsed.value.result orelse {
        return .{ .items = try allocator.alloc(FoldingRange, 0) };
    };

    const out = try allocator.alloc(FoldingRange, items.len);
    for (items, 0..) |item, i| {
        out[i] = .{
            .start_line = item.startLine,
            .end_line = item.endLine,
            .start_character = item.startCharacter,
            .end_character = item.endCharacter,
            .kind = if (item.kind) |k| try allocator.dupe(u8, k) else null,
        };
    }
    return .{ .items = out };
}

test "buildFoldingRangeRequest includes method" {
    const allocator = std.testing.allocator;
    const msg = try buildFoldingRangeRequest(allocator, 1, "file:///test.zig");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/foldingRange\"") != null);
}

test "parseFoldingRangeResponse extracts ranges" {
    const allocator = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[{"startLine":0,"endLine":5,"kind":"region"},{"startLine":2,"endLine":4}]}
    ;
    var list = try parseFoldingRangeResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(u32, 0), list.items[0].start_line);
    try std.testing.expectEqual(@as(u32, 5), list.items[0].end_line);
    try std.testing.expectEqualStrings("region", list.items[0].kind.?);
}

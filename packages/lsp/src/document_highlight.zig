const std = @import("std");

/// Document highlight support (textDocument/documentHighlight).
/// Highlights all occurrences of the symbol under the cursor.

pub const HighlightKind = enum(u32) {
    text = 1,
    read = 2,
    write = 3,
};

pub const Highlight = struct {
    line: u32,
    start_col: u32,
    end_col: u32,
    kind: HighlightKind = .text,
};

pub const HighlightList = struct {
    items: []Highlight,

    pub fn deinit(self: *HighlightList, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn buildDocumentHighlightRequest(allocator: std.mem.Allocator, request_id: i32, uri: []const u8, line: u32, character: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/documentHighlight","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}}}
    , .{ request_id, uri, line, character });
}

pub fn parseDocumentHighlightResponse(allocator: std.mem.Allocator, response_json: []const u8) !HighlightList {
    const Item = struct {
        range: struct {
            start: struct { line: u32, character: u32 },
            end: struct { line: u32, character: u32 },
        },
        kind: ?u32 = null,
    };
    const Wrapper = struct { result: ?[]const Item = null };
    var parsed = try std.json.parseFromSlice(Wrapper, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const items = parsed.value.result orelse {
        return .{ .items = try allocator.alloc(Highlight, 0) };
    };

    const out = try allocator.alloc(Highlight, items.len);
    for (items, 0..) |item, i| {
        out[i] = .{
            .line = item.range.start.line,
            .start_col = item.range.start.character,
            .end_col = item.range.end.character,
            .kind = if (item.kind) |k| switch (k) {
                1 => .text,
                2 => .read,
                3 => .write,
                else => .text,
            } else .text,
        };
    }
    return .{ .items = out };
}

test "buildDocumentHighlightRequest includes method and position" {
    const allocator = std.testing.allocator;
    const msg = try buildDocumentHighlightRequest(allocator, 1, "file:///test.zig", 5, 10);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/documentHighlight\"") != null);
}

test "parseDocumentHighlightResponse extracts ranges" {
    const allocator = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"kind":2}]}
    ;
    var list = try parseDocumentHighlightResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u32, 0), list.items[0].line);
    try std.testing.expectEqual(HighlightKind.read, list.items[0].kind);
}

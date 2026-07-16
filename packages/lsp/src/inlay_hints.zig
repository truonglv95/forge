const std = @import("std");

/// Inlay hints support (textDocument/inlayHint).
/// Provides inline type annotations, parameter names, and other hints
/// directly in the editor.
pub const InlayHintKind = enum(u32) {
    type_hint = 1,
    parameter = 2,
};

pub const InlayHint = struct {
    line: u32,
    character: u32,
    label: []const u8,
    kind: InlayHintKind = .type_hint,
    padding_left: bool = false,
    padding_right: bool = false,
};

pub const InlayHintList = struct {
    items: []InlayHint,

    pub fn deinit(self: *InlayHintList, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.label);
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn buildInlayHintRequest(allocator: std.mem.Allocator, request_id: i32, uri: []const u8, start_line: u32, end_line: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/inlayHint","params":{{"textDocument":{{"uri":"{s}"}},"range":{{"start":{{"line":{d},"character":0}},"end":{{"line":{d},"character":0}}}}}}}}
    , .{ request_id, uri, start_line, end_line });
}

pub fn parseInlayHintResponse(allocator: std.mem.Allocator, response_json: []const u8) !InlayHintList {
    const Item = struct {
        position: struct { line: u32, character: u32 },
        label: []const u8,
        kind: ?u32 = null,
        paddingLeft: ?bool = null,
        paddingRight: ?bool = null,
    };
    const Wrapper = struct { result: ?[]const Item = null };
    var parsed = try std.json.parseFromSlice(Wrapper, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const items = parsed.value.result orelse {
        return .{ .items = try allocator.alloc(InlayHint, 0) };
    };

    const out = try allocator.alloc(InlayHint, items.len);
    for (items, 0..) |item, i| {
        out[i] = .{
            .line = item.position.line,
            .character = item.position.character,
            .label = try allocator.dupe(u8, item.label),
            .kind = if (item.kind) |k| switch (k) {
                1 => .type_hint,
                2 => .parameter,
                else => .type_hint,
            } else .type_hint,
            .padding_left = item.paddingLeft orelse false,
            .padding_right = item.paddingRight orelse false,
        };
    }
    return .{ .items = out };
}

test "buildInlayHintRequest includes method and range" {
    const allocator = std.testing.allocator;
    const msg = try buildInlayHintRequest(allocator, 1, "file:///test.zig", 0, 100);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/inlayHint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"line\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"line\":100") != null);
}

test "parseInlayHintResponse extracts hints" {
    const allocator = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[{"position":{"line":5,"character":10},"label":": u32","kind":1},{"position":{"line":6,"character":0},"label":"name:","kind":2,"paddingRight":true}]}
    ;
    var list = try parseInlayHintResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(u32, 5), list.items[0].line);
    try std.testing.expectEqualStrings(": u32", list.items[0].label);
    try std.testing.expectEqual(InlayHintKind.type_hint, list.items[0].kind);
    try std.testing.expectEqual(InlayHintKind.parameter, list.items[1].kind);
    try std.testing.expect(list.items[1].padding_right);
}

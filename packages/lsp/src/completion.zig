const std = @import("std");
const diagnostics = @import("diagnostics.zig");

pub const Item = struct {
    label: []const u8,
    detail: []const u8,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

pub const List = struct {
    items: []Item,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn buildDidOpenNotification(
    allocator: std.mem.Allocator,
    uri: []const u8,
    language_id: []const u8,
    version: u32,
    text: []const u8,
) ![]const u8 {
    return diagnostics.buildDidOpenNotification(allocator, uri, language_id, version, text);
}

pub fn buildCompletionRequest(
    allocator: std.mem.Allocator,
    id: i32,
    uri: []const u8,
    line: u32,
    character: u32,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/completion","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}}}
    , .{ id, uri, line, character });
}

pub fn parseCompletionResponse(allocator: std.mem.Allocator, response_json: []const u8) !List {
    var list: std.ArrayList(Item) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    var search_from: usize = 0;
    while (search_from < response_json.len) {
        const label_key = std.mem.indexOfPos(u8, response_json, search_from, "\"label\"") orelse break;
        const label = parseQuotedField(response_json, label_key) orelse {
            search_from = label_key + 1;
            continue;
        };

        const detail_key = std.mem.indexOfPos(u8, response_json, label_key, "\"detail\"") orelse label_key;
        const detail = parseQuotedField(response_json, detail_key) orelse "";

        try list.append(allocator, .{
            .label = try allocator.dupe(u8, label),
            .detail = try allocator.dupe(u8, detail),
        });
        search_from = label_key + label.len;
        if (list.items.len >= 64) break;
    }

    return .{ .items = try list.toOwnedSlice(allocator) };
}

fn parseQuotedField(source: []const u8, key_pos: usize) ?[]const u8 {
    const colon = std.mem.indexOfPos(u8, source, key_pos, ":") orelse return null;
    const quote = std.mem.indexOfPos(u8, source, colon, "\"") orelse return null;
    const end = std.mem.indexOfPos(u8, source, quote + 1, "\"") orelse return null;
    return source[quote + 1 .. end];
}

test "parseCompletionResponse extracts labels" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","id":1,"result":{"items":[{"label":"fn main","detail":"() !void"},{"label":"const","detail":"keyword"}]}}
    ;
    var list = try parseCompletionResponse(allocator, json);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("fn main", list.items[0].label);
}

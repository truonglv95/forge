const std = @import("std");
const rename = @import("rename.zig");

pub fn buildFormatRequest(
    allocator: std.mem.Allocator,
    id: i32,
    uri: []const u8,
    tab_size: u32,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/formatting","params":{{"textDocument":{{"uri":"{s}"}},"options":{{"tabSize":{d},"insertSpaces":true}}}}}}
    , .{ id, uri, tab_size });
}

pub fn parseFormatResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]rename.TextEdit {
    const key = std.mem.indexOf(u8, response_json, "\"result\"") orelse return &.{};
    const array_start = std.mem.indexOfPos(u8, response_json, key, "[") orelse return &.{};
    return try parseTextEditArray(allocator, response_json[array_start..]);
}

fn parseTextEditArray(allocator: std.mem.Allocator, slice: []const u8) ![]rename.TextEdit {
    var list: std.ArrayList(rename.TextEdit) = .empty;
    errdefer {
        for (list.items) |*edit| edit.deinit(allocator);
        list.deinit(allocator);
    }

    const array_start = std.mem.indexOf(u8, slice, "[") orelse return try list.toOwnedSlice(allocator);
    var i = array_start + 1;
    while (i < slice.len) {
        const obj_start = std.mem.indexOfPos(u8, slice, i, "{") orelse break;
        const obj_end = findMatchingBrace(slice, obj_start) orelse break;
        const obj = slice[obj_start .. obj_end + 1];

        const range_pos = std.mem.indexOf(u8, obj, "\"range\"") orelse {
            i = obj_end + 1;
            continue;
        };
        const range_obj_start = std.mem.indexOfPos(u8, obj, range_pos, "{") orelse {
            i = obj_end + 1;
            continue;
        };
        const range_obj_end = findMatchingBrace(obj, range_obj_start) orelse {
            i = obj_end + 1;
            continue;
        };
        const range_obj = obj[range_obj_start .. range_obj_end + 1];
        const start_line = parseRangePointField(range_obj, "start", "line") orelse 0;
        const start_char = parseRangePointField(range_obj, "start", "character") orelse 0;
        const end_line = parseRangePointField(range_obj, "end", "line") orelse start_line;
        const end_char = parseRangePointField(range_obj, "end", "character") orelse start_char;
        const new_text_raw = parseStringField(obj, "newText") orelse "";
        const new_text = try allocator.dupe(u8, new_text_raw);

        try list.append(allocator, .{
            .line = start_line,
            .character = start_char,
            .end_line = end_line,
            .end_character = end_char,
            .new_text = new_text,
        });
        i = obj_end + 1;
    }
    return try list.toOwnedSlice(allocator);
}

fn parseRangePointField(range_obj: []const u8, point_key: []const u8, field: []const u8) ?u32 {
    var needle: [16]u8 = undefined;
    const pattern = std.fmt.bufPrint(&needle, "\"{s}\"", .{point_key}) catch return null;
    const point_pos = std.mem.indexOf(u8, range_obj, pattern) orelse return null;
    const point_start = std.mem.indexOfPos(u8, range_obj, point_pos, "{") orelse return null;
    const point_end = findMatchingBrace(range_obj, point_start) orelse return null;
    return parseU32Field(range_obj[point_start .. point_end + 1], field);
}

fn findMatchingBrace(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '{') return null;
    var depth: i32 = 0;
    var in_string = false;
    var escape = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (ch == '\\') escape = true;
            if (ch == '"') in_string = false;
            continue;
        }
        if (ch == '"') {
            in_string = true;
            continue;
        }
        if (ch == '{') depth += 1;
        if (ch == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn parseU32Field(object: []const u8, key: []const u8) ?u32 {
    var needle: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&needle, "\"{s}\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, object, pattern) orelse return null;
    const colon = std.mem.indexOfPos(u8, object, pos + pattern.len, ":") orelse return null;
    var i = colon + 1;
    while (i < object.len and std.ascii.isWhitespace(object[i])) : (i += 1) {}
    var end = i;
    while (end < object.len and object[end] >= '0' and object[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u32, object[i..end], 10) catch null;
}

fn parseStringField(object: []const u8, key: []const u8) ?[]const u8 {
    var needle: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&needle, "\"{s}\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, object, pattern) orelse return null;
    const colon = std.mem.indexOfPos(u8, object, pos + pattern.len, ":") orelse return null;
    var i = colon + 1;
    while (i < object.len and std.ascii.isWhitespace(object[i])) : (i += 1) {}
    if (i >= object.len or object[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < object.len) : (i += 1) {
        if (object[i] == '\\') {
            i += 1;
            continue;
        }
        if (object[i] == '"') return object[start..i];
    }
    return null;
}

test "parse format response extracts text edits" {
    const json =
        \\{"jsonrpc":"2.0","id":1,"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"pub fn"}]}
    ;
    const edits = try parseFormatResponse(std.testing.allocator, json);
    defer {
        for (edits) |*edit| edit.deinit(std.testing.allocator);
        std.testing.allocator.free(edits);
    }
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqualStrings("pub fn", edits[0].new_text);
}

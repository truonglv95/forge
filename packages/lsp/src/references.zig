const std = @import("std");
const navigation = @import("navigation.zig");

pub const LocationList = struct {
    items: []navigation.Location,

    pub fn deinit(self: *LocationList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn buildReferencesRequest(
    allocator: std.mem.Allocator,
    id: i32,
    uri: []const u8,
    line: u32,
    character: u32,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/references","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"context":{{"includeDeclaration":true}}}}}}
    , .{ id, uri, line, character });
}

pub fn parseReferencesResponse(allocator: std.mem.Allocator, response_json: []const u8) !LocationList {
    var list: std.ArrayList(navigation.Location) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    const result_key = std.mem.indexOf(u8, response_json, "\"result\"") orelse {
        return .{ .items = try list.toOwnedSlice(allocator) };
    };
    const array_start = std.mem.indexOfPos(u8, response_json, result_key, "[") orelse {
        return .{ .items = try list.toOwnedSlice(allocator) };
    };

    var i = array_start + 1;
    while (i < response_json.len) {
        const obj_start = std.mem.indexOfPos(u8, response_json, i, "{") orelse break;
        const obj_end = findMatchingBrace(response_json, obj_start) orelse break;
        const obj = response_json[obj_start .. obj_end + 1];

        const uri_raw = parseStringField(obj, "uri") orelse {
            i = obj_end + 1;
            continue;
        };
        const uri = try allocator.dupe(u8, uri_raw);
        errdefer allocator.free(uri);

        const line_val = parseRangeStartField(obj, "line") orelse 0;
        const char_val = parseRangeStartField(obj, "character") orelse 0;

        try list.append(allocator, .{
            .uri = uri,
            .line = line_val,
            .character = char_val,
        });
        i = obj_end + 1;
    }

    return .{ .items = try list.toOwnedSlice(allocator) };
}

fn parseRangeStartField(object: []const u8, field: []const u8) ?u32 {
    const range_pos = std.mem.indexOf(u8, object, "\"range\"") orelse return null;
    const range_obj_start = std.mem.indexOfPos(u8, object, range_pos, "{") orelse return null;
    const range_obj_end = findMatchingBrace(object, range_obj_start) orelse return null;
    const range_obj = object[range_obj_start .. range_obj_end + 1];
    const start_pos = std.mem.indexOf(u8, range_obj, "\"start\"") orelse return null;
    const start_obj_start = std.mem.indexOfPos(u8, range_obj, start_pos, "{") orelse return null;
    const start_obj_end = findMatchingBrace(range_obj, start_obj_start) orelse return null;
    const start_obj = range_obj[start_obj_start .. start_obj_end + 1];
    return parseU32Field(start_obj, field);
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

test "parse references array" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","id":1,"result":[{"uri":"file:///proj/a.zig","range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}}]}
    ;
    var list = try parseReferencesResponse(allocator, json);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u32, 1), list.items[0].line);
}

const std = @import("std");

pub fn buildHoverRequest(
    allocator: std.mem.Allocator,
    id: i32,
    uri: []const u8,
    line: u32,
    character: u32,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/hover","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}}}
    , .{ id, uri, line, character });
}

pub fn parseHoverResponse(allocator: std.mem.Allocator, response_json: []const u8) !?[]const u8 {
    const result = extractResultObject(response_json) orelse return null;

    if (parseStringField(result, "value")) |value| {
        return try allocator.dupe(u8, value);
    }

    const contents = std.mem.indexOf(u8, result, "\"contents\"") orelse return null;
    const slice = result[contents..];

    if (parseStringField(slice, "value")) |value| {
        return try allocator.dupe(u8, value);
    }

    if (parseStringField(slice, "label")) |label| {
        return try allocator.dupe(u8, label);
    }

    const array_start = std.mem.indexOfPos(u8, slice, 0, "[") orelse return null;
    const first_quote = std.mem.indexOfPos(u8, slice, array_start, "\"") orelse return null;
    const end_quote = std.mem.indexOfPos(u8, slice, first_quote + 1, "\"") orelse return null;
    return try allocator.dupe(u8, slice[first_quote + 1 .. end_quote]);
}

fn extractResultObject(json: []const u8) ?[]const u8 {
    const key = std.mem.indexOf(u8, json, "\"result\"") orelse return null;
    const colon = std.mem.indexOfPos(u8, json, key, ":") orelse return null;
    var i = colon + 1;
    while (i < json.len and std.ascii.isWhitespace(json[i])) : (i += 1) {}
    if (i >= json.len) return null;
    if (json[i] == 'n') return null;
    if (json[i] == '{') {
        const end = findMatchingBrace(json, i) orelse return null;
        return json[i .. end + 1];
    }
    return null;
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

test "parse hover markdown response" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","id":1,"result":{"contents":{"kind":"markdown","value":"fn main() void"}}}
    ;
    const text = (try parseHoverResponse(allocator, json)).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("fn main() void", text);
}

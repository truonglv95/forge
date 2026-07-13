const std = @import("std");
const diagnostics = @import("diagnostics.zig");

pub const Location = struct {
    uri: []const u8,
    line: u32,
    character: u32,

    pub fn deinit(self: *Location, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        self.* = undefined;
    }
};

pub fn buildDefinitionRequest(
    allocator: std.mem.Allocator,
    id: i32,
    uri: []const u8,
    line: u32,
    character: u32,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/definition","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}}}
    , .{ id, uri, line, character });
}

pub fn parseDefinitionResponse(allocator: std.mem.Allocator, response_json: []const u8) !?Location {
    const object = extractResultObject(response_json) orelse return null;

    const uri_raw = parseStringField(object, "targetUri") orelse parseStringField(object, "uri") orelse return null;
    const uri = try allocator.dupe(u8, uri_raw);
    errdefer allocator.free(uri);

    const range_key = if (std.mem.indexOf(u8, object, "\"targetRange\"") != null) "targetRange" else "range";
    const line = parseRangeField(object, range_key, "line") orelse 0;
    const character = parseRangeField(object, range_key, "character") orelse 0;

    return .{
        .uri = uri,
        .line = line,
        .character = character,
    };
}

pub fn uriToRelativePath(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    uri: []const u8,
) !?[]const u8 {
    const prefix = try std.fmt.allocPrint(allocator, "file://{s}", .{workspace_path});
    defer allocator.free(prefix);

    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    if (rest.len == 0) return null;
    return try allocator.dupe(u8, rest);
}

fn extractResultObject(json: []const u8) ?[]const u8 {
    const key = std.mem.indexOf(u8, json, "\"result\"") orelse return null;
    const colon = std.mem.indexOfPos(u8, json, key, ":") orelse return null;
    var i = colon + 1;
    while (i < json.len and std.ascii.isWhitespace(json[i])) : (i += 1) {}
    if (i >= json.len) return null;
    if (json[i] == 'n') return null;
    if (json[i] == '[') {
        const obj_start = std.mem.indexOfPos(u8, json, i, "{") orelse return null;
        const obj_end = findMatchingBrace(json, obj_start) orelse return null;
        return json[obj_start .. obj_end + 1];
    }
    if (json[i] == '{') {
        const end = findMatchingBrace(json, i) orelse return null;
        return json[i .. end + 1];
    }
    return null;
}

fn parseRangeField(object: []const u8, range_key: []const u8, field: []const u8) ?u32 {
    var needle: [32]u8 = undefined;
    const range_pattern = std.fmt.bufPrint(&needle, "\"{s}\"", .{range_key}) catch return null;
    const range_pos = std.mem.indexOf(u8, object, range_pattern) orelse return null;
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

test "parse definition response" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","id":1,"result":{"uri":"file:///proj/src/main.zig","range":{"start":{"line":10,"character":4},"end":{"line":10,"character":8}}}}
    ;
    var loc = (try parseDefinitionResponse(allocator, json)).?;
    defer loc.deinit(allocator);
    try std.testing.expectEqualStrings("file:///proj/src/main.zig", loc.uri);
    try std.testing.expectEqual(@as(u32, 10), loc.line);
    try std.testing.expectEqual(@as(u32, 4), loc.character);
}

test "uri to relative path" {
    const allocator = std.testing.allocator;
    const rel = (try uriToRelativePath(allocator, "/proj", "file:///proj/src/main.zig")).?;
    defer allocator.free(rel);
    try std.testing.expectEqualStrings("src/main.zig", rel);
}

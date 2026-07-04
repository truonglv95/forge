const std = @import("std");

pub const TextEdit = struct {
    line: u32,
    character: u32,
    end_line: u32,
    end_character: u32,
    new_text: []const u8,

    pub fn deinit(self: *TextEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.new_text);
        self.* = undefined;
    }
};

pub const FileEdit = struct {
    uri: []const u8,
    edits: []TextEdit,

    pub fn deinit(self: *FileEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        for (self.edits) |*edit| edit.deinit(allocator);
        allocator.free(self.edits);
        self.* = undefined;
    }
};

pub const WorkspaceEdit = struct {
    files: []FileEdit,

    pub fn deinit(self: *WorkspaceEdit, allocator: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub fn buildRenameRequest(
    allocator: std.mem.Allocator,
    id: i32,
    uri: []const u8,
    line: u32,
    character: u32,
    new_name: []const u8,
) ![]const u8 {
    const escaped = try escapeJsonString(allocator, new_name);
    defer allocator.free(escaped);
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/rename","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"newName":"{s}"}}}}
    , .{ id, uri, line, character, escaped });
}

pub fn parseRenameResponse(allocator: std.mem.Allocator, response_json: []const u8) !?WorkspaceEdit {
    const result = extractResultObject(response_json) orelse return null;
    var files: std.ArrayList(FileEdit) = .empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }

    if (std.mem.indexOf(u8, result, "\"documentChanges\"")) |changes_pos| {
        const array_start = std.mem.indexOfPos(u8, result, changes_pos, "[") orelse return null;
        var i = array_start + 1;
        while (i < result.len) {
            const obj_start = std.mem.indexOfPos(u8, result, i, "{") orelse break;
            const obj_end = findMatchingBrace(result, obj_start) orelse break;
            const obj = result[obj_start .. obj_end + 1];
            try parseDocumentChange(allocator, obj, &files);
            i = obj_end + 1;
        }
    } else if (std.mem.indexOf(u8, result, "\"changes\"")) |_| {
        try parseChangesMap(allocator, result, &files);
    }

    if (files.items.len == 0) return null;
    return .{ .files = try files.toOwnedSlice(allocator) };
}

fn parseDocumentChange(allocator: std.mem.Allocator, object: []const u8, files: *std.ArrayList(FileEdit)) !void {
    const uri_raw = parseStringField(object, "uri") orelse return;
    const uri = try allocator.dupe(u8, uri_raw);
    errdefer allocator.free(uri);

    const edits_key = std.mem.indexOf(u8, object, "\"edits\"") orelse {
        allocator.free(uri);
        return;
    };
    const edits = try parseTextEditArray(allocator, object[edits_key..]);
    errdefer {
        for (edits) |*edit| edit.deinit(allocator);
        allocator.free(edits);
        allocator.free(uri);
    }
    try files.append(allocator, .{ .uri = uri, .edits = edits });
}

fn parseChangesMap(allocator: std.mem.Allocator, object: []const u8, files: *std.ArrayList(FileEdit)) !void {
    const changes_pos = std.mem.indexOf(u8, object, "\"changes\"") orelse return;
    var search = changes_pos;
    while (search < object.len) {
        const uri_key = std.mem.indexOfPos(u8, object, search, "\"file://") orelse break;
        const uri_end = std.mem.indexOfPos(u8, object, uri_key + 1, "\"") orelse break;
        const uri_raw = object[uri_key + 1 .. uri_end];
        const uri = try allocator.dupe(u8, uri_raw);
        errdefer allocator.free(uri);
        const array_start = std.mem.indexOfPos(u8, object, uri_end, "[") orelse break;
        const edits = try parseTextEditArray(allocator, object[array_start..]);
        errdefer {
            for (edits) |*edit| edit.deinit(allocator);
            allocator.free(edits);
            allocator.free(uri);
        }
        try files.append(allocator, .{ .uri = uri, .edits = edits });
        search = array_start + 1;
    }
}

fn parseTextEditArray(allocator: std.mem.Allocator, slice: []const u8) ![]TextEdit {
    var list: std.ArrayList(TextEdit) = .empty;
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

fn extractResultObject(json: []const u8) ?[]const u8 {
    const key = std.mem.indexOf(u8, json, "\"result\"") orelse return null;
    const colon = std.mem.indexOfPos(u8, json, key, ":") orelse return null;
    var i = colon + 1;
    while (i < json.len and std.ascii.isWhitespace(json[i])) : (i += 1) {}
    if (i >= json.len or json[i] == 'n') return null;
    if (json[i] != '{') return null;
    const end = findMatchingBrace(json, i) orelse return null;
    return json[i .. end + 1];
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

fn escapeJsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

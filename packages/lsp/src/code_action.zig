const std = @import("std");
const rename = @import("rename.zig");
const diagnostics = @import("diagnostics.zig");

pub const Action = struct {
    title: []const u8,
    edit: ?rename.WorkspaceEdit = null,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.edit) |*edit| edit.deinit(allocator);
        self.* = undefined;
    }
};

pub fn buildCodeActionRequest(
    allocator: std.mem.Allocator,
    id: i32,
    uri: []const u8,
    diag: diagnostics.Diagnostic,
) ![]const u8 {
    const escaped_msg = try escapeJsonString(allocator, diag.message);
    defer allocator.free(escaped_msg);
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/codeAction","params":{{"textDocument":{{"uri":"{s}"}},"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"context":{{"diagnostics":[{{"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"message":"{s}","severity":{d}}}]}}}}}}
    , .{
        id,
        uri,
        diag.line,
        diag.character,
        diag.end_line,
        diag.end_character,
        diag.line,
        diag.character,
        diag.end_line,
        diag.end_character,
        escaped_msg,
        @intFromEnum(diag.severity),
    });
}

pub fn parseCodeActionResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]Action {
    var list: std.ArrayList(Action) = .empty;
    errdefer {
        for (list.items) |*action| action.deinit(allocator);
        list.deinit(allocator);
    }

    const key = std.mem.indexOf(u8, response_json, "\"result\"") orelse return try list.toOwnedSlice(allocator);
    const array_start = std.mem.indexOfPos(u8, response_json, key, "[") orelse return try list.toOwnedSlice(allocator);
    var i = array_start + 1;
    while (i < response_json.len) {
        const obj_start = std.mem.indexOfPos(u8, response_json, i, "{") orelse break;
        const obj_end = findMatchingBrace(response_json, obj_start) orelse break;
        const obj = response_json[obj_start .. obj_end + 1];

        const title_raw = parseStringField(obj, "title") orelse {
            i = obj_end + 1;
            continue;
        };
        const title = try allocator.dupe(u8, title_raw);

        var edit: ?rename.WorkspaceEdit = null;
        if (std.mem.indexOf(u8, obj, "\"edit\"")) |edit_pos| {
            const edit_obj_start = std.mem.indexOfPos(u8, obj, edit_pos, "{") orelse null;
            if (edit_obj_start) |start| {
                const edit_obj_end = findMatchingBrace(obj, start) orelse null;
                if (edit_obj_end) |end| {
                    edit = try parseWorkspaceEditObject(allocator, obj[start .. end + 1]);
                }
            }
        }

        try list.append(allocator, .{ .title = title, .edit = edit });
        i = obj_end + 1;
    }

    return try list.toOwnedSlice(allocator);
}

fn parseWorkspaceEditObject(allocator: std.mem.Allocator, object: []const u8) !rename.WorkspaceEdit {
    var files: std.ArrayList(rename.FileEdit) = .empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }

    if (std.mem.indexOf(u8, object, "\"changes\"")) |_| {
        try parseChangesMap(allocator, object, &files);
    }

    return .{ .files = try files.toOwnedSlice(allocator) };
}

fn parseChangesMap(allocator: std.mem.Allocator, object: []const u8, files: *std.ArrayList(rename.FileEdit)) !void {
    var search: usize = 0;
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
    var idx = colon + 1;
    while (idx < object.len and std.ascii.isWhitespace(object[idx])) : (idx += 1) {}
    var end = idx;
    while (end < object.len and object[end] >= '0' and object[end] <= '9') : (end += 1) {}
    if (end == idx) return null;
    return std.fmt.parseInt(u32, object[idx..end], 10) catch null;
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

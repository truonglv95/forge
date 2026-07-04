const std = @import("std");

pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    info = 3,
    hint = 4,
    unknown = 0,
};

pub const Diagnostic = struct {
    line: u32,
    character: u32,
    end_line: u32,
    end_character: u32,
    message: []const u8,
    severity: Severity,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const List = struct {
    items: []Diagnostic,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn parseDiagnosticResponse(allocator: std.mem.Allocator, response_json: []const u8) !List {
    var list: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    var search_from: usize = 0;
    while (search_from < response_json.len) {
        const diag_key = std.mem.indexOfPos(u8, response_json, search_from, "\"diagnostics\"") orelse break;
        const array_start = std.mem.indexOfPos(u8, response_json, diag_key, "[") orelse {
            search_from = diag_key + 1;
            continue;
        };

        var i = array_start + 1;
        while (i < response_json.len) {
            const obj_start = std.mem.indexOfPos(u8, response_json, i, "{") orelse break;
            const obj_end = findMatchingBrace(response_json, obj_start) orelse break;
            const obj = response_json[obj_start .. obj_end + 1];

            const range_start = std.mem.indexOf(u8, obj, "\"range\"") orelse {
                i = obj_end + 1;
                continue;
            };
            const range_obj_start = std.mem.indexOfPos(u8, obj, range_start, "{") orelse {
                i = obj_end + 1;
                continue;
            };
            const range_obj_end = findMatchingBrace(obj, range_obj_start) orelse {
                i = obj_end + 1;
                continue;
            };
            const range_obj = obj[range_obj_start .. range_obj_end + 1];

            const start_line = parseU32Field(range_obj, "line") orelse 0;
            const start_char = parseU32Field(range_obj, "character") orelse 0;
            var end_line = start_line;
            var end_char = start_char + 1;
            if (std.mem.indexOf(u8, range_obj, "\"end\"")) |end_pos| {
                const end_obj_start = std.mem.indexOfPos(u8, range_obj, end_pos, "{") orelse null;
                if (end_obj_start) |eos| {
                    const end_obj_end = findMatchingBrace(range_obj, eos) orelse null;
                    if (end_obj_end) |eoe| {
                        const end_obj = range_obj[eos .. eoe + 1];
                        end_line = parseU32Field(end_obj, "line") orelse end_line;
                        end_char = parseU32Field(end_obj, "character") orelse end_char;
                    }
                }
            }

            const message_raw = parseStringField(obj, "message") orelse "diagnostic";
            const message = try allocator.dupe(u8, message_raw);
            errdefer allocator.free(message);
            const severity_raw = parseU32Field(obj, "severity") orelse 1;
            const severity: Severity = switch (severity_raw) {
                1 => .err,
                2 => .warning,
                3 => .info,
                4 => .hint,
                else => .unknown,
            };

            try list.append(allocator, .{
                .line = start_line,
                .character = start_char,
                .end_line = end_line,
                .end_character = end_char,
                .message = message,
                .severity = severity,
            });

            i = obj_end + 1;
            if (response_json[i..].len > 0 and response_json[i] == ']') break;
        }
        search_from = array_start + 1;
    }

    return .{ .items = try list.toOwnedSlice(allocator) };
}

pub fn buildDidOpenNotification(allocator: std.mem.Allocator, uri: []const u8, language_id: []const u8, text: []const u8) ![]const u8 {
    const escaped = try escapeJsonString(allocator, text);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"{s}","version":1,"text":"{s}"}}}}}}
    , .{ uri, language_id, escaped });
}

pub fn buildDiagnosticRequest(allocator: std.mem.Allocator, id: i32, uri: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/diagnostic","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{ id, uri });
}

pub fn fileUri(allocator: std.mem.Allocator, workspace_path: []const u8, rel_path: []const u8) ![]const u8 {
    if (rel_path.len == 0) return std.fmt.allocPrint(allocator, "file://{s}", .{workspace_path});
    return std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ workspace_path, rel_path });
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
        if (object[i] == '"') {
            return object[start..i];
        }
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
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "parse diagnostic response" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","id":2,"result":{"kind":"full","items":[{"uri":"file:///x","version":1,"diagnostics":[{"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}},"severity":1,"message":"expected semicolon"}]}]}}
    ;
    var list = try parseDiagnosticResponse(allocator, json);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u32, 1), list.items[0].line);
    try std.testing.expectEqualStrings("expected semicolon", list.items[0].message);
}

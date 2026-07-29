const std = @import("std");

pub const ApplyError = error{
    MatchNotFound,
    MultipleMatches,
    OutOfMemory,
};

pub const BlockEdit = struct {
    search: []const u8,
    replace: []const u8,
};

/// Applies a block edit to the content using indentation-aware matching.
pub fn applyEdit(allocator: std.mem.Allocator, content: []const u8, edit: BlockEdit) ![]u8 {
    if (edit.search.len == 0) {
        return error.MatchNotFound;
    }

    // 1. Try exact match
    const first_idx = std.mem.indexOf(u8, content, edit.search);
    if (first_idx) |idx| {
        if (std.mem.indexOfPos(u8, content, idx + edit.search.len, edit.search)) |_| {
            return error.MultipleMatches;
        }

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.appendSlice(allocator, content[0..idx]);
        try result.appendSlice(allocator, edit.replace);
        try result.appendSlice(allocator, content[idx + edit.search.len ..]);
        return result.toOwnedSlice(allocator);
    }

    // 2. Try indentation-agnostic match
    var search_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer search_lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, edit.search, '\n');
    while (it.next()) |line| {
        try search_lines.append(allocator, std.mem.trim(u8, line, " \t\r"));
    }

    var search_start: usize = 0;
    while (search_start < search_lines.items.len and search_lines.items[search_start].len == 0) {
        search_start += 1;
    }
    var search_end: usize = search_lines.items.len;
    while (search_end > search_start and search_lines.items[search_end - 1].len == 0) {
        search_end -= 1;
    }
    const clean_search = search_lines.items[search_start..search_end];

    if (clean_search.len == 0) return error.MatchNotFound;

    var content_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer content_lines.deinit(allocator);
    var content_offsets: std.ArrayListUnmanaged(usize) = .empty;
    defer content_offsets.deinit(allocator);

    var content_it = std.mem.splitScalar(u8, content, '\n');
    var current_offset: usize = 0;
    while (content_it.next()) |line| {
        try content_lines.append(allocator, line);
        try content_offsets.append(allocator, current_offset);
        current_offset += line.len + 1; // +1 for \n
    }

    var best_match_start: ?usize = null;
    var best_match_end: ?usize = null;
    var match_count: usize = 0;

    var i: usize = 0;
    while (i + clean_search.len <= content_lines.items.len) : (i += 1) {
        var is_match = true;
        for (clean_search, 0..) |s_line, j| {
            const c_line = std.mem.trim(u8, content_lines.items[i + j], " \t\r");
            if (!std.mem.eql(u8, c_line, s_line)) {
                is_match = false;
                break;
            }
        }

        if (is_match) {
            match_count += 1;
            best_match_start = i;
            best_match_end = i + clean_search.len;
        }
    }

    if (match_count == 0) return error.MatchNotFound;
    if (match_count > 1) return error.MultipleMatches;

    const match_start_line = content_lines.items[best_match_start.?];
    const original_indent = getLeadingWhitespace(match_start_line);
    const search_indent = getLeadingWhitespace(edit.search);

    const byte_start = content_offsets.items[best_match_start.?];
    const byte_end = if (best_match_end.? < content_offsets.items.len)
        content_offsets.items[best_match_end.?]
    else
        content.len;

    var fixed_replace: std.ArrayListUnmanaged(u8) = .empty;
    defer fixed_replace.deinit(allocator);

    var rep_it = std.mem.splitScalar(u8, edit.replace, '\n');
    var first_line = true;
    while (rep_it.next()) |line| {
        if (!first_line) try fixed_replace.appendSlice(allocator, "\n");
        first_line = false;

        const line_trim = std.mem.trimStart(u8, line, " \t");
        if (line_trim.len == 0) continue;

        if (std.mem.startsWith(u8, line, search_indent)) {
            try fixed_replace.appendSlice(allocator, original_indent);
            try fixed_replace.appendSlice(allocator, line[search_indent.len..]);
        } else {
            try fixed_replace.appendSlice(allocator, line);
        }
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, content[0..byte_start]);
    try result.appendSlice(allocator, fixed_replace.items);

    if (byte_end < content.len and !std.mem.endsWith(u8, fixed_replace.items, "\n")) {
        try result.appendSlice(allocator, "\n");
    }

    try result.appendSlice(allocator, content[byte_end..]);
    return result.toOwnedSlice(allocator);
}

fn getLeadingWhitespace(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        if (text[end] != ' ' and text[end] != '\t') break;
    }
    return text[0..end];
}

test "fast_apply exact match" {
    const allocator = std.testing.allocator;
    const content = "fn hello() void {\n    print(\"hi\");\n}\n";
    const edit = BlockEdit{
        .search = "    print(\"hi\");\n",
        .replace = "    print(\"hello world\");\n",
    };

    const result = try applyEdit(allocator, content, edit);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("fn hello() void {\n    print(\"hello world\");\n}\n", result);
}

test "fast_apply indentation match" {
    const allocator = std.testing.allocator;
    const content = "fn hello() void {\n    print(\"hi\");\n}\n";
    const edit = BlockEdit{
        .search = "print(\"hi\");",
        .replace = "print(\"hello\");",
    };

    const result = try applyEdit(allocator, content, edit);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("fn hello() void {\n    print(\"hello\");\n}\n", result);
}

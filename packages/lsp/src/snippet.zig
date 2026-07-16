const std = @import("std");

/// Snippet completion support (insertTextFormat = 2).
///
/// LSP completions can include snippets with placeholder syntax:
///   `fn ${1:name}(${2:args}) ${3:ret} {`  \n  `    $0`  \n  `}`
///
/// When the user accepts a snippet completion, the editor:
/// 1. Inserts the snippet text
/// 2. Places the cursor at $0 (final position)
/// 3. Allows Tab to cycle through ${1:...}, ${2:...}, ${3:...} placeholders
///
/// This module parses snippet syntax and produces the plain text to insert
/// plus a list of tab-stop positions for the editor.
pub const TabStop = struct {
    /// 0-indexed position in the inserted text where this tab-stop starts.
    start: usize,
    /// Length of the placeholder text (what gets selected when Tab lands here).
    length: usize,
    /// Tab-stop index (1, 2, 3...). 0 is the final cursor position.
    index: u32,
    /// Placeholder text (what's selected when the tab-stop is active).
    placeholder: []const u8,
};

pub const ParsedSnippet = struct {
    /// The plain text to insert (placeholders expanded to their default values).
    text: []const u8,
    /// Tab-stop positions in the inserted text.
    tab_stops: []TabStop,
    /// The final cursor position (where $0 is, or end of text if no $0).
    final_cursor: usize,

    pub fn deinit(self: *ParsedSnippet, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.tab_stops) |ts| allocator.free(ts.placeholder);
        allocator.free(self.tab_stops);
        self.* = undefined;
    }
};

/// Parse a snippet string and produce the plain text + tab-stop list.
/// Supports:
///   $0 — final cursor position
///   $1, $2, ... — numbered tab-stops (empty placeholder)
///   ${1:default} — numbered tab-stop with default text
///   ${name:default} — named placeholder (treated as tab-stop with index 0)
///   \\$ — literal dollar sign
pub fn parseSnippet(allocator: std.mem.Allocator, snippet: []const u8) !ParsedSnippet {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var tab_stops: std.ArrayList(TabStop) = .empty;
    errdefer {
        for (tab_stops.items) |ts| allocator.free(ts.placeholder);
        tab_stops.deinit(allocator);
    }
    var final_cursor: usize = 0;
    var has_final_cursor = false;

    var i: usize = 0;
    while (i < snippet.len) {
        if (snippet[i] == '\\' and i + 1 < snippet.len and snippet[i + 1] == '$') {
            try text.append(allocator, '$');
            i += 2;
            continue;
        }

        if (snippet[i] == '$') {
            if (i + 1 >= snippet.len) {
                try text.append(allocator, '$');
                i += 1;
                continue;
            }

            if (snippet[i + 1] == '{') {
                // ${n:placeholder} or ${name:default}
                const close = std.mem.indexOfPos(u8, snippet, i + 2, "}") orelse {
                    try text.append(allocator, '$');
                    i += 1;
                    continue;
                };
                const inner = snippet[i + 2 .. close];
                const colon = std.mem.indexOfScalar(u8, inner, ':');
                const index_str = if (colon) |c| inner[0..c] else inner;
                const placeholder = if (colon) |c| inner[c + 1 ..] else "";
                const index = std.fmt.parseInt(u32, index_str, 10) catch 0;

                const start = text.items.len;
                try text.appendSlice(allocator, placeholder);
                if (index == 0) {
                    final_cursor = start;
                    has_final_cursor = true;
                } else {
                    try tab_stops.append(allocator, .{
                        .start = start,
                        .length = placeholder.len,
                        .index = index,
                        .placeholder = try allocator.dupe(u8, placeholder),
                    });
                }
                i = close + 1;
                continue;
            }

            // $0, $1, $2, etc.
            if (std.ascii.isDigit(snippet[i + 1])) {
                var j = i + 1;
                while (j < snippet.len and std.ascii.isDigit(snippet[j])) j += 1;
                const index = std.fmt.parseInt(u32, snippet[i + 1 .. j], 10) catch 0;
                if (index == 0) {
                    final_cursor = text.items.len;
                    has_final_cursor = true;
                } else {
                    try tab_stops.append(allocator, .{
                        .start = text.items.len,
                        .length = 0,
                        .index = index,
                        .placeholder = try allocator.dupe(u8, ""),
                    });
                }
                i = j;
                continue;
            }

            try text.append(allocator, '$');
            i += 1;
            continue;
        }

        try text.append(allocator, snippet[i]);
        i += 1;
    }

    if (!has_final_cursor) {
        final_cursor = text.items.len;
    }

    // Sort tab-stops by index for Tab cycling.
    std.sort.block(TabStop, tab_stops.items, {}, struct {
        fn less(_: void, a: TabStop, b: TabStop) bool {
            return a.index < b.index;
        }
    }.less);

    return .{
        .text = try text.toOwnedSlice(allocator),
        .tab_stops = try tab_stops.toOwnedSlice(allocator),
        .final_cursor = final_cursor,
    };
}

test "parseSnippet handles plain text" {
    const allocator = std.testing.allocator;
    var result = try parseSnippet(allocator, "hello world");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("hello world", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.tab_stops.len);
    try std.testing.expectEqual(@as(usize, 11), result.final_cursor);
}

test "parseSnippet handles final cursor $0" {
    const allocator = std.testing.allocator;
    var result = try parseSnippet(allocator, "fn main() $0");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("fn main() ", result.text);
    try std.testing.expectEqual(@as(usize, 10), result.final_cursor);
}

test "parseSnippet handles numbered tabstops with placeholders" {
    const allocator = std.testing.allocator;
    var result = try parseSnippet(allocator, "fn ${1:name}() ${2:ret} { $0 }");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("fn name() ret {  }", result.text);
    try std.testing.expectEqual(@as(usize, 2), result.tab_stops.len);
    try std.testing.expectEqual(@as(u32, 1), result.tab_stops[0].index);
    try std.testing.expectEqualStrings("name", result.tab_stops[0].placeholder);
    try std.testing.expectEqual(@as(u32, 2), result.tab_stops[1].index);
    try std.testing.expectEqualStrings("ret", result.tab_stops[1].placeholder);
}

test "parseSnippet handles escaped dollar sign" {
    const allocator = std.testing.allocator;
    var result = try parseSnippet(allocator, "cost: \\$5");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("cost: $5", result.text);
}

test "parseSnippet handles empty tabstops $1$2" {
    const allocator = std.testing.allocator;
    var result = try parseSnippet(allocator, "x = $1 + $2");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("x =  + ", result.text);
    try std.testing.expectEqual(@as(usize, 2), result.tab_stops.len);
    try std.testing.expectEqual(@as(usize, 0), result.tab_stops[0].length);
    try std.testing.expectEqual(@as(usize, 0), result.tab_stops[1].length);
}

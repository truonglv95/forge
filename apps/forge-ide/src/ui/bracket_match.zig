const std = @import("std");
const editor = @import("forge-editor");

pub const Position = struct {
    row: usize,
    col: usize,
};

fn partner(ch: u8) ?u8 {
    return switch (ch) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        else => null,
    };
}

fn isOpen(ch: u8) bool {
    return ch == '(' or ch == '[' or ch == '{';
}

fn isClose(ch: u8) bool {
    return ch == ')' or ch == ']' or ch == '}';
}

fn charAt(buf: *const editor.Buffer, row: usize, col: usize) ?u8 {
    const line = buf.lineAt(row);
    if (col >= line.len) return null;
    return line[col];
}

pub const Match = struct {
    from: Position,
    to: Position,
};

/// Returns matching bracket pair for cursor-adjacent bracket, or null.
pub fn findMatch(buf: *const editor.Buffer, row: usize, col: usize) ?Match {
    const line = buf.lineAt(row);
    var check_col: ?usize = null;
    if (col > 0 and col <= line.len) {
        const left = line[col - 1];
        if (partner(left) != null) check_col = col - 1;
    }
    if (check_col == null and col < line.len) {
        const at = line[col];
        if (partner(at) != null) check_col = col;
    }
    const bracket_col = check_col orelse return null;
    const ch = line[bracket_col];
    const pair = partner(ch) orelse return null;
    const from = Position{ .row = row, .col = bracket_col };

    if (isOpen(ch)) {
        if (scanForward(buf, row, bracket_col + 1, ch, pair)) |to| return .{ .from = from, .to = to };
    } else if (isClose(ch)) {
        if (scanBackward(buf, row, bracket_col, ch, pair)) |to| return .{ .from = from, .to = to };
    }
    return null;
}

/// Returns matching bracket position for cursor-adjacent bracket, or null.
pub fn findMatchEnd(buf: *const editor.Buffer, row: usize, col: usize) ?Position {
    return if (findMatch(buf, row, col)) |m| m.to else null;
}

fn scanForward(buf: *const editor.Buffer, start_row: usize, start_col: usize, open: u8, close: u8) ?Position {
    var depth: i32 = 1;
    var r = start_row;
    var c = start_col;
    while (r < buf.lineCount()) {
        const line = buf.lineAt(r);
        while (c < line.len) {
            if (skipContext(line, &c)) continue;
            const ch = line[c];
            if (ch == open) depth += 1;
            if (ch == close) {
                depth -= 1;
                if (depth == 0) return .{ .row = r, .col = c };
            }
            c += 1;
        }
        r += 1;
        c = 0;
    }
    return null;
}

fn scanBackward(buf: *const editor.Buffer, start_row: usize, start_col: usize, close: u8, open: u8) ?Position {
    var depth: i32 = 1;
    var r: i32 = @intCast(start_row);
    var c: i32 = @intCast(start_col);
    while (r >= 0) {
        const line = buf.lineAt(@intCast(r));
        while (c >= 0) {
            if (skipContextReverse(line, &c)) continue;
            const ch = line[@intCast(c)];
            if (ch == close) depth += 1;
            if (ch == open) {
                depth -= 1;
                if (depth == 0) return .{ .row = @intCast(r), .col = @intCast(c) };
            }
            c -= 1;
        }
        r -= 1;
        if (r >= 0) c = @intCast(buf.lineAt(@intCast(r)).len - 1);
    }
    return null;
}

fn skipContext(line: []const u8, c: *usize) bool {
    if (c.* >= line.len) return false;
    if (line[c.*] == '"') {
        c.* += 1;
        while (c.* < line.len and line[c.*] != '"') : (c.* += 1) {}
        if (c.* < line.len) c.* += 1;
        return true;
    }
    if (c.* + 1 < line.len and line[c.*] == '/' and line[c.* + 1] == '/') {
        c.* = line.len;
        return true;
    }
    return false;
}

fn skipContextReverse(line: []const u8, c: *i32) bool {
    if (c.* < 0) return false;
    const idx: usize = @intCast(c.*);
    if (line[idx] == '"') {
        var i: i32 = @as(i32, @intCast(idx)) - 1;
        while (i >= 0 and line[@intCast(i)] != '"') i -= 1;
        if (i >= 0) c.* = i - 1;
        return true;
    }
    return false;
}

test "matching parens on same line" {
    var buf = editor.Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try buf.setText("fn main() void {}\n");
    buf.cursor = .{ .row = 0, .col = 9 };
    const m = findMatch(&buf, 0, 9);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 0), m.?.from.row);
    try std.testing.expectEqual(@as(usize, 9), m.?.from.col);
    try std.testing.expectEqual(@as(usize, 0), m.?.to.row);
    try std.testing.expectEqual(@as(usize, 16), m.?.to.col);
}

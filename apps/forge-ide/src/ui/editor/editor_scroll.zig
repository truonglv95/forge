const std = @import("std");
const editor = @import("forge-editor");
const workspace = @import("forge-workspace");
const renderer = @import("forge-renderer");

pub const editor_chrome_height: f32 = 35;
pub const content_top: f32 = 65;
pub const text_inset_y: f32 = 5;

pub fn firstLineY(_: *const workspace.Theme) f32 {
    return content_top + text_inset_y;
}

pub fn lineHeight(theme: *const workspace.Theme) f32 {
    return theme.lineHeight();
}

pub fn charWidth(theme: *const workspace.Theme) f32 {
    return theme.charWidth();
}

pub fn gutterWidth(theme: *const workspace.Theme) f32 {
    return theme.gutterWidth();
}

pub fn viewportHeight(editor_h: f32) f32 {
    return editor_h - editor_chrome_height;
}

pub fn contentHeight(line_count: usize, theme: *const workspace.Theme) f32 {
    return @as(f32, @floatFromInt(line_count)) * lineHeight(theme);
}

pub fn maxScrollY(line_count: usize, editor_h: f32, theme: *const workspace.Theme) f32 {
    const viewport = viewportHeight(editor_h);
    const content = contentHeight(line_count, theme);
    return @max(0, content - viewport);
}

pub fn longestLineLen(buf: *const editor.Buffer) usize {
    var max_len: usize = 0;
    for (0..buf.lineCount()) |idx| {
        max_len = @max(max_len, buf.lineAt(idx).len);
    }
    return max_len;
}

pub fn viewportWidth(editor_w: f32, theme: *const workspace.Theme) f32 {
    return @max(0, editor_w - gutterWidth(theme) - 16);
}

pub fn textWidth(text: []const u8, font_size: f32) f32 {
    return renderer.Renderer.measureText(text, font_size);
}

pub fn cursorX(line: []const u8, col: usize, font_size: f32) f32 {
    const end = @min(col, line.len);
    return textWidth(line[0..end], font_size);
}

pub fn columnAtX(line: []const u8, x: f32, font_size: f32) usize {
    if (line.len == 0 or x <= 0) return 0;
    var lo: usize = 0;
    var hi: usize = line.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (textWidth(line[0..mid], font_size) < x) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo == 0) return 0;
    const left = textWidth(line[0 .. lo - 1], font_size);
    const right = textWidth(line[0..lo], font_size);
    if (x - left < right - x) return lo - 1;
    return lo;
}

pub fn maxLineWidth(buf: *const editor.Buffer, font_size: f32) f32 {
    var max_w: f32 = 0;
    for (0..buf.lineCount()) |idx| {
        max_w = @max(max_w, textWidth(buf.lineAt(idx), font_size));
    }
    return max_w;
}

pub fn maxScrollX(content_w: f32, editor_w: f32, theme: *const workspace.Theme) f32 {
    const viewport = viewportWidth(editor_w, theme);
    return @max(0, content_w - viewport);
}

pub fn clampScrollY(scroll_y: f32, line_count: usize, editor_h: f32, theme: *const workspace.Theme) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(line_count, editor_h, theme));
}

pub fn clampScrollX(scroll_x: f32, content_w: f32, editor_w: f32, theme: *const workspace.Theme) f32 {
    return std.math.clamp(scroll_x, 0, maxScrollX(content_w, editor_w, theme));
}

pub fn scrollToCursor(
    scroll_y: f32,
    scroll_x: f32,
    buf: *const editor.Buffer,
    editor_w: f32,
    editor_h: f32,
    theme: *const workspace.Theme,
) struct { y: f32, x: f32 } {
    const line_h = lineHeight(theme);
    const char_w = charWidth(theme);
    const viewport_h = viewportHeight(editor_h);
    const viewport_w = viewportWidth(editor_w, theme);
    const cursor_y = @as(f32, @floatFromInt(buf.cursor.row)) * line_h;
    const line = buf.lineAt(buf.cursor.row);
    const cursor_x = cursorX(line, buf.cursor.col, theme.editor_font_size);

    var y = scroll_y;
    var x = scroll_x;
    if (cursor_y < y) y = cursor_y;
    if (cursor_y + line_h > y + viewport_h) y = cursor_y + line_h - viewport_h;

    if (cursor_x < x) x = cursor_x;
    if (cursor_x + char_w > x + viewport_w) x = cursor_x + char_w - viewport_w;

    const max_line_len = longestLineLen(buf);
    const content_w = @as(f32, @floatFromInt(max_line_len)) * char_w;
    y = clampScrollY(y, buf.lineCount(), editor_h, theme);
    x = clampScrollX(x, content_w, editor_w, theme);
    return .{ .y = y, .x = x };
}

test "vertical scroll stops at last line" {
    const theme = workspace.Theme.darkDefault();
    try std.testing.expectEqual(@as(f32, 0), maxScrollY(10, 200, &theme));
}

test "horizontal scroll stops at longest line" {
    const theme = workspace.Theme.darkDefault();
    try std.testing.expectEqual(@as(f32, 0), maxScrollX(20, 800, &theme));
    const max = maxScrollX(800, 400, &theme);
    try std.testing.expect(max > 0);
}

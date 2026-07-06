const std = @import("std");
const editor = @import("forge-editor");
const editor_scroll = @import("editor_scroll.zig");

pub const Segment = struct {
    buf_line: usize,
    start_col: usize,
    end_col: usize,
};

pub fn maxWidth(viewport_w: f32) f32 {
    return @max(40.0, viewport_w - 8.0);
}

pub fn segmentCount(line: []const u8, max_w: f32, font_size: f32) usize {
    if (line.len == 0) return 1;
    var count: usize = 0;
    var start: usize = 0;
    while (start < line.len) {
        const end = breakAt(line, start, max_w, font_size);
        count += 1;
        if (end >= line.len) break;
        start = end;
        while (start < line.len and line[start] == ' ') start += 1;
    }
    return @max(1, count);
}

pub fn totalVisualLines(buf: *const editor.Buffer, viewport_w: f32, font_size: f32) usize {
    const max_w = maxWidth(viewport_w);
    var total: usize = 0;
    for (0..buf.lineCount()) |idx| {
        total += segmentCount(buf.lineAt(idx), max_w, font_size);
    }
    return @max(1, total);
}

pub fn segmentAt(buf: *const editor.Buffer, visual_index: usize, viewport_w: f32, font_size: f32) Segment {
    const max_w = maxWidth(viewport_w);
    var current: usize = 0;
    for (0..buf.lineCount()) |line_idx| {
        const line = buf.lineAt(line_idx);
        var start: usize = 0;
        while (start <= line.len) {
            const end = if (start < line.len) breakAt(line, start, max_w, font_size) else start;
            if (current == visual_index) {
                return .{ .buf_line = line_idx, .start_col = start, .end_col = end };
            }
            current += 1;
            if (end >= line.len) break;
            start = end;
            while (start < line.len and line[start] == ' ') start += 1;
        }
    }
    return .{ .buf_line = 0, .start_col = 0, .end_col = 0 };
}

pub fn visualIndexForCursor(buf: *const editor.Buffer, row: usize, col: usize, viewport_w: f32, font_size: f32) usize {
    const max_w = maxWidth(viewport_w);
    var visual: usize = 0;
    for (0..buf.lineCount()) |line_idx| {
        const line = buf.lineAt(line_idx);
        var start: usize = 0;
        while (start <= line.len) {
            const end = if (start < line.len) breakAt(line, start, max_w, font_size) else start;
            if (line_idx == row and col >= start and (col <= end or end >= line.len)) {
                return visual;
            }
            visual += 1;
            if (end >= line.len) break;
            start = end;
            while (start < line.len and line[start] == ' ') start += 1;
        }
    }
    return visual;
}

pub fn contentHeight(buf: *const editor.Buffer, viewport_w: f32, font_size: f32, theme: *const @import("forge-workspace").Theme) f32 {
    const lines = totalVisualLines(buf, viewport_w, font_size);
    return @as(f32, @floatFromInt(lines)) * editor_scroll.lineHeight(theme);
}

pub fn maxScrollY(buf: *const editor.Buffer, editor_h: f32, viewport_w: f32, font_size: f32, theme: *const @import("forge-workspace").Theme) f32 {
    const viewport = editor_scroll.viewportHeight(editor_h);
    const content = contentHeight(buf, viewport_w, font_size, theme);
    return @max(0, content - viewport);
}

pub fn breakAt(line: []const u8, start: usize, max_w: f32, font_size: f32) usize {
    if (start >= line.len) return start;
    const rest = line[start..];
    if (editor_scroll.textWidth(rest, font_size) <= max_w) return line.len;

    var lo: usize = start + 1;
    var hi: usize = line.len;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (editor_scroll.textWidth(line[start..mid], font_size) <= max_w) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    var end = lo;
    if (end < line.len and end > start) {
        if (std.mem.lastIndexOfScalar(u8, line[start..end], ' ')) |rel| {
            const sp = start + rel + 1;
            if (sp > start) end = sp;
        }
    }
    return if (end > start) end else start + 1;
}

pub fn columnAtVisualRow(
    buf: *const editor.Buffer,
    visual_index: usize,
    click_x: f32,
    viewport_w: f32,
    font_size: f32,
) ?struct { row: usize, col: usize } {
    const seg = segmentAt(buf, visual_index, viewport_w, font_size);
    const line = buf.lineAt(seg.buf_line);
    const slice = if (seg.end_col > seg.start_col) line[seg.start_col..seg.end_col] else line[0..0];
    const col_in_slice = editor_scroll.columnAtX(slice, click_x, font_size);
    return .{
        .row = seg.buf_line,
        .col = @min(seg.start_col + col_in_slice, line.len),
    };
}

pub fn scrollToCursor(
    scroll_y: f32,
    buf: *const editor.Buffer,
    editor_h: f32,
    viewport_w: f32,
    font_size: f32,
    theme: *const @import("forge-workspace").Theme,
) f32 {
    const line_h = editor_scroll.lineHeight(theme);
    const viewport_h = editor_scroll.viewportHeight(editor_h);
    const visual = visualIndexForCursor(buf, buf.cursor.row, buf.cursor.col, viewport_w, font_size);
    const cursor_y = @as(f32, @floatFromInt(visual)) * line_h;
    var y = scroll_y;
    if (cursor_y < y) y = cursor_y;
    if (cursor_y + line_h > y + viewport_h) y = cursor_y + line_h - viewport_h;
    return std.math.clamp(y, 0, maxScrollY(buf, editor_h, viewport_w, font_size, theme));
}

test "wrap long line into segments" {
    const line = "hello world this is a long line";
    try std.testing.expect(segmentCount(line, 80.0, 14.0) >= 1);
}

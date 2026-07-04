const std = @import("std");
const renderer = @import("forge-renderer");
const panel_scroll = @import("panel_scroll.zig");
const editor_scroll = @import("editor_scroll.zig");
const terminal_prompt = @import("terminal_prompt.zig");
const git_status = @import("../git/status.zig");

pub const font_size: f32 = 12.0;
pub const text_inset_x: f32 = 12.0;

pub const Pos = struct {
    line: usize,
    col: usize,
};

pub const Selection = struct {
    anchor: Pos,
    cursor: Pos,

    pub fn isEmpty(self: Selection) bool {
        return self.anchor.line == self.cursor.line and self.anchor.col == self.cursor.col;
    }

    pub fn normalized(self: Selection) struct { start: Pos, end: Pos } {
        const a = self.anchor;
        const b = self.cursor;
        if (a.line < b.line or (a.line == b.line and a.col <= b.col)) {
            return .{ .start = a, .end = b };
        }
        return .{ .start = b, .end = a };
    }
};

pub fn contentTop(panel_y: f32) f32 {
    return panel_y + panel_scroll.bottom_content_top;
}

pub fn hitTest(
    editor_x: f32,
    panel_y: f32,
    panel_h: f32,
    x: f32,
    y: f32,
    scroll_y: f32,
    lines: []const []const u8,
) ?Pos {
    const top = contentTop(panel_y);
    const viewport = panel_scroll.bottomViewportHeight(panel_h);
    if (x < editor_x or y < top or y >= top + viewport) return null;

    const float_line = (y - top + scroll_y) / panel_scroll.bottom_line_h;
    if (float_line < 0) return null;

    var line: usize = @intFromFloat(float_line);
    if (lines.len == 0) return .{ .line = 0, .col = 0 };
    if (line >= lines.len) line = lines.len - 1;

    const rel_x = x - editor_x - text_inset_x;
    const col = editor_scroll.columnAtX(lines[line], @max(0, rel_x), font_size);
    return .{ .line = line, .col = col };
}

pub fn extractText(allocator: std.mem.Allocator, lines: []const []const u8, sel: Selection) ![]const u8 {
    if (sel.isEmpty()) return error.EmptySelection;

    const range = sel.normalized();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_idx = range.start.line;
    while (line_idx <= range.end.line and line_idx < lines.len) : (line_idx += 1) {
        if (line_idx > range.start.line) try out.append(allocator, '\n');
        const line = lines[line_idx];
        const start_col = if (line_idx == range.start.line) @min(range.start.col, line.len) else 0;
        const end_col = if (line_idx == range.end.line)
            @min(range.end.col + 1, line.len)
        else
            line.len;
        if (end_col > start_col) try out.appendSlice(allocator, line[start_col..end_col]);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn drawSelection(
    editor_x: f32,
    panel_y: f32,
    scroll_y: f32,
    lines: []const []const u8,
    sel: Selection,
) void {
    if (sel.isEmpty()) return;

    const range = sel.normalized();
    const top = contentTop(panel_y);
    const highlight = renderer.Color{ .r = 0.25, .g = 0.45, .b = 0.75, .a = 0.45 };

    var line_idx = range.start.line;
    while (line_idx <= range.end.line and line_idx < lines.len) : (line_idx += 1) {
        const line = lines[line_idx];
        const start_col = if (line_idx == range.start.line) @min(range.start.col, line.len) else 0;
        const end_col = if (line_idx == range.end.line)
            @min(range.end.col + 1, line.len)
        else
            line.len;
        if (end_col <= start_col) continue;

        const x0 = editor_x + text_inset_x + editor_scroll.cursorX(line, start_col, font_size);
        const x1 = editor_x + text_inset_x + editor_scroll.cursorX(line, end_col, font_size);
        const y = top - scroll_y + @as(f32, @floatFromInt(line_idx)) * panel_scroll.bottom_line_h;
        renderer.Renderer.drawRect(x0, y, @max(1, x1 - x0), panel_scroll.bottom_line_h, highlight);
    }
}

fn segmentColor(kind: terminal_prompt.SegmentKind) renderer.Color {
    return switch (kind) {
        .folder => .{ .r = 0.35, .g = 0.88, .b = 0.95, .a = 1.0 },
        .muted => .{ .r = 0.50, .g = 0.50, .b = 0.52, .a = 1.0 },
        .branch => .{ .r = 0.95, .g = 0.82, .b = 0.35, .a = 1.0 },
        .marker_deleted => .{ .r = 0.95, .g = 0.42, .b = 0.42, .a = 1.0 },
        .marker_modified => .{ .r = 1.0, .g = 0.62, .b = 0.30, .a = 1.0 },
        .marker_staged => .{ .r = 0.42, .g = 0.88, .b = 0.52, .a = 1.0 },
        .marker_untracked => .{ .r = 0.55, .g = 0.72, .b = 1.0, .a = 1.0 },
        .marker_conflict => .{ .r = 0.95, .g = 0.45, .b = 0.95, .a = 1.0 },
        .marker_ahead, .marker_behind => .{ .r = 0.40, .g = 0.85, .b = 0.95, .a = 1.0 },
        .chevron => .{ .r = 0.55, .g = 0.85, .b = 1.0, .a = 1.0 },
        .command => .{ .r = 0.92, .g = 0.92, .b = 0.90, .a = 1.0 },
        .plain => .{ .r = 0.85, .g = 0.90, .b = 0.85, .a = 1.0 },
    };
}

pub fn drawStyledLine(
    editor_x: f32,
    y: f32,
    line: []const u8,
    workspace_path: []const u8,
    git: ?*const git_status.Status,
) void {
    if (line.len == 0) return;

    var prompt_buf: [256]u8 = undefined;
    var segments: [16]terminal_prompt.Segment = undefined;
    const seg_count = terminal_prompt.buildLineSegments(
        workspace_path,
        git,
        line,
        &prompt_buf,
        &segments,
    );

    var display: [512:0]u8 = undefined;
    const clipped = if (line.len > 511) line[0..511] else line;
    @memcpy(display[0..clipped.len], clipped);
    display[clipped.len] = 0;

    var spans: [16]renderer.TextSpan = undefined;
    for (0..seg_count) |i| {
        const seg = segments[i];
        const color = segmentColor(seg.kind);
        spans[i] = .{
            .offset = seg.offset,
            .length = @min(seg.length, clipped.len - seg.offset),
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = color.a,
        };
    }

    renderer.Renderer.drawStyledText(
        display[0..clipped.len],
        editor_x + text_inset_x,
        y,
        font_size,
        spans[0..seg_count],
    );
}

pub fn drawInputCursor(
    editor_x: f32,
    y: f32,
    line: []const u8,
    col: usize,
    visible: bool,
) void {
    if (!visible) return;
    const x = editor_x + text_inset_x + editor_scroll.cursorX(line, col, font_size);
    renderer.Renderer.drawRect(x, y + 1, 7, panel_scroll.bottom_line_h - 2, .{
        .r = 0.55,
        .g = 0.85,
        .b = 1.0,
        .a = 0.85,
    });
}

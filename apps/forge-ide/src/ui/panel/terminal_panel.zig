const std = @import("std");
const renderer = @import("forge-renderer");
const panel_scroll = @import("../core/panel_scroll.zig");
const editor_scroll = @import("../editor/editor_scroll.zig");
const terminal_prompt = @import("terminal_prompt.zig");
const git_status = @import("../../git/status.zig");

pub const font_size: f32 = 13.0;
pub const line_h: f32 = 20.0;
pub const text_inset_x: f32 = 40.0;
pub const session_tab_h: f32 = 20.0;
pub const session_tab_w: f32 = 48.0;

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
    return panel_y + 42.0;
}

pub fn hitSessionTab(editor_x: f32, editor_w: f32, panel_y: f32, x: f32, y: f32, _: usize) ?union(enum) { new, activate: usize } {
    // We moved these to the right side of the main tab bar.
    // For now we just return null or we could implement hit testing for the new layout.
    // The main tab bar is roughly at panel_y + 6 to panel_y + 34
    // Plus icon is at rx - 156
    const rx = editor_x + editor_w;
    if (y >= panel_y + 6 and y <= panel_y + 34) {
        if (x >= rx - 156 and x <= rx - 140) return .new; // Plus button
    }
    return null;
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

    const float_line = (y - top + scroll_y) / line_h;
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
        const y = top - scroll_y + @as(f32, @floatFromInt(line_idx)) * line_h;
        renderer.Renderer.drawRect(x0, y, @max(1, x1 - x0), line_h, highlight);
    }
}

fn segmentColor(kind: terminal_prompt.SegmentKind) renderer.Color {
    return switch (kind) {
        .folder => .{ .r = 0.00, .g = 0.90, .b = 0.58, .a = 1.0 },
        .muted => .{ .r = 0.56, .g = 0.58, .b = 0.64, .a = 1.0 },
        .branch => .{ .r = 0.00, .g = 0.90, .b = 0.58, .a = 1.0 },
        .marker_deleted => .{ .r = 0.95, .g = 0.42, .b = 0.42, .a = 1.0 },
        .marker_modified => .{ .r = 1.0, .g = 0.62, .b = 0.30, .a = 1.0 },
        .marker_staged => .{ .r = 0.42, .g = 0.88, .b = 0.52, .a = 1.0 },
        .marker_untracked => .{ .r = 0.55, .g = 0.72, .b = 1.0, .a = 1.0 },
        .marker_conflict => .{ .r = 0.95, .g = 0.45, .b = 0.95, .a = 1.0 },
        .marker_ahead, .marker_behind => .{ .r = 0.40, .g = 0.85, .b = 0.95, .a = 1.0 },
        .chevron => .{ .r = 0.00, .g = 0.90, .b = 0.58, .a = 1.0 },
        .command => .{ .r = 0.92, .g = 0.92, .b = 0.90, .a = 1.0 },
        .plain => .{ .r = 0.84, .g = 0.85, .b = 0.88, .a = 1.0 },
    };
}

const LineKind = enum {
    normal,
    activity,
    thinking,
    success,
    warning,
    diff_add,
    diff_del,
};

fn classifyLine(line: []const u8) LineKind {
    const trimmed = trimLineStart(line);
    if (trimmed.len == 0) return .normal;
    if (std.mem.startsWith(u8, trimmed, "Thinking")) return .thinking;
    if (std.mem.startsWith(u8, trimmed, "✓") or std.mem.startsWith(u8, trimmed, "✔")) return .success;
    if (std.mem.startsWith(u8, trimmed, "!") or std.mem.startsWith(u8, trimmed, "⚠")) return .warning;
    if (std.mem.startsWith(u8, trimmed, "+")) return .diff_add;
    if (std.mem.startsWith(u8, trimmed, "-")) return .diff_del;
    if (std.mem.startsWith(u8, trimmed, ">") or
        std.mem.startsWith(u8, trimmed, "›") or
        std.mem.startsWith(u8, trimmed, "Reading ") or
        std.mem.startsWith(u8, trimmed, "Analyzing ") or
        std.mem.startsWith(u8, trimmed, "Found "))
    {
        return .activity;
    }
    return .normal;
}

fn trimLineStart(line: []const u8) []const u8 {
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
    return line[start..];
}

fn lineColor(kind: LineKind) renderer.Color {
    return switch (kind) {
        .normal => .{ .r = 0.84, .g = 0.85, .b = 0.88, .a = 1.0 },
        .activity => .{ .r = 0.62, .g = 0.63, .b = 0.68, .a = 1.0 },
        .thinking => .{ .r = 0.23, .g = 0.62, .b = 1.0, .a = 1.0 },
        .success => .{ .r = 0.00, .g = 0.90, .b = 0.58, .a = 1.0 },
        .warning => .{ .r = 1.00, .g = 0.76, .b = 0.34, .a = 1.0 },
        .diff_add => .{ .r = 0.00, .g = 0.90, .b = 0.58, .a = 1.0 },
        .diff_del => .{ .r = 1.00, .g = 0.30, .b = 0.36, .a = 1.0 },
    };
}

fn drawLineBackground(editor_x: f32, editor_w: f32, y: f32, kind: LineKind) void {
    const card_x = editor_x + text_inset_x - 14;
    const card_w = @max(40, editor_w - text_inset_x - 28);
    switch (kind) {
        .activity => {
            renderer.Renderer.drawRoundedRect(card_x, y - 4, card_w, line_h + 6, 4, .{ .r = 0.13, .g = 0.13, .b = 0.14, .a = 1.0 });
        },
        .diff_add => {
            renderer.Renderer.drawRect(card_x + 16, y - 2, card_w - 32, line_h, .{ .r = 0.05, .g = 0.22, .b = 0.16, .a = 1.0 });
        },
        .diff_del => {
            renderer.Renderer.drawRect(card_x + 16, y - 2, card_w - 32, line_h, .{ .r = 0.24, .g = 0.10, .b = 0.11, .a = 1.0 });
        },
        else => {},
    }
}

pub fn drawStyledLine(
    editor_x: f32,
    editor_w: f32,
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

    const is_prompt = seg_count > 0 and segments[0].kind == .chevron;
    if (!is_prompt) {
        const kind = classifyLine(clipped);
        drawLineBackground(editor_x, editor_w, y, kind);
        renderer.Renderer.drawText(@ptrCast(&display), editor_x + text_inset_x, y + 1, font_size, lineColor(kind));
        return;
    }

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
        y + 1,
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
    renderer.Renderer.drawRect(x, y + 2, 8, line_h - 4, .{
        .r = 1.00,
        .g = 0.58,
        .b = 0.00,
        .a = 0.85,
    });
}

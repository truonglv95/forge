const renderer = @import("forge-renderer");
const editor_scroll = @import("../../editor/editor_scroll.zig");
const bracket_match = @import("../../editor/bracket_match.zig");
const Buffer = @import("forge-editor").Buffer;
const syntax = @import("syntax.zig");

pub fn drawBracketHighlight(
    editor_buf: *Buffer,
    match: bracket_match.Match,
    buf_line: usize,
    start_col: usize,
    end_col: usize,
    text_x: f32,
    line_y: f32,
    line_h: f32,
    font_size: f32,
    theme: *const @import("forge-workspace").Theme,
) void {
    const hl = syntax.color(theme.colors.selection);
    const mut = renderer.Color{ .r = hl.r, .g = hl.g, .b = hl.b, .a = 0.35 };
    highlightBracketAt(editor_buf, match.from, buf_line, start_col, end_col, text_x, line_y, line_h, font_size, mut);
    highlightBracketAt(editor_buf, match.to, buf_line, start_col, end_col, text_x, line_y, line_h, font_size, mut);
}

pub fn drawSelectionInSegment(
    editor_buf: *Buffer,
    buf_line: usize,
    seg_start_col: usize,
    seg_end_col: usize,
    seg_text_x: f32,
    line_y: f32,
    line_h: f32,
    font_size: f32,
    color: renderer.Color,
) void {
    if (!editor_buf.hasSelection()) return;
    const ord = editor_buf.selectionOrdered();
    if (buf_line < ord.start.row or buf_line > ord.end.row) return;
    const line = editor_buf.lineAt(buf_line);
    const sel_start: usize = if (buf_line == ord.start.row) ord.start.col else 0;
    const sel_end: usize = if (buf_line == ord.end.row) @min(ord.end.col, line.len) else line.len;
    const start_col = @max(seg_start_col, sel_start);
    const end_col = @min(seg_end_col, sel_end);
    if (start_col >= end_col) return;
    const x0 = seg_text_x + editor_scroll.cursorX(line, start_col, font_size) - editor_scroll.cursorX(line, seg_start_col, font_size);
    const x1 = seg_text_x + editor_scroll.cursorX(line, end_col, font_size) - editor_scroll.cursorX(line, seg_start_col, font_size);
    renderer.Renderer.drawRect(x0, line_y, @max(2, x1 - x0), line_h, color);
}

pub fn highlightBracketAt(
    editor_buf: *Buffer,
    pos: bracket_match.Position,
    buf_line: usize,
    start_col: usize,
    end_col: usize,
    text_x: f32,
    line_y: f32,
    line_h: f32,
    font_size: f32,
    color: renderer.Color,
) void {
    if (pos.row != buf_line) return;
    if (pos.col < start_col or pos.col >= end_col) return;
    const line = editor_buf.lineAt(buf_line);
    const x0 = text_x + editor_scroll.cursorX(line, pos.col, font_size);
    const x1 = text_x + editor_scroll.cursorX(line, pos.col + 1, font_size);
    renderer.Renderer.drawRect(x0, line_y, @max(4, x1 - x0), line_h, color);
}

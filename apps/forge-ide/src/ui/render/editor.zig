const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../state.zig");
const layout = @import("../layout.zig");
const editor_scroll = @import("../editor_scroll.zig");
const bracket_match = @import("../bracket_match.zig");
const word_wrap = @import("../word_wrap.zig");
const scrollbar = @import("../scrollbar.zig");
const tabs_ui = @import("../tabs.zig");
const proposal_review_panel = @import("../proposal_review_panel.zig");
const ai_settings_panel = @import("../ai_settings_panel.zig");
const render_theme = @import("theme.zig");
const Workbench = @import("../../workbench.zig").Workbench;
const Buffer = @import("forge-editor").Buffer;

fn c(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return render_theme.color(rgba);
}

fn drawHighlightedLine(line: []const u8, x: f32, y: f32, theme: *const @import("forge-workspace").Theme) void {
    const font_size = theme.editor_font_size;
    var spans: [96]renderer.TextSpan = undefined;
    var span_count: usize = 0;
    var i: usize = 0;
    while (i < line.len and span_count < spans.len) {
        const start = i;
        if (line[i] == ' ') {
            i += 1;
        } else if (isPunctuation(line[i])) {
            i += 1;
        } else {
            while (i < line.len and line[i] != ' ' and !isPunctuation(line[i])) : (i += 1) {}
        }
        const color = segmentColor(line, start, theme);
        spans[span_count] = .{
            .offset = start,
            .length = i - start,
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = color.a,
        };
        span_count += 1;
    }
    if (span_count == 0) return;
    renderer.Renderer.drawStyledText(line, x, y, font_size, spans[0..span_count]);
}

fn isPunctuation(ch: u8) bool {
    return ch == '(' or ch == ')' or ch == '{' or ch == '}' or ch == ';' or ch == ',' or ch == '[' or ch == ']';
}

fn segmentColor(line: []const u8, index: usize, theme: *const @import("forge-workspace").Theme) renderer.Color {
    const ch = line[index];
    if (ch == ' ' or ch == '\t') return c(theme.colors.editor_fg);
    if (isPunctuation(ch)) return c(theme.colors.punctuation);
    var end = index;
    while (end < line.len and line[end] != ' ' and !isPunctuation(line[end])) : (end += 1) {}
    const word = line[index..end];
    if (word.len > 0 and word[0] >= '0' and word[0] <= '9') return c(theme.colors.number);
    if (isKeyword(word)) return c(theme.colors.keyword);
    return c(theme.colors.editor_fg);
}
fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "pub", "fn", "const", "var", "struct", "enum", "union", "return", "try", "catch", "if", "else", "switch", "while", "for", "break", "continue", "defer", "errdefer" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}
fn drawBracketHighlight(
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
    const hl = c(theme.colors.selection);
    const mut = renderer.Color{ .r = hl.r, .g = hl.g, .b = hl.b, .a = 0.35 };
    highlightBracketAt(editor_buf, match.from, buf_line, start_col, end_col, text_x, line_y, line_h, font_size, mut);
    highlightBracketAt(editor_buf, match.to, buf_line, start_col, end_col, text_x, line_y, line_h, font_size, mut);
}

fn drawSelectionInSegment(
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

fn highlightBracketAt(
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

fn lineColAtBufferOffset(editor_buf: *Buffer, offset: usize) struct { line: usize, col: usize } {
    var pos: usize = 0;
    const line_count = editor_buf.lineCount();
    for (0..line_count) |line| {
        const line_len = editor_buf.lineAt(line).len;
        const line_end = pos + line_len;
        if (offset <= line_end) return .{ .line = line, .col = offset - pos };
        pos = line_end + 1;
    }
    if (line_count > 0) {
        const last = line_count - 1;
        return .{ .line = last, .col = editor_buf.lineAt(last).len };
    }
    return .{ .line = 0, .col = 0 };
}

fn reviewLineHasChange(
    wb: *Workbench,
    editor_buf: *Buffer,
    file_path: []const u8,
    line_index: usize,
) bool {
    if (!wb.agent.show_review) return false;
    wb.agent.lock();
    defer wb.agent.unlock();
    for (wb.agent.review.hunks) |hunk| {
        if (!hunk.accepted or !std.mem.eql(u8, hunk.path, file_path)) continue;
        if (hunk.edit_start == null or hunk.edit_end == null) return true;
        const del_start = lineColAtBufferOffset(editor_buf, @intCast(hunk.edit_start.?));
        const del_end = lineColAtBufferOffset(editor_buf, @intCast(hunk.edit_end.?));
        if (line_index >= del_start.line and line_index <= del_end.line) return true;
    }
    return false;
}

fn drawReviewLineOverlay(
    wb: *Workbench,
    theme: *const @import("forge-workspace").Theme,
    editor_buf: *Buffer,
    file_path: []const u8,
    line_index: usize,
    text_x: f32,
    line_y: f32,
    line_h: f32,
    font_size: f32,
) void {
    if (!wb.agent.show_review) return;
    wb.agent.lock();
    defer wb.agent.unlock();
    const line = editor_buf.lineAt(line_index);
    for (wb.agent.review.hunks) |hunk| {
        if (!hunk.accepted or !std.mem.eql(u8, hunk.path, file_path)) continue;
        const edit_start = hunk.edit_start orelse continue;
        const edit_end = hunk.edit_end orelse continue;
        const del_start = lineColAtBufferOffset(editor_buf, @intCast(edit_start));
        const del_end = lineColAtBufferOffset(editor_buf, @intCast(edit_end));
        if (line_index < del_start.line or line_index > del_end.line) continue;

        const start_col = if (line_index == del_start.line) del_start.col else 0;
        const end_col = if (line_index == del_end.line) del_end.col else line.len;
        const start_x = text_x + editor_scroll.cursorX(line, start_col, font_size);
        const end_x = text_x + editor_scroll.cursorX(line, end_col, font_size);
        renderer.Renderer.drawRect(start_x, line_y, @max(4, end_x - start_x), line_h, .{ .r = 0.75, .g = 0.2, .b = 0.2, .a = 0.28 });

        if (hunk.replacement) |replacement| {
            if (replacement.len > 0 and line_index == del_start.line) {
                const first_line_end = std.mem.indexOfScalar(u8, replacement, '\n') orelse replacement.len;
                const preview = replacement[0..first_line_end];
                const ins_x = text_x + editor_scroll.cursorX(line, start_col, font_size);
                const ins_w = @as(f32, @floatFromInt(preview.len)) * editor_scroll.charWidth(theme);
                renderer.Renderer.drawRect(ins_x, line_y, @max(4, ins_w), line_h, .{ .r = 0.2, .g = 0.65, .b = 0.3, .a = 0.35 });
            }
        }
    }
}

fn drawDecorations(
    editor_buf: *Buffer,
    buf_line: usize,
    text_x: f32,
    line_y: f32,
    line_h: f32,
    viewport_w: f32,
) void {
    for (editor_buf.decorations.items) |dec| {
        if (dec.row == buf_line) {
            const color = if (dec.kind == .addition)
                renderer.Color{ .r = 0.2, .g = 0.7, .b = 0.3, .a = 0.25 }
            else
                renderer.Color{ .r = 0.9, .g = 0.3, .b = 0.3, .a = 0.25 };

            renderer.Renderer.drawRect(text_x - 4, line_y, viewport_w, line_h, color);

            if (dec.kind == .deletion) {
                // Strike-through
                renderer.Renderer.drawRect(text_x, line_y + line_h / 2, viewport_w - 16, 1.5, .{ .r = 0.95, .g = 0.25, .b = 0.25, .a = 0.85 });
            }
        }
    }
}

fn drawEditorViewport(
    wb: *Workbench,
    editor_buf: *Buffer,
    editor_x: f32,
    editor_w: f32,
    editor_h: f32,
    scroll_y: f32,
    scroll_x: f32,
    file_path: []const u8,
    pane_focused: bool,
) void {
    const theme = &wb.theme;
    const editor_view_h = editor_scroll.viewportHeight(editor_h);
    const gutter = editor_scroll.gutterWidth(theme);
    const line_h = editor_scroll.lineHeight(theme);
    const font_size = theme.editor_font_size;
    const wrap_enabled = wb.user_settings.word_wrap;
    const effective_scroll_x = if (wrap_enabled) @as(f32, 0) else scroll_x;
    const text_x = editor_x + gutter - effective_scroll_x;
    const viewport_w = editor_scroll.viewportWidth(editor_w, theme);

    if (pane_focused and wb.editor_split) {
        renderer.Renderer.drawRect(editor_x, 65, editor_w, 2, c(theme.colors.tab_active_bg));
    }

    renderer.Renderer.drawRect(editor_x, 65, gutter, editor_view_h, c(theme.colors.sidebar_bg));
    renderer.Renderer.setClipRect(editor_x, 65, editor_w, editor_view_h);
    const show_cursor = @mod(state.time, 1.0) < 0.5;
    const show_editor_cursor = show_cursor and wb.focused_panel == .editor and pane_focused;
    const bracket_pair = if (show_editor_cursor and !wb.agent.worker_running)
        bracket_match.findMatch(editor_buf, editor_buf.cursor.row, editor_buf.cursor.col)
    else
        null;

    const line_count = editor_buf.lineCount();
    const content_h = if (wrap_enabled)
        word_wrap.contentHeight(editor_buf, viewport_w, font_size, theme)
    else
        editor_scroll.contentHeight(line_count, theme);
    const max_scroll_y = if (wrap_enabled)
        word_wrap.maxScrollY(editor_buf, editor_h, viewport_w, font_size, theme)
    else
        editor_scroll.maxScrollY(line_count, editor_h, theme);
    const max_line_len = editor_scroll.longestLineLen(editor_buf);
    const content_w = @as(f32, @floatFromInt(max_line_len)) * editor_scroll.charWidth(theme);
    const max_scroll_x = if (wrap_enabled) @as(f32, 0) else editor_scroll.maxScrollX(content_w, editor_w, theme);

    const show_diags = blk: {
        if (wb.diagnostics.active_path) |active_path| {
            break :blk std.mem.eql(u8, active_path, file_path);
        }
        break :blk false;
    };

    const diag_store = @import("../../workbench/diagnostics_store.zig");
    var line_num_y = editor_scroll.firstLineY(theme) - scroll_y;

    if (wrap_enabled) {
        const visual_count = word_wrap.totalVisualLines(editor_buf, viewport_w, font_size);
        for (0..visual_count) |visual_idx| {
            if (line_num_y + line_h >= 65 and line_num_y < 65 + editor_view_h) {
                const seg = word_wrap.segmentAt(editor_buf, visual_idx, viewport_w, font_size);
                if (seg.start_col == 0) {
                    if (wb.breakpoints.hasAt(file_path, seg.buf_line)) {
                        renderer.Renderer.drawRoundedRect(editor_x + 4, line_num_y + 4, 8, 8, 4, c(theme.colors.warning));
                    }
                    const debug_here = blk: {
                        if (wb.debug_stop_path) |stop_path| {
                            if (wb.debug_stop_line) |stop_line| {
                                break :blk std.mem.eql(u8, stop_path, file_path) and stop_line == seg.buf_line;
                            }
                        }
                        break :blk false;
                    };
                    if (debug_here) {
                        renderer.Renderer.drawText("→", editor_x + 2, line_num_y, font_size, c(theme.colors.accent));
                    }
                    var num_buf: [16]u8 = undefined;
                    const line_str = std.fmt.bufPrintZ(&num_buf, "{d}", .{seg.buf_line + 1}) catch "";
                    renderer.Renderer.drawText(line_str, editor_x + 10, line_num_y, font_size, c(theme.colors.line_number));
                    if (show_diags) {
                        if (diag_store.worstSeverityOnLine(wb.diagnostics.list, seg.buf_line)) |severity| {
                            const marker = switch (severity) {
                                .err => "!",
                                .warning => "~",
                                else => "·",
                            };
                            const marker_color = switch (severity) {
                                .err => c(theme.colors.warning),
                                .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                                else => c(theme.colors.text_muted),
                            };
                            renderer.Renderer.drawText(marker, editor_x + gutter - 14, line_num_y, font_size, marker_color);
                        }
                    }
                }
            }
            line_num_y += line_h;
        }
    } else {
        for (0..line_count) |idx| {
            if (line_num_y + line_h >= 65 and line_num_y < 65 + editor_view_h) {
                if (wb.breakpoints.hasAt(file_path, idx)) {
                    renderer.Renderer.drawRoundedRect(editor_x + 4, line_num_y + 4, 8, 8, 4, c(theme.colors.warning));
                }
                const debug_here = blk: {
                    if (wb.debug_stop_path) |stop_path| {
                        if (wb.debug_stop_line) |stop_line| {
                            break :blk std.mem.eql(u8, stop_path, file_path) and stop_line == idx;
                        }
                    }
                    break :blk false;
                };
                if (debug_here) {
                    renderer.Renderer.drawText("→", editor_x + 2, line_num_y, font_size, c(theme.colors.accent));
                }
                var num_buf: [16]u8 = undefined;
                const line_str = std.fmt.bufPrintZ(&num_buf, "{d}", .{idx + 1}) catch "";
                renderer.Renderer.drawText(line_str, editor_x + 10, line_num_y, font_size, c(theme.colors.line_number));
                if (show_diags) {
                    if (diag_store.worstSeverityOnLine(wb.diagnostics.list, idx)) |severity| {
                        const marker = switch (severity) {
                            .err => "!",
                            .warning => "~",
                            else => "·",
                        };
                        const marker_color = switch (severity) {
                            .err => c(theme.colors.warning),
                            .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                            else => c(theme.colors.text_muted),
                        };
                        renderer.Renderer.drawText(marker, editor_x + gutter - 14, line_num_y, font_size, marker_color);
                    }
                }
                if (reviewLineHasChange(wb, editor_buf, file_path, idx)) {
                    renderer.Renderer.drawText("±", editor_x + gutter - 14, line_num_y, font_size, .{ .r = 0.55, .g = 0.85, .b = 0.95, .a = 1.0 });
                }
            }
            line_num_y += line_h;
        }
    }

    renderer.Renderer.setClipRect(editor_x + gutter, 65, editor_w - gutter, editor_view_h);
    line_num_y = editor_scroll.firstLineY(theme) - scroll_y;

    if (wrap_enabled) {
        const visual_count = word_wrap.totalVisualLines(editor_buf, viewport_w, font_size);
        const cursor_visual = word_wrap.visualIndexForCursor(editor_buf, editor_buf.cursor.row, editor_buf.cursor.col, viewport_w, font_size);
        for (0..visual_count) |visual_idx| {
            if (line_num_y + line_h >= 65 and line_num_y < 65 + editor_view_h) {
                const seg = word_wrap.segmentAt(editor_buf, visual_idx, viewport_w, font_size);
                const slice = editor_buf.lineAt(seg.buf_line)[seg.start_col..seg.end_col];
                const seg_text_x = text_x + editor_scroll.cursorX(editor_buf.lineAt(seg.buf_line), seg.start_col, font_size);

                const debug_here = blk: {
                    if (wb.debug_stop_path) |stop_path| {
                        if (wb.debug_stop_line) |stop_line| {
                            break :blk std.mem.eql(u8, stop_path, file_path) and stop_line == seg.buf_line and seg.start_col == 0;
                        }
                    }
                    break :blk false;
                };
                if (debug_here) {
                    renderer.Renderer.drawRect(seg_text_x - 4, line_num_y, viewport_w, line_h, .{ .r = 0.2, .g = 0.45, .b = 0.75, .a = 0.18 });
                }
                drawDecorations(editor_buf, seg.buf_line, seg_text_x, line_num_y, line_h, viewport_w);
                drawSelectionInSegment(editor_buf, seg.buf_line, seg.start_col, seg.end_col, seg_text_x, line_num_y, line_h, font_size, .{ .r = 0.35, .g = 0.55, .b = 0.95, .a = 0.35 });
                drawReviewLineOverlay(wb, theme, editor_buf, file_path, seg.buf_line, seg_text_x, line_num_y, line_h, font_size);
                drawFindHighlights(wb, editor_buf, seg.buf_line, seg_text_x, line_num_y, line_h, font_size);
                drawHighlightedLine(slice, seg_text_x, line_num_y, theme);
                if (bracket_pair) |pair| {
                    drawBracketHighlight(editor_buf, pair, seg.buf_line, seg.start_col, seg.end_col, seg_text_x, line_num_y, line_h, font_size, theme);
                }
                if (show_diags) {
                    for (wb.diagnostics.list.items) |diag| {
                        if (diag.line != seg.buf_line) continue;
                        const line = editor_buf.lineAt(seg.buf_line);
                        const start_x = seg_text_x + editor_scroll.cursorX(line, @max(seg.start_col, @min(diag.character, seg.end_col)), font_size) - editor_scroll.cursorX(line, seg.start_col, font_size);
                        const end_col = @min(if (diag.end_line == seg.buf_line) diag.end_character else line.len, seg.end_col);
                        const end_x = seg_text_x + editor_scroll.cursorX(line, @max(seg.start_col, end_col), font_size) - editor_scroll.cursorX(line, seg.start_col, font_size);
                        const underline_y = line_num_y + line_h - 3;
                        const underline_color = switch (diag.severity) {
                            .err => c(theme.colors.warning),
                            .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                            else => c(theme.colors.text_muted),
                        };
                        renderer.Renderer.drawRect(start_x, underline_y, @max(4, end_x - start_x), 2, underline_color);
                    }
                }
                if (show_editor_cursor and visual_idx == cursor_visual) {
                    const line = editor_buf.lineAt(seg.buf_line);
                    const cursor_x = text_x + editor_scroll.cursorX(line, editor_buf.cursor.col, font_size);
                    renderer.Renderer.drawText("|", cursor_x, line_num_y, font_size, c(theme.colors.cursor));
                }
            }
            line_num_y += line_h;
        }
    } else {
        for (0..line_count) |idx| {
            if (line_num_y + line_h >= 65 and line_num_y < 65 + editor_view_h) {
                const debug_here = blk: {
                    if (wb.debug_stop_path) |stop_path| {
                        if (wb.debug_stop_line) |stop_line| {
                            break :blk std.mem.eql(u8, stop_path, file_path) and stop_line == idx;
                        }
                    }
                    break :blk false;
                };
                if (debug_here) {
                    renderer.Renderer.drawRect(text_x - 4, line_num_y, content_w + 8, line_h, .{ .r = 0.2, .g = 0.45, .b = 0.75, .a = 0.18 });
                }
                drawDecorations(editor_buf, idx, text_x, line_num_y, line_h, content_w);
                drawSelectionInSegment(editor_buf, idx, 0, editor_buf.lineAt(idx).len, text_x, line_num_y, line_h, font_size, .{ .r = 0.35, .g = 0.55, .b = 0.95, .a = 0.35 });
                drawReviewLineOverlay(wb, theme, editor_buf, file_path, idx, text_x, line_num_y, line_h, font_size);
                drawFindHighlights(wb, editor_buf, idx, text_x, line_num_y, line_h, font_size);
                drawHighlightedLine(editor_buf.lineAt(idx), text_x, line_num_y, theme);
                if (bracket_pair) |pair| {
                    drawBracketHighlight(editor_buf, pair, idx, 0, editor_buf.lineAt(idx).len, text_x, line_num_y, line_h, font_size, theme);
                }
                if (show_diags) {
                    for (wb.diagnostics.list.items) |diag| {
                        if (diag.line != idx) continue;
                        const line = editor_buf.lineAt(idx);
                        const start_x = text_x + editor_scroll.cursorX(line, @min(diag.character, line.len), font_size);
                        const end_col = @min(if (diag.end_line == idx) diag.end_character else line.len, line.len);
                        const end_x = text_x + editor_scroll.cursorX(line, end_col, font_size);
                        const underline_y = line_num_y + line_h - 3;
                        const underline_color = switch (diag.severity) {
                            .err => c(theme.colors.warning),
                            .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                            else => c(theme.colors.text_muted),
                        };
                        renderer.Renderer.drawRect(start_x, underline_y, @max(4, end_x - start_x), 2, underline_color);
                    }
                }
                if (show_editor_cursor and idx == editor_buf.cursor.row) {
                    const line = editor_buf.lineAt(idx);
                    const cursor_x = text_x + editor_scroll.cursorX(line, editor_buf.cursor.col, font_size);
                    renderer.Renderer.drawText("|", cursor_x, line_num_y, font_size, c(theme.colors.cursor));
                }
            }
            line_num_y += line_h;
        }
    }

    renderer.Renderer.setClipRect(editor_x, 65, editor_w, editor_view_h);
    const show_editor_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, editor_x, 65, editor_w, editor_view_h);
    scrollbar.drawVertical(
        editor_x + editor_w - scrollbar.track_w - 4,
        65,
        editor_view_h,
        scroll_y,
        max_scroll_y,
        content_h,
        editor_view_h,
        show_editor_scroll,
    );
    scrollbar.drawHorizontal(
        editor_x + gutter,
        65 + editor_view_h - scrollbar.track_w - 2,
        viewport_w,
        scroll_x,
        max_scroll_x,
        content_w,
        viewport_w,
        show_editor_scroll,
    );
    renderer.Renderer.clearClipRect();
}

pub fn drawEditorPanel(wb: *Workbench, editor_buf: ?*Buffer, editor_x: f32, editor_w: f32, editor_h: f32, _: f32) void {
    if (wb.proposal_review_open) {
        const theme = &wb.theme;
        proposal_review_panel.drawTab(editor_x, c(theme.colors.accent), c(theme.colors.editor_bg), c(theme.colors.border), c(theme.colors.text_primary), theme.ui_font_size);
        proposal_review_panel.draw(wb, editor_x, editor_w, editor_h);
        return;
    }
    if (wb.ai_settings_open) {
        ai_settings_panel.draw(wb, editor_x, editor_w, editor_h);
        return;
    }
    const theme = &wb.theme;
    const ui_size = theme.ui_font_size;
    renderer.Renderer.drawRect(editor_x, tabs_ui.tab_bar_top, editor_w, tabs_ui.tab_bar_height, c(theme.colors.tab_bar_bg));
    renderer.Renderer.drawRect(editor_x, tabs_ui.tab_bar_top + tabs_ui.tab_bar_height - 1, editor_w, 1, c(theme.colors.border));
    renderer.Renderer.setClipRect(editor_x, tabs_ui.tab_bar_top, editor_w, tabs_ui.tab_bar_height);

    var tab_layouts: std.ArrayList(tabs_ui.TabLayout) = .empty;
    defer tab_layouts.deinit(state.gpa);
    tabs_ui.collectLayouts(wb, editor_x, &tab_layouts) catch {};

    for (tab_layouts.items) |tab_layout| {
        const tab_index = tab_layout.index;
        const doc = &wb.tabs.tabs.items[tab_index];
        var label_buf: [128]u8 = undefined;
        const label = wb.tabLabel(tab_index, &label_buf);
        const is_active = tab_index == wb.tabs.active;

        if (is_active) {
            // Draw the active tab background (overwriting the tab bar border)
            renderer.Renderer.drawRect(tab_layout.x, tabs_ui.tab_y, tab_layout.width, tabs_ui.tab_height + 1, c(theme.colors.editor_bg));

            // Draw subtle borders: top, left, right
            const border = c(theme.colors.border);
            renderer.Renderer.drawRect(tab_layout.x, tabs_ui.tab_y, tab_layout.width, 1, border); // top
            renderer.Renderer.drawRect(tab_layout.x, tabs_ui.tab_y, 1, tabs_ui.tab_height, border); // left
            renderer.Renderer.drawRect(tab_layout.x + tab_layout.width - 1, tabs_ui.tab_y, 1, tabs_ui.tab_height, border); // right
        } else {
            // Optional: Draw a separator line between inactive tabs
            const border = c(theme.colors.border);
            // Draw a subtle left separator for inactive tabs (unless it's the first tab)
            if (tab_index > 0 and tab_index - 1 != wb.tabs.active) {
                renderer.Renderer.drawRect(tab_layout.x, tabs_ui.tab_y + 8, 1, tabs_ui.tab_height - 16, .{ .r = border.r, .g = border.g, .b = border.b, .a = border.a * 0.5 });
            }
        }
        var tab_label_buf: [128:0]u8 = undefined;
        const max_label_chars = @min(label.len, tab_label_buf.len - 1);
        @memcpy(tab_label_buf[0..max_label_chars], label[0..max_label_chars]);
        tab_label_buf[max_label_chars] = 0;
        const color = if (is_active) c(theme.colors.text_primary) else c(theme.colors.text_muted);
        renderer.Renderer.drawText(@ptrCast(&tab_label_buf), tab_layout.x + 12, 43, ui_size, color);

        if (doc.external_conflict) {
            renderer.Renderer.drawText("!", tab_layout.x + tab_layout.width - tabs_ui.close_button_width - 10, 43, ui_size, c(theme.colors.warning));
        }

        const close_x = tab_layout.x + tab_layout.width - tabs_ui.close_button_width + 4;
        const close_color = if (is_active) c(theme.colors.text_secondary) else c(theme.colors.text_muted);
        renderer.Renderer.drawText("x", close_x, 43, ui_size, close_color);
    }

    const max_tab_scroll = tabs_ui.maxScroll(wb, editor_w);
    if (max_tab_scroll > 0) {
        const scroll_ratio = wb.tab_scroll_x / max_tab_scroll;
        const bar_w: f32 = @max(24.0, editor_w * (editor_w / tabs_ui.totalContentWidth(wb)));
        const bar_x = editor_x + scroll_ratio * (editor_w - bar_w);
        renderer.Renderer.drawRoundedRect(bar_x, tabs_ui.tab_bar_top + tabs_ui.tab_bar_height - 4, bar_w, 3, 1.5, .{ .r = 0.35, .g = 0.35, .b = 0.35, .a = 0.7 });
    }

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    var rx = editor_x + editor_w - 24;
    const my = state.last_mouse_y;
    const mx = state.last_mouse_x;

    if (mx >= rx and mx < rx + 16 and my >= layout.header_height + 4 and my < layout.header_height + 24) {
        renderer.Renderer.drawRoundedRect(rx - 2, layout.header_height + 4, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, rx, layout.header_height + 7, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= layout.header_height + 4 and my < layout.header_height + 24) {
        renderer.Renderer.drawRoundedRect(rx - 2, layout.header_height + 4, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.repo, rx, layout.header_height + 7, 16, 16, icon_c);

    renderer.Renderer.clearClipRect();

    const pane_w = wb.paneWidth(editor_w);
    if (wb.editor_split) {
        if (wb.docForPane(.primary)) |doc| {
            drawEditorViewport(
                wb,
                &doc.buffer,
                editor_x,
                pane_w,
                editor_h,
                wb.editor_scroll_y,
                wb.editor_scroll_x,
                doc.path,
                wb.editor_pane_focus == .primary,
            );
        }
        const divider_x = editor_x + pane_w;
        renderer.Renderer.drawRect(divider_x, 65, 4, editor_scroll.viewportHeight(editor_h), c(theme.colors.tab_bar_bg));
        if (wb.docForPane(.secondary)) |doc| {
            drawEditorViewport(
                wb,
                &doc.buffer,
                divider_x + 4,
                pane_w,
                editor_h,
                wb.split_scroll_y,
                wb.split_scroll_x,
                doc.path,
                wb.editor_pane_focus == .secondary,
            );
        }
    } else if (editor_buf) |buf| {
        const path = wb.activeFilePath() orelse "";
        drawEditorViewport(wb, buf, editor_x, editor_w, editor_h, wb.editor_scroll_y, wb.editor_scroll_x, path, true);
    }

    if (wb.completions.visible and wb.completions.list.items.len > 0 and wb.focused_panel == .editor) {
        const gutter = editor_scroll.gutterWidth(theme);
        const focus_x = wb.paneOriginX(editor_x, editor_w, wb.focusedPane());
        const focus_w = pane_w;
        const popup_x = focus_x + gutter + 8;
        const popup_y: f32 = 90;
        const popup_w = @min(focus_w - gutter - 16, 360);
        const row_h: f32 = 16;
        const count = @min(wb.completions.list.items.len, 10);
        const popup_h = @as(f32, @floatFromInt(count)) * row_h + 8;
        renderer.Renderer.drawRoundedRect(popup_x, popup_y, popup_w, popup_h, 6, .{ .r = 0.14, .g = 0.16, .b = 0.22, .a = 0.98 });
        var row: usize = 0;
        while (row < count) : (row += 1) {
            const item = wb.completions.list.items[row];
            const row_y = popup_y + 4 + @as(f32, @floatFromInt(row)) * row_h;
            if (row == wb.completions.selected) {
                renderer.Renderer.drawRect(popup_x + 4, row_y, popup_w - 8, row_h, .{ .r = 0.22, .g = 0.34, .b = 0.52, .a = 1.0 });
            }
            var label_buf: [128:0]u8 = undefined;
            const clipped = if (item.label.len > 127) item.label[0..127] else item.label;
            @memcpy(label_buf[0..clipped.len], clipped);
            label_buf[clipped.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&label_buf), popup_x + 8, row_y + 3, 11.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
        }
    }
    if (wb.find_bar.open or wb.goto_bar.open or wb.rename_bar.open) {
        drawEditorOverlay(wb, editor_x, editor_w);
    }
    if (wb.focused_panel == .editor) {
        drawHoverTooltip(wb, wb.paneOriginX(editor_x, editor_w, wb.focusedPane()), pane_w);
    }
    renderer.Renderer.clearClipRect();
}

fn drawHoverTooltip(wb: *Workbench, editor_x: f32, editor_w: f32) void {
    const text = wb.hover.text orelse return;
    if (text.len == 0) return;

    const font_size: f32 = 11.0;
    const line_h: f32 = 14.0;
    const padding: f32 = 8.0;
    const max_w: f32 = @min(420, editor_w - 24);
    const max_lines: usize = 12;
    const max_chars_per_line: usize = 64;

    var lines: [max_lines][]const u8 = undefined;
    var line_is_code: [max_lines]bool = undefined;
    var line_count: usize = 0;
    var in_code_block = false;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len and line_count < max_lines) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            var slice = text[line_start..i];
            if (std.mem.startsWith(u8, slice, "```")) {
                in_code_block = !in_code_block;
                line_start = i + 1;
                continue;
            }
            slice = std.mem.trim(u8, slice, " \t\r");
            if (slice.len == 0) {
                line_start = i + 1;
                continue;
            }
            const is_code = in_code_block or (slice.len >= 2 and slice[0] == '`' and slice[slice.len - 1] == '`');
            var chunk_start: usize = 0;
            while (chunk_start < slice.len and line_count < max_lines) {
                const chunk_end = @min(chunk_start + max_chars_per_line, slice.len);
                lines[line_count] = slice[chunk_start..chunk_end];
                line_is_code[line_count] = is_code;
                line_count += 1;
                if (chunk_end >= slice.len) break;
                chunk_start = chunk_end;
            }
            line_start = i + 1;
        }
    }
    if (line_count == 0) return;

    var box_w: f32 = 0;
    for (lines[0..line_count]) |line| {
        box_w = @max(box_w, renderer.Renderer.measureText(line, font_size));
    }
    box_w = @min(max_w, box_w + padding * 2);
    const box_h = @as(f32, @floatFromInt(line_count)) * line_h + padding * 2;
    var box_x = wb.hover.anchor_x + 12;
    var box_y = wb.hover.anchor_y - box_h - 8;
    if (box_x + box_w > editor_x + editor_w - 8) box_x = editor_x + editor_w - box_w - 8;
    if (box_x < editor_x + 8) box_x = editor_x + 8;
    if (box_y < 70) box_y = wb.hover.anchor_y + 18;

    renderer.Renderer.drawRect(box_x, box_y, box_w, box_h, .{ .r = 0.14, .g = 0.16, .b = 0.2, .a = 0.98 });
    var y = box_y + padding;
    for (lines[0..line_count], line_is_code[0..line_count]) |line, is_code| {
        var buf: [256:0]u8 = undefined;
        var clipped = line;
        if (is_code and clipped.len >= 2 and clipped[0] == '`' and clipped[clipped.len - 1] == '`') {
            clipped = clipped[1 .. clipped.len - 1];
        }
        const copy_len = @min(clipped.len, 255);
        @memcpy(buf[0..copy_len], clipped[0..copy_len]);
        buf[copy_len] = 0;
        const color = if (is_code)
            renderer.Color{ .r = 0.75, .g = 0.9, .b = 1.0, .a = 1.0 }
        else
            renderer.Color{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 };
        renderer.Renderer.drawText(@ptrCast(&buf), box_x + padding, y, font_size, color);
        y += line_h;
    }
}

fn drawFindHighlights(
    wb: *Workbench,
    buf: *Buffer,
    row: usize,
    text_x: f32,
    line_y: f32,
    line_h: f32,
    font_size: f32,
) void {
    if (!wb.find_bar.open or wb.find_bar.matches.len == 0) return;
    const line = buf.lineAt(row);
    for (wb.find_bar.matches, 0..) |match, index| {
        if (match.row != row) continue;
        const start_x = text_x + editor_scroll.cursorX(line, match.col, font_size);
        const end_x = text_x + editor_scroll.cursorX(line, @min(match.col + match.len, line.len), font_size);
        const is_active = index == wb.find_bar.match_index;
        const color = if (is_active)
            renderer.Color{ .r = 0.95, .g = 0.75, .b = 0.2, .a = 0.45 }
        else
            renderer.Color{ .r = 0.55, .g = 0.65, .b = 0.85, .a = 0.35 };
        renderer.Renderer.drawRect(start_x, line_y, @max(4, end_x - start_x), line_h - 2, color);
    }
}

fn drawEditorOverlay(wb: *Workbench, editor_x: f32, editor_w: f32) void {
    const bar_h: f32 = if (wb.find_bar.open and wb.find_bar.replace_mode) 56 else 32;
    const bar_y: f32 = tabs_ui.tab_bar_top + tabs_ui.tab_bar_height;
    renderer.Renderer.drawRect(editor_x, bar_y, editor_w, bar_h, .{ .r = 0.12, .g = 0.14, .b = 0.18, .a = 0.98 });

    if (wb.find_bar.open) {
        var query_buf: [256:0]u8 = undefined;
        const query = wb.find_bar.query.lineAt(0);
        const clipped_q = if (query.len > 255) query[0..255] else query;
        @memcpy(query_buf[0..clipped_q.len], clipped_q);
        query_buf[clipped_q.len] = 0;
        renderer.Renderer.drawText("Find:", editor_x + 12, bar_y + 8, 11.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&query_buf), editor_x + 56, bar_y + 8, 11.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });

        if (wb.find_bar.replace_mode) {
            var replace_buf: [256:0]u8 = undefined;
            const replacement = wb.find_bar.replace.lineAt(0);
            const clipped_r = if (replacement.len > 255) replacement[0..255] else replacement;
            @memcpy(replace_buf[0..clipped_r.len], clipped_r);
            replace_buf[clipped_r.len] = 0;
            renderer.Renderer.drawText("With:", editor_x + 12, bar_y + 30, 11.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
            renderer.Renderer.drawText(@ptrCast(&replace_buf), editor_x + 56, bar_y + 30, 11.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
        }

        var count_buf: [64:0]u8 = undefined;
        const count_msg = if (wb.find_bar.matches.len > 0)
            std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ wb.find_bar.match_index + 1, wb.find_bar.matches.len }) catch ""
        else
            std.fmt.bufPrint(&count_buf, "0/0", .{}) catch "0/0";
        count_buf[count_msg.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&count_buf), editor_x + editor_w - 80, bar_y + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    }

    if (wb.goto_bar.open) {
        var line_buf: [64:0]u8 = undefined;
        const input = wb.goto_bar.input.lineAt(0);
        const clipped = if (input.len > 63) input[0..63] else input;
        @memcpy(line_buf[0..clipped.len], clipped);
        line_buf[clipped.len] = 0;
        renderer.Renderer.drawText("Go to line:", editor_x + 12, bar_y + 8, 11.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&line_buf), editor_x + 96, bar_y + 8, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
    }

    if (wb.rename_bar.open) {
        var name_buf: [128:0]u8 = undefined;
        const input = wb.rename_bar.input.lineAt(0);
        const clipped = if (input.len > 127) input[0..127] else input;
        @memcpy(name_buf[0..clipped.len], clipped);
        name_buf[clipped.len] = 0;
        renderer.Renderer.drawText("Rename:", editor_x + 12, bar_y + 8, 11.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&name_buf), editor_x + 80, bar_y + 8, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
    }
}

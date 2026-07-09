const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const editor_scroll = @import("../../editor/editor_scroll.zig");
const bracket_match = @import("../../editor/bracket_match.zig");
const word_wrap = @import("../../editor/word_wrap.zig");
const scrollbar = @import("../../core/scrollbar.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const Buffer = @import("forge-editor").Buffer;
const syntax = @import("syntax.zig");
const bracket = @import("bracket.zig");
const review_overlay = @import("review_overlay.zig");
const decorations = @import("decorations.zig");
const overlays = @import("overlays.zig");

pub fn drawEditorViewport(
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
        renderer.Renderer.drawRect(editor_x, 65, editor_w, 2, syntax.color(theme.colors.tab_active_bg));
    }

    renderer.Renderer.drawRect(editor_x, 65, gutter, editor_view_h, syntax.color(theme.colors.sidebar_bg));
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

    const diag_store = @import("../../../workbench/diagnostics_store.zig");
    var line_num_y = editor_scroll.firstLineY(theme) - scroll_y;

    if (wrap_enabled) {
        const visual_count = word_wrap.totalVisualLines(editor_buf, viewport_w, font_size);
        for (0..visual_count) |visual_idx| {
            if (line_num_y + line_h >= 65 and line_num_y < 65 + editor_view_h) {
                const seg = word_wrap.segmentAt(editor_buf, visual_idx, viewport_w, font_size);
                if (seg.start_col == 0) {
                    if (wb.breakpoints.hasAt(file_path, seg.buf_line)) {
                        renderer.Renderer.drawRoundedRect(editor_x + 4, line_num_y + 4, 8, 8, 4, syntax.color(theme.colors.warning));
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
                        renderer.Renderer.drawText("→", editor_x + 2, line_num_y, font_size, syntax.color(theme.colors.accent));
                    }
                    var num_buf: [16]u8 = undefined;
                    const line_str = std.fmt.bufPrintZ(&num_buf, "{d}", .{seg.buf_line + 1}) catch "";
                    renderer.Renderer.drawText(line_str, editor_x + 10, line_num_y, font_size, syntax.color(theme.colors.line_number));
                    if (show_diags) {
                        if (diag_store.worstSeverityOnLine(wb.diagnostics.list, seg.buf_line)) |severity| {
                            const marker = switch (severity) {
                                .err => "!",
                                .warning => "~",
                                else => "·",
                            };
                            const marker_color = switch (severity) {
                                .err => syntax.color(theme.colors.warning),
                                .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                                else => syntax.color(theme.colors.text_muted),
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
                    renderer.Renderer.drawRoundedRect(editor_x + 4, line_num_y + 4, 8, 8, 4, syntax.color(theme.colors.warning));
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
                    renderer.Renderer.drawText("→", editor_x + 2, line_num_y, font_size, syntax.color(theme.colors.accent));
                }
                var num_buf: [16]u8 = undefined;
                const line_str = std.fmt.bufPrintZ(&num_buf, "{d}", .{idx + 1}) catch "";
                renderer.Renderer.drawText(line_str, editor_x + 10, line_num_y, font_size, syntax.color(theme.colors.line_number));
                if (show_diags) {
                    if (diag_store.worstSeverityOnLine(wb.diagnostics.list, idx)) |severity| {
                        const marker = switch (severity) {
                            .err => "!",
                            .warning => "~",
                            else => "·",
                        };
                        const marker_color = switch (severity) {
                            .err => syntax.color(theme.colors.warning),
                            .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                            else => syntax.color(theme.colors.text_muted),
                        };
                        renderer.Renderer.drawText(marker, editor_x + gutter - 14, line_num_y, font_size, marker_color);
                    }
                }
                if (review_overlay.reviewLineHasChange(wb, editor_buf, file_path, idx)) {
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
                decorations.drawDecorations(editor_buf, seg.buf_line, seg_text_x, line_num_y, line_h, viewport_w);
                bracket.drawSelectionInSegment(editor_buf, seg.buf_line, seg.start_col, seg.end_col, seg_text_x, line_num_y, line_h, font_size, .{ .r = 0.35, .g = 0.55, .b = 0.95, .a = 0.35 });
                review_overlay.drawReviewLineOverlay(wb, theme, editor_buf, file_path, seg.buf_line, seg_text_x, line_num_y, line_h, font_size);
                overlays.drawFindHighlights(wb, editor_buf, seg.buf_line, seg_text_x, line_num_y, line_h, font_size);

                const semantic_tokens = blk: {
                    if (wb.lsp_sync.entries.get(file_path)) |entry| {
                        break :blk entry.semantic_tokens;
                    }
                    break :blk null;
                };
                syntax.drawHighlightedLine(slice, seg.buf_line, seg_text_x, line_num_y, theme, semantic_tokens);

                if (bracket_pair) |pair| {
                    bracket.drawBracketHighlight(editor_buf, pair, seg.buf_line, seg.start_col, seg.end_col, seg_text_x, line_num_y, line_h, font_size, theme);
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
                            .err => syntax.color(theme.colors.warning),
                            .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                            else => syntax.color(theme.colors.text_muted),
                        };
                        renderer.Renderer.drawRect(start_x, underline_y, @max(4, end_x - start_x), 2, underline_color);
                    }
                }
                if (show_editor_cursor and visual_idx == cursor_visual) {
                    const line = editor_buf.lineAt(seg.buf_line);
                    const cursor_x = text_x + editor_scroll.cursorX(line, editor_buf.cursor.col, font_size);
                    renderer.Renderer.drawText("|", cursor_x, line_num_y, font_size, syntax.color(theme.colors.cursor));
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
                decorations.drawDecorations(editor_buf, idx, text_x, line_num_y, line_h, content_w);
                bracket.drawSelectionInSegment(editor_buf, idx, 0, editor_buf.lineAt(idx).len, text_x, line_num_y, line_h, font_size, .{ .r = 0.35, .g = 0.55, .b = 0.95, .a = 0.35 });
                review_overlay.drawReviewLineOverlay(wb, theme, editor_buf, file_path, idx, text_x, line_num_y, line_h, font_size);
                overlays.drawFindHighlights(wb, editor_buf, idx, text_x, line_num_y, line_h, font_size);

                const semantic_tokens = blk: {
                    if (wb.lsp_sync.entries.get(file_path)) |entry| {
                        break :blk entry.semantic_tokens;
                    }
                    break :blk null;
                };
                syntax.drawHighlightedLine(editor_buf.lineAt(idx), idx, text_x, line_num_y, theme, semantic_tokens);

                if (bracket_pair) |pair| {
                    bracket.drawBracketHighlight(editor_buf, pair, idx, 0, editor_buf.lineAt(idx).len, text_x, line_num_y, line_h, font_size, theme);
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
                            .err => syntax.color(theme.colors.warning),
                            .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                            else => syntax.color(theme.colors.text_muted),
                        };
                        renderer.Renderer.drawRect(start_x, underline_y, @max(4, end_x - start_x), 2, underline_color);
                    }
                }
                if (show_editor_cursor and idx == editor_buf.cursor.row) {
                    const line = editor_buf.lineAt(idx);
                    const cursor_x = text_x + editor_scroll.cursorX(line, editor_buf.cursor.col, font_size);
                    renderer.Renderer.drawText("|", cursor_x, line_num_y, font_size, syntax.color(theme.colors.cursor));
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

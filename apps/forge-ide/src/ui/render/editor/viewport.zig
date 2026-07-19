const std = @import("std");
const core = @import("forge-core");
const telemetry = core.telemetry;
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
const conflict_resolver = @import("../../../workbench/conflict_resolver.zig");
const inlay_hints_render = @import("inlay_hints.zig");

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
    var span = telemetry.startSpan("ide", "render_frame_scroll");
    defer span.end();
    wb.lsp.diagnostics.mutex.lock();
    defer wb.lsp.diagnostics.mutex.unlock();
    wb.lsp.sync.mutex.lock();
    defer wb.lsp.sync.mutex.unlock();

    const theme = &wb.theme;
    const editor_view_h = editor_scroll.viewportHeight(editor_h);
    const gutter = editor_scroll.gutterWidth(theme);
    const line_h = editor_scroll.lineHeight(theme);
    const font_size = theme.editor_font_size;
    const wrap_enabled = wb.user_settings.word_wrap;
    const effective_scroll_x = if (wrap_enabled) @as(f32, 0) else scroll_x;
    const text_x = editor_x + gutter - effective_scroll_x;
    const viewport_w = editor_scroll.viewportWidth(editor_w, theme);

    const content_top = editor_scroll.content_top;

    if (pane_focused and wb.editor_split) {
        renderer.Renderer.drawRect(editor_x, content_top, editor_w, 2, syntax.color(theme.colors.tab_active_bg));
    }

    renderer.Renderer.drawRect(editor_x, content_top, gutter, editor_view_h, syntax.color(theme.colors.sidebar_bg));
    renderer.Renderer.setClipRect(editor_x, content_top, editor_w, editor_view_h);
    const show_cursor = @mod(state.time, 1.0) < 0.5;
    const show_editor_cursor = show_cursor and wb.focused_panel == .editor and pane_focused;
    const bracket_pair = if (show_editor_cursor and !wb.agent_ui.session.worker_running) blk: {
        const hash = std.hash.CityHash64.hash(file_path);
        if (wb.bracket_match_cache.file_path_hash == hash and
            wb.bracket_match_cache.revision == editor_buf.revision and
            wb.bracket_match_cache.row == editor_buf.cursor.row and
            wb.bracket_match_cache.col == editor_buf.cursor.col)
        {
            break :blk wb.bracket_match_cache.match;
        }
        const match = bracket_match.findMatch(editor_buf, editor_buf.cursor.row, editor_buf.cursor.col);
        wb.bracket_match_cache = .{
            .file_path_hash = hash,
            .revision = editor_buf.revision,
            .row = editor_buf.cursor.row,
            .col = editor_buf.cursor.col,
            .match = match,
        };
        break :blk match;
    } else null;

    var wrap_cache_opt: ?*word_wrap.WrapCache = null;
    if (wrap_enabled) {
        const hash = std.hash.CityHash64.hash(file_path);
        if (wb.wrap_cache.get(hash)) |c| {
            wrap_cache_opt = c;
        } else {
            const c = word_wrap.WrapCache.init(wb.allocator);
            wb.wrap_cache.put(hash, c) catch unreachable;
            wrap_cache_opt = c;
        }
    }

    const line_count = editor_buf.lineCount();
    const content_h = if (wrap_enabled)
        wrap_cache_opt.?.cachedContentHeight(editor_buf, viewport_w, font_size, theme)
    else
        editor_scroll.contentHeight(line_count, theme);
    const max_scroll_y = if (wrap_enabled)
        wrap_cache_opt.?.cachedMaxScrollY(editor_buf, editor_h, viewport_w, font_size, theme)
    else
        editor_scroll.maxScrollY(line_count, editor_h, theme);
    const max_line_len = if (wrap_enabled) 0 else blk: {
        const hash = std.hash.CityHash64.hash(file_path);
        if (wb.max_line_len_cache.get(hash)) |entry| {
            if (entry.revision == editor_buf.revision) {
                break :blk entry.len;
            }
        }
        const len = editor_scroll.longestLineLen(editor_buf);
        wb.max_line_len_cache.put(hash, .{ .revision = editor_buf.revision, .len = len }) catch {};
        break :blk len;
    };
    const content_w = @as(f32, @floatFromInt(max_line_len)) * editor_scroll.charWidth(theme);
    const max_scroll_x = if (wrap_enabled) @as(f32, 0) else editor_scroll.maxScrollX(content_w, editor_w, theme);

    const show_diags = blk: {
        if (wb.lsp.diagnostics.active_path) |active_path| {
            break :blk std.mem.eql(u8, active_path, file_path);
        }
        break :blk false;
    };

    const diag_store = @import("../../../workbench/diagnostics_store.zig");
    const semantic_tokens_for_file = blk: {
        if (wb.lsp.sync.entries.get(file_path)) |entry| {
            break :blk entry.semantic_tokens;
        }
        break :blk null;
    };

    const resolved_hunks = blk: {
        const hash = std.hash.CityHash64.hash(file_path);
        if (wb.review_hunks_cache.file_path_hash == hash and
            wb.review_hunks_cache.buf_revision == editor_buf.revision and
            wb.review_hunks_cache.review_revision == wb.agent_ui.session.review.revision)
        {
            break :blk wb.review_hunks_cache.hunks;
        }
        const hunks = review_overlay.resolveHunks(wb, editor_buf, file_path);
        wb.review_hunks_cache = .{
            .file_path_hash = hash,
            .buf_revision = editor_buf.revision,
            .review_revision = wb.agent_ui.session.review.revision,
            .hunks = hunks,
        };
        break :blk wb.review_hunks_cache.hunks;
    };

    const conflict_blocks = blk: {
        const hash = std.hash.CityHash64.hash(file_path);
        if (wb.conflict_blocks_cache.file_path_hash == hash and
            wb.conflict_blocks_cache.buf_revision == editor_buf.revision)
        {
            break :blk wb.conflict_blocks_cache.blocks.items;
        }

        conflict_resolver.findConflicts(wb.allocator, editor_buf, &wb.conflict_blocks_cache.blocks) catch {};
        wb.conflict_blocks_cache.file_path_hash = hash;
        wb.conflict_blocks_cache.buf_revision = editor_buf.revision;
        break :blk wb.conflict_blocks_cache.blocks.items;
    };

    var ghost_newlines: f32 = 0;
    var ghost_row: ?usize = null;
    wb.editor.ghost.mutex.lock();
    if (wb.editor.ghost.ghost_text) |gt| {
        if (wb.editor.ghost.trigger_row == editor_buf.cursor.row and wb.editor.ghost.trigger_col == editor_buf.cursor.col) {
            ghost_row = editor_buf.cursor.row;
            for (gt) |c| {
                if (c == '\n') {
                    ghost_newlines += 1.0;
                }
            }
        }
    }
    wb.editor.ghost.mutex.unlock();

    const safe_margin: f32 = 2000;
    var start_idx: usize = 0;
    if (scroll_y > safe_margin) {
        start_idx = @intFromFloat((scroll_y - safe_margin) / line_h);
    }

    var line_num_y = editor_scroll.firstLineY(theme) - scroll_y + @as(f32, @floatFromInt(start_idx)) * line_h;
    const initial_line_num_y = line_num_y;

    if (wrap_enabled) {
        const visual_count = wrap_cache_opt.?.cachedTotalVisualLines(editor_buf, viewport_w, font_size);
        const cursor_visual = wrap_cache_opt.?.cachedVisualIndexForCursor(editor_buf, editor_buf.cursor.row, editor_buf.cursor.col, viewport_w, font_size);
        if (cursor_visual < start_idx) line_num_y += ghost_newlines * line_h;
        for (start_idx..visual_count) |visual_idx| {
            if (line_num_y > content_top + editor_view_h) break;
            if (line_num_y + line_h >= content_top and line_num_y < content_top + editor_view_h) {
                const seg = wrap_cache_opt.?.cachedSegmentAt(editor_buf, visual_idx, viewport_w, font_size);
                if (seg.start_col == 0) {
                    if (wb.debug.breakpoints.hasAt(file_path, seg.buf_line)) {
                        renderer.Renderer.drawRoundedRect(editor_x + 4, line_num_y + 4, 8, 8, 4, syntax.color(theme.colors.warning));
                    }
                    const debug_here = blk: {
                        if (wb.debug.stop_path) |stop_path| {
                            if (wb.debug.stop_line) |stop_line| {
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
                        if (diag_store.worstSeverityOnLine(wb.lsp.diagnostics.list, seg.buf_line)) |severity| {
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
        if (ghost_row != null and ghost_row.? < start_idx) line_num_y += ghost_newlines * line_h;
        for (start_idx..line_count) |idx| {
            if (line_num_y > content_top + editor_view_h) break;
            if (line_num_y + line_h >= content_top and line_num_y < content_top + editor_view_h) {
                if (wb.debug.breakpoints.hasAt(file_path, idx)) {
                    renderer.Renderer.drawRoundedRect(editor_x + 4, line_num_y + 4, 8, 8, 4, syntax.color(theme.colors.warning));
                }
                const debug_here = blk: {
                    if (wb.debug.stop_path) |stop_path| {
                        if (wb.debug.stop_line) |stop_line| {
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
                    if (diag_store.worstSeverityOnLine(wb.lsp.diagnostics.list, idx)) |severity| {
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
                if (review_overlay.reviewLineHasChange(resolved_hunks.slice(), idx)) {
                    renderer.Renderer.drawText("±", editor_x + gutter - 14, line_num_y, font_size, .{ .r = 0.55, .g = 0.85, .b = 0.95, .a = 1.0 });
                }
            }
            line_num_y += line_h;
        }
    }

    renderer.Renderer.setClipRect(editor_x + gutter, content_top, editor_w - gutter, editor_view_h);
    line_num_y = initial_line_num_y;

    if (wrap_enabled) {
        const visual_count = wrap_cache_opt.?.cachedTotalVisualLines(editor_buf, viewport_w, font_size);
        const cursor_visual = wrap_cache_opt.?.cachedVisualIndexForCursor(editor_buf, editor_buf.cursor.row, editor_buf.cursor.col, viewport_w, font_size);
        if (cursor_visual < start_idx) line_num_y += ghost_newlines * line_h;
        for (start_idx..visual_count) |visual_idx| {
            if (line_num_y > content_top + editor_view_h) break;
            if (line_num_y + line_h >= content_top and line_num_y < content_top + editor_view_h) {
                const seg = wrap_cache_opt.?.cachedSegmentAt(editor_buf, visual_idx, viewport_w, font_size);
                const slice = editor_buf.lineAt(seg.buf_line)[seg.start_col..seg.end_col];
                const seg_text_x = text_x + editor_scroll.cursorX(editor_buf.lineAt(seg.buf_line), seg.start_col, font_size);

                const debug_here = blk: {
                    if (wb.debug.stop_path) |stop_path| {
                        if (wb.debug.stop_line) |stop_line| {
                            break :blk std.mem.eql(u8, stop_path, file_path) and stop_line == seg.buf_line and seg.start_col == 0;
                        }
                    }
                    break :blk false;
                };
                if (debug_here) {
                    renderer.Renderer.drawRect(seg_text_x - 4, line_num_y, viewport_w, line_h, .{ .r = 0.2, .g = 0.45, .b = 0.75, .a = 0.18 });
                }

                if (std.mem.startsWith(u8, file_path, "git-diff://")) {
                    const full_line = editor_buf.lineAt(seg.buf_line);
                    if (full_line.len > 0) {
                        const bg_w = @max(viewport_w, content_w + 8);
                        if (full_line[0] == '+') {
                            renderer.Renderer.drawRect(seg_text_x - 4, line_num_y, bg_w, line_h, .{ .r = 0.2, .g = 0.8, .b = 0.2, .a = 0.15 });
                        } else if (full_line[0] == '-') {
                            renderer.Renderer.drawRect(seg_text_x - 4, line_num_y, bg_w, line_h, .{ .r = 0.8, .g = 0.2, .b = 0.2, .a = 0.15 });
                        } else if (std.mem.startsWith(u8, full_line, "@@")) {
                            renderer.Renderer.drawRect(seg_text_x - 4, line_num_y, bg_w, line_h, .{ .r = 0.2, .g = 0.4, .b = 0.8, .a = 0.15 });
                        }
                    }
                }

                decorations.drawDecorations(editor_buf, seg.buf_line, seg_text_x, line_num_y, line_h, viewport_w);
                bracket.drawSelectionInSegment(editor_buf, seg.buf_line, seg.start_col, seg.end_col, seg_text_x, line_num_y, line_h, font_size, .{ .r = 0.35, .g = 0.55, .b = 0.95, .a = 0.35 });
                review_overlay.drawReviewLineOverlay(resolved_hunks.slice(), theme, editor_buf, seg.buf_line, seg_text_x, line_num_y, line_h, font_size);
                overlays.drawFindHighlights(wb, editor_buf, seg.buf_line, seg_text_x, line_num_y, line_h, font_size);

                syntax.drawHighlightedLine(file_path, slice, seg.buf_line, seg.start_col, seg_text_x, line_num_y, theme, semantic_tokens_for_file);

                // P0-6: Inlay hints.
                const hints_for_file = wb.editor.inlay_hints.get(file_path);
                inlay_hints_render.drawLineHints(hints_for_file, seg.buf_line, slice, seg_text_x, line_num_y, font_size, theme);

                if (bracket_pair) |pair| {
                    bracket.drawBracketHighlight(editor_buf, pair, seg.buf_line, seg.start_col, seg.end_col, seg_text_x, line_num_y, line_h, font_size, theme);
                }
                if (show_diags) {
                    const start_idx_diag = diag_store.firstForLine(wb.lsp.diagnostics.list, seg.buf_line);
                    for (wb.lsp.diagnostics.list.items[start_idx_diag..]) |diag| {
                        if (diag.line != seg.buf_line) break;
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
                for (conflict_blocks) |block| {
                    if (block.start_row == seg.buf_line and seg.start_col == 0) {
                        conflict_resolver.drawInlineActions(wb, block, editor_x, gutter, line_num_y, state.last_mouse_x, state.last_mouse_y);
                    }
                }

                if (visual_idx == cursor_visual) {
                    const line = editor_buf.lineAt(seg.buf_line);
                    const cursor_x = text_x + editor_scroll.cursorX(line, editor_buf.cursor.col, font_size);
                    if (show_editor_cursor) {
                        renderer.Renderer.drawText("|", cursor_x, line_num_y, font_size, syntax.color(theme.colors.cursor));
                    }
                    wb.editor.ghost.mutex.lock();
                    if (wb.editor.ghost.ghost_text) |gt| {
                        if (wb.editor.ghost.trigger_row == editor_buf.cursor.row and wb.editor.ghost.trigger_col == editor_buf.cursor.col) {
                            var ghost_y = line_num_y;
                            var it = std.mem.splitScalar(u8, gt, '\n');
                            var is_first = true;
                            while (it.next()) |gline| {
                                if (is_first) {
                                    renderer.Renderer.drawText(gline, cursor_x, ghost_y, font_size, syntax.color(theme.colors.text_muted));
                                    is_first = false;
                                } else {
                                    ghost_y += line_h;
                                    renderer.Renderer.drawText(gline, text_x + editor_scroll.cursorX(line, 0, font_size), ghost_y, font_size, syntax.color(theme.colors.text_muted));
                                }
                            }
                        }
                    }
                    wb.editor.ghost.mutex.unlock();
                }
            }
            if (visual_idx == cursor_visual) {
                wb.editor.ghost.mutex.lock();
                if (wb.editor.ghost.ghost_text) |gt| {
                    if (wb.editor.ghost.trigger_row == editor_buf.cursor.row and wb.editor.ghost.trigger_col == editor_buf.cursor.col) {
                        var newlines: f32 = 0;
                        for (gt) |c| {
                            if (c == '\n') newlines += 1.0;
                        }
                        line_num_y += newlines * line_h;
                    }
                }
                wb.editor.ghost.mutex.unlock();
            }
            line_num_y += line_h;
        }
    } else {
        if (ghost_row != null and ghost_row.? < start_idx) line_num_y += ghost_newlines * line_h;
        for (start_idx..line_count) |idx| {
            // P0-4: Skip lines hidden by code folding.
            if (wb.editor.fold_controller.isLineHidden(@intCast(idx))) {
                continue;
            }
            if (line_num_y > content_top + editor_view_h) break;
            if (line_num_y + line_h >= content_top and line_num_y < content_top + editor_view_h) {
                const debug_here = blk: {
                    if (wb.debug.stop_path) |stop_path| {
                        if (wb.debug.stop_line) |stop_line| {
                            break :blk std.mem.eql(u8, stop_path, file_path) and stop_line == idx;
                        }
                    }
                    break :blk false;
                };
                if (debug_here) {
                    renderer.Renderer.drawRect(text_x - 4, line_num_y, content_w + 8, line_h, .{ .r = 0.2, .g = 0.45, .b = 0.75, .a = 0.18 });
                }

                if (std.mem.startsWith(u8, file_path, "git-diff://")) {
                    const full_line = editor_buf.lineAt(idx);
                    if (full_line.len > 0) {
                        const bg_w = @max(viewport_w, content_w + 8);
                        if (full_line[0] == '+') {
                            renderer.Renderer.drawRect(text_x - 4, line_num_y, bg_w, line_h, .{ .r = 0.2, .g = 0.8, .b = 0.2, .a = 0.15 });
                        } else if (full_line[0] == '-') {
                            renderer.Renderer.drawRect(text_x - 4, line_num_y, bg_w, line_h, .{ .r = 0.8, .g = 0.2, .b = 0.2, .a = 0.15 });
                        } else if (std.mem.startsWith(u8, full_line, "@@")) {
                            renderer.Renderer.drawRect(text_x - 4, line_num_y, bg_w, line_h, .{ .r = 0.2, .g = 0.4, .b = 0.8, .a = 0.15 });
                        }
                    }
                }

                decorations.drawDecorations(editor_buf, idx, text_x, line_num_y, line_h, content_w);
                bracket.drawSelectionInSegment(editor_buf, idx, 0, editor_buf.lineAt(idx).len, text_x, line_num_y, line_h, font_size, .{ .r = 0.35, .g = 0.55, .b = 0.95, .a = 0.35 });
                review_overlay.drawReviewLineOverlay(resolved_hunks.slice(), theme, editor_buf, idx, text_x, line_num_y, line_h, font_size);
                overlays.drawFindHighlights(wb, editor_buf, idx, text_x, line_num_y, line_h, font_size);

                syntax.drawHighlightedLine(file_path, editor_buf.lineAt(idx), idx, 0, text_x, line_num_y, theme, semantic_tokens_for_file);

                // P0-6: Inlay hints.
                const hints_for_file = wb.editor.inlay_hints.get(file_path);
                inlay_hints_render.drawLineHints(hints_for_file, idx, editor_buf.lineAt(idx), text_x, line_num_y, font_size, theme);

                if (bracket_pair) |pair| {
                    bracket.drawBracketHighlight(editor_buf, pair, idx, 0, editor_buf.lineAt(idx).len, text_x, line_num_y, line_h, font_size, theme);
                }
                if (show_diags) {
                    const start_idx_diag = diag_store.firstForLine(wb.lsp.diagnostics.list, idx);
                    for (wb.lsp.diagnostics.list.items[start_idx_diag..]) |diag| {
                        if (diag.line != idx) break;
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
                if (idx == editor_buf.cursor.row) {
                    const line = editor_buf.lineAt(idx);
                    const cursor_x = text_x + editor_scroll.cursorX(line, editor_buf.cursor.col, font_size);
                    if (wb.ime_text) |ime_text| {
                        renderer.Renderer.drawText(ime_text, cursor_x, line_num_y, font_size, syntax.color(theme.colors.text_primary));
                        const ime_w = renderer.Renderer.measureText(ime_text, font_size);
                        renderer.Renderer.drawRect(cursor_x, line_num_y + line_h - 2, ime_w, 2, syntax.color(theme.colors.text_primary));
                        if (wb.ime_cursor >= 0 and wb.ime_cursor <= ime_text.len) {
                            const sub_w = renderer.Renderer.measureText(ime_text[0..@intCast(wb.ime_cursor)], font_size);
                            renderer.Renderer.drawText("|", cursor_x + sub_w, line_num_y, font_size, syntax.color(theme.colors.cursor));
                            renderer.Renderer.setImeCursorRect(cursor_x + sub_w, line_num_y, 0, line_h);
                        } else {
                            renderer.Renderer.setImeCursorRect(cursor_x, line_num_y, ime_w, line_h);
                        }
                    } else if (show_editor_cursor) {
                        renderer.Renderer.drawText("|", cursor_x, line_num_y, font_size, syntax.color(theme.colors.cursor));
                        renderer.Renderer.setImeCursorRect(cursor_x, line_num_y, 0, line_h);
                    }
                    wb.editor.ghost.mutex.lock();
                    if (wb.editor.ghost.ghost_text) |gt| {
                        if (wb.editor.ghost.trigger_row == editor_buf.cursor.row and wb.editor.ghost.trigger_col == editor_buf.cursor.col) {
                            var ghost_y = line_num_y;
                            var it = std.mem.splitScalar(u8, gt, '\n');
                            var is_first = true;
                            while (it.next()) |gline| {
                                if (is_first) {
                                    renderer.Renderer.drawText(gline, cursor_x, ghost_y, font_size, syntax.color(theme.colors.text_muted));
                                    is_first = false;
                                } else {
                                    ghost_y += line_h;
                                    renderer.Renderer.drawText(gline, text_x + editor_scroll.cursorX(line, 0, font_size), ghost_y, font_size, syntax.color(theme.colors.text_muted));
                                }
                            }
                        }
                    }
                    wb.editor.ghost.mutex.unlock();
                }
            }
            if (idx == editor_buf.cursor.row) {
                wb.editor.ghost.mutex.lock();
                if (wb.editor.ghost.ghost_text) |gt| {
                    if (wb.editor.ghost.trigger_row == editor_buf.cursor.row and wb.editor.ghost.trigger_col == editor_buf.cursor.col) {
                        var newlines: f32 = 0;
                        for (gt) |c| {
                            if (c == '\n') newlines += 1.0;
                        }
                        line_num_y += newlines * line_h;
                    }
                }
                wb.editor.ghost.mutex.unlock();
            }
            line_num_y += line_h;
        }
    }

    renderer.Renderer.setClipRect(editor_x, content_top, editor_w, editor_view_h);
    const show_editor_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, editor_x, content_top, editor_w, editor_view_h);
    scrollbar.drawVertical(
        editor_x + editor_w - scrollbar.track_w - 4,
        content_top,
        editor_view_h,
        scroll_y,
        max_scroll_y,
        content_h,
        editor_view_h,
        show_editor_scroll,
    );
    scrollbar.drawHorizontal(
        editor_x + gutter,
        content_top + editor_view_h - scrollbar.track_w - 2,
        viewport_w,
        scroll_x,
        max_scroll_x,
        content_w,
        viewport_w,
        show_editor_scroll,
    );
    renderer.Renderer.clearClipRect();
}

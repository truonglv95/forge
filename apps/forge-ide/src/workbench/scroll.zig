const std = @import("std");
const plugin = @import("forge-plugin");
const renderer = @import("forge-renderer");
const terminal_group_mod = @import("terminal_group.zig");

pub fn clampProposalReviewScroll(wb: anytype, editor_h: f32) void {
    if (!wb.proposal_review_open) return;
    wb.agent_ui.session.lock();
    const hunks = wb.agent_ui.session.review.hunks;
    const file_index = wb.proposal_review_file_index;
    wb.agent_ui.session.unlock();
    const panel = @import("../ui/editor/proposal_review_panel.zig");
    var files = panel.collectFiles(wb.allocator, hunks) catch return;
    defer files.deinit(wb.allocator);
    wb.proposal_review_scroll_y = panel.clampScrollY(
        wb.proposal_review_scroll_y,
        editor_h,
        hunks,
        file_index,
        files.items,
    );
}

pub fn clampPromptScroll(wb: anytype, agent_w: f32) void {
    const ac = @import("../ui/agent/agent_composer.zig");
    const visual_lines = ac.visualLineCount(&wb.agent_ui.prompt_buffer, agent_w);
    const input_h = wb.composerInputHeight(agent_w);
    wb.prompt_scroll_y = ac.clampPromptScroll(wb.prompt_scroll_y, visual_lines, input_h);
}

pub fn clampEditorScroll(wb: anytype, editor_w: f32, editor_h: f32) void {
    const scroll = @import("../ui/editor/editor_scroll.zig");
    const word_wrap = @import("../ui/editor/word_wrap.zig");
    const pane_w = wb.paneWidth(editor_w);
    const viewport_w = scroll.viewportWidth(pane_w, &wb.theme);
    const wrap = wb.user_settings.word_wrap;

    if (wb.docForPane(.primary)) |doc| {
        if (wrap) {
            wb.editor_scroll_y = std.math.clamp(
                wb.editor_scroll_y,
                0,
                word_wrap.maxScrollY(&doc.buffer, editor_h, viewport_w, wb.theme.editor_font_size, &wb.theme),
            );
            wb.editor_scroll_x = 0;
        } else {
            const max_line_len = blk: {
                const hash = std.hash.CityHash64.hash(doc.path);
                if (wb.max_line_len_cache.get(hash)) |entry| {
                    if (entry.revision == doc.buffer.revision) break :blk entry.len;
                }
                const len = scroll.longestLineLen(&doc.buffer);
                wb.max_line_len_cache.put(hash, .{ .revision = doc.buffer.revision, .len = len }) catch {};
                break :blk len;
            };
            const content_w = @as(f32, @floatFromInt(max_line_len)) * scroll.charWidth(&wb.theme);
            wb.editor_scroll_y = scroll.clampScrollY(wb.editor_scroll_y, doc.buffer.lineCount(), editor_h, &wb.theme);
            wb.editor_scroll_x = scroll.clampScrollX(wb.editor_scroll_x, content_w, pane_w, &wb.theme);
        }
    } else {
        wb.editor_scroll_y = 0;
        wb.editor_scroll_x = 0;
    }
    if (wb.editor_split) {
        if (wb.docForPane(.secondary)) |doc| {
            if (wrap) {
                wb.split_scroll_y = std.math.clamp(
                    wb.split_scroll_y,
                    0,
                    word_wrap.maxScrollY(&doc.buffer, editor_h, viewport_w, wb.theme.editor_font_size, &wb.theme),
                );
                wb.split_scroll_x = 0;
            } else {
                const max_line_len = blk: {
                    const hash = std.hash.CityHash64.hash(doc.path);
                    if (wb.max_line_len_cache.get(hash)) |entry| {
                        if (entry.revision == doc.buffer.revision) break :blk entry.len;
                    }
                    const len = scroll.longestLineLen(&doc.buffer);
                    wb.max_line_len_cache.put(hash, .{ .revision = doc.buffer.revision, .len = len }) catch {};
                    break :blk len;
                };
                const content_w = @as(f32, @floatFromInt(max_line_len)) * scroll.charWidth(&wb.theme);
                wb.split_scroll_y = scroll.clampScrollY(wb.split_scroll_y, doc.buffer.lineCount(), editor_h, &wb.theme);
                wb.split_scroll_x = scroll.clampScrollX(wb.split_scroll_x, content_w, pane_w, &wb.theme);
            }
        } else {
            wb.split_scroll_y = 0;
            wb.split_scroll_x = 0;
        }
    }
}

pub fn clampExplorerScroll(wb: anytype, window_h: f32) void {
    const scroll = @import("../ui/sidebar/explorer_scroll.zig");
    wb.explorer_scroll_y = scroll.clampScrollY(
        wb.explorer_scroll_y,
        wb.explorer.entries.len,
        window_h,
    );
}

pub fn clampExtensionsScroll(wb: anytype, window_h: f32) void {
    const scroll = @import("../ui/sidebar/extensions_panel.zig");
    const catalog_ptr: ?*const plugin.MarketplaceCatalog = if (wb.marketplace_catalog) |*catalog| catalog else null;
    wb.extensions_scroll_y = scroll.clampScrollY(
        wb.extensions_scroll_y,
        &wb.extension_host,
        catalog_ptr,
        wb.extensions_panel_mode,
        window_h,
        wb.extensionsFilterSlice(),
        wb.extensions_detail_index,
    );
}

pub fn clampSearchScroll(wb: anytype, window_h: f32) void {
    const scroll = @import("../ui/sidebar/search_panel.zig");
    const count = if (wb.search.results) |results| results.matches.len else 0;
    wb.search.scroll_y = scroll.clampScrollY(wb.search.scroll_y, count, window_h);
}

pub fn clampGitScroll(wb: anytype, window_h: f32) void {
    const scroll = @import("../ui/sidebar/git_panel.zig");
    wb.git.scroll_y = scroll.clampScrollY(wb.git.scroll_y, wb, window_h);
}

pub fn clampRunScroll(wb: anytype, window_h: f32) void {
    const scroll = @import("../ui/sidebar/debug_panel.zig");
    const debug_active = wb.debug.lldb.isActive();
    wb.run_scroll_y = scroll.clampScrollY(wb.run_scroll_y, wb.debug.breakpoints.items.items.len, window_h, debug_active);
}

pub fn clampBottomPanelScroll(wb: anytype, panel_h: f32) void {
    const panel_scroll = @import("../ui/core/panel_scroll.zig");
    const line_h = if (wb.bottom_panel_mode == .terminal)
        @import("../ui/panel/terminal_panel.zig").line_h
    else
        panel_scroll.bottom_line_h;
    const viewport = if (wb.bottom_panel_mode == .terminal)
        @max(0, panel_h - @import("../ui/panel/terminal_panel.zig").contentTop(0))
    else
        panel_scroll.bottomViewportHeight(panel_h);
    wb.task_scroll_y = panel_scroll.clampScrollY(
        wb.task_scroll_y,
        wb.bottomPanelLineCount(),
        viewport,
        line_h,
    );
}

pub fn clampChatScroll(wb: anytype, agent_h: f32) void {
    wb.chat_follow_stream = false;
    @import("chat_layout.zig").ensure(wb, agent_h);
    wb.chat_scroll_y = std.math.clamp(wb.chat_scroll_y, 0, wb.chat_layout.max_scroll);
}

pub fn clampReviewScroll(wb: anytype, agent_h: f32) void {
    const panel_scroll = @import("../ui/core/panel_scroll.zig");
    const layout_mod = @import("../ui/core/layout.zig");
    const agent_panel_mod = @import("../ui/agent/agent_panel.zig");
    wb.agent_ui.session.lock();
    const content_h = agent_panel_mod.reviewContentHeight(&wb.agent_ui.session);
    wb.agent_ui.session.unlock();
    const viewport = @max(0, agent_h - layout_mod.status_height - 200);
    wb.agent_ui.session.review_scroll_y = panel_scroll.clampScrollY(
        wb.agent_ui.session.review_scroll_y,
        @intFromFloat(content_h),
        viewport,
        1.0,
    );
}

pub fn clampTabScroll(wb: anytype, editor_w: f32) void {
    const visible_w = @max(10, editor_w - 60);
    wb.tab_scroll_x = @import("../ui/editor/tabs.zig").clampScroll(wb.tab_scroll_x, wb, visible_w);
}

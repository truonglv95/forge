const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("state.zig");
const layout = @import("layout.zig");
const editor_scroll = @import("editor_scroll.zig");
const activity_bar = @import("activity_bar.zig");
const sidebar_view = @import("sidebar_view.zig");
const extensions_panel = @import("extensions_panel.zig");
const context_inspector = @import("context_inspector.zig");
const chat_bubble = @import("chat_bubble.zig");
const tool_step_card = @import("tool_step_card.zig");
const agent_composer = @import("agent_composer.zig");
const search_panel = @import("search_panel.zig");
const debug_panel = @import("debug_panel.zig");
const git_panel = @import("git_panel.zig");
const ai_settings_panel = @import("ai_settings_panel.zig");
const header_toolbar = @import("header_toolbar.zig");
const explorer_scroll = @import("explorer_scroll.zig");
const tabs_ui = @import("tabs.zig");
const theme_loader = @import("../theme_loader.zig");
const bracket_match = @import("bracket_match.zig");
const word_wrap = @import("word_wrap.zig");
const scrollbar = @import("scrollbar.zig");
const panel_scroll = @import("panel_scroll.zig");
const agent_panel = @import("agent_panel.zig");
const plugin = @import("forge-plugin");
const ai = @import("forge-ai");
const agent_scope_picker_mod = @import("../agent/scope_picker.zig");

fn c(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return theme_loader.toColor(rgba);
}

fn drawSidebarScrollbar(
    panel_x: f32,
    panel_w: f32,
    list_top: f32,
    window_h: f32,
    scroll_y: f32,
    row_count: usize,
    row_h: f32,
) void {
    const metrics = scrollbar.sidebarMetrics(row_count, row_h, list_top, window_h, layout.status_height);
    const show = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, list_top, panel_w, metrics.viewport_h);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        list_top,
        metrics.viewport_h,
        scroll_y,
        metrics.max_scroll,
        metrics.content_h,
        metrics.viewport_h,
        show,
    );
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

fn drawConflictDialog(wb: *@import("../workbench.zig").Workbench, w: f32, h: f32) void {
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const box_w: f32 = 520;
    const box_h: f32 = 180;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 2;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 10, .{ .r = 0.18, .g = 0.14, .b = 0.12, .a = 1.0 });
    renderer.Renderer.drawText("External file change", box_x + 20, box_y + 16, 16.0, .{ .r = 1.0, .g = 0.85, .b = 0.55, .a = 1.0 });

    var path_buf: [384:0]u8 = undefined;
    const path = wb.conflict_path orelse "active file";
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&path_buf), box_x + 20, box_y + 46, 13.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    renderer.Renderer.drawText("Enter: reload from disk    Esc: keep local edits", box_x + 20, box_y + 78, 12.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
}

fn drawRecoveryDialog(wb: *@import("../workbench.zig").Workbench, w: f32, h: f32) void {
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const box_w: f32 = 520;
    const box_h: f32 = 180;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 2;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 10, .{ .r = 0.12, .g = 0.18, .b = 0.22, .a = 1.0 });
    renderer.Renderer.drawText("Recover unsaved work?", box_x + 20, box_y + 16, 16.0, .{ .r = 0.55, .g = 0.85, .b = 1.0, .a = 1.0 });

    var count_buf: [64:0]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&count_buf, "{d} recovery snapshot(s) found in .forge/recovery/", .{wb.recovery_count}) catch "";
    count_buf[count_msg.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&count_buf), box_x + 20, box_y + 50, 13.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    renderer.Renderer.drawText("Enter: restore    Esc: discard", box_x + 20, box_y + 82, 12.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
}

fn drawPalette(wb: *@import("../workbench.zig").Workbench, w: f32, h: f32) void {
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const box_w: f32 = 560;
    const box_h: f32 = 360;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 3;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 10, .{ .r = 0.16, .g = 0.16, .b = 0.18, .a = 1.0 });
    renderer.Renderer.drawText("Command Palette", box_x + 16, box_y + 12, 14.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });

    var query_buf: [320:0]u8 = undefined;
    @memcpy(query_buf[0..wb.palette.query_len], wb.palette.querySlice());
    query_buf[wb.palette.query_len] = 0;
    renderer.Renderer.drawRoundedRect(box_x + 12, box_y + 36, box_w - 24, 28, 6, .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 });
    renderer.Renderer.drawText(@ptrCast(&query_buf), box_x + 20, box_y + 42, 14.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    var row_y = box_y + 76;
    const max_rows: usize = 10;
    const show_rows = @min(wb.palette.filtered.len, max_rows);
    for (0..show_rows) |visible_index| {
        const entry_index = wb.palette.filtered[visible_index];
        const entry = wb.palette.entries[entry_index];
        const selected = visible_index == wb.palette.selected;
        if (selected) {
            renderer.Renderer.drawRoundedRect(box_x + 10, row_y - 2, box_w - 20, 22, 4, .{ .r = 0.22, .g = 0.35, .b = 0.55, .a = 1.0 });
        }
        var line_buf: [384:0]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}    {s}", .{ entry.category, entry.title }) catch entry.title;
        line_buf[line.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&line_buf), box_x + 18, row_y, 13.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
        row_y += 24;
    }
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "pub", "fn", "const", "var", "struct", "enum", "union", "return", "try", "catch", "if", "else", "switch", "while", "for", "break", "continue", "defer", "errdefer" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

pub fn onRenderFrame() void {
    const wb = state.wb orelse return;
    const editor_buf = wb.activeBuffer();
    const theme = &wb.theme;

    state.time += 0.016;
    wb.tickFrame(0.016) catch {};
    theme_loader.applyShellColors(theme.*);

    renderer.Renderer.clearClipRect();

    var w: f32 = 0;
    var h: f32 = 0;
    renderer.Renderer.getWindowSize(&w, &h);

    const geo = wb.layoutGeometry(w, h);
    wb.clampEditorScroll(geo.editor_w, geo.editor_h);
    wb.clampTabScroll(geo.editor_w);
    wb.clampExplorerScroll(h);
    wb.clampExtensionsScroll(h);
    wb.clampSearchScroll(h);
    wb.clampGitScroll(h);
    wb.clampRunScroll(h);
    if (wb.ai_settings_open) wb.clampAiSettingsScroll(geo.editor_h);
    const side_h = geo.content_h;

    if (state.root_view) |rv| {
        rv.frame = .{ .x = 0, .y = 0, .w = w, .h = h };
        if (state.header_view) |v| v.frame = .{ .x = 0, .y = 0, .w = w, .h = layout.header_height };
        if (state.activity_view) |v| v.frame = .{ .x = 0, .y = layout.header_height, .w = geo.explorer_w, .h = layout.activity_bar_height };
        if (state.explorer_view) |v| v.frame = .{ .x = geo.explorer_x, .y = layout.header_height + layout.activity_bar_height, .w = geo.explorer_w, .h = side_h - layout.activity_bar_height };
        if (state.editor_view) |v| v.frame = .{ .x = geo.editor_x, .y = layout.header_height, .w = geo.editor_w, .h = geo.editor_h };
        if (state.panel_view) |v| v.frame = .{ .x = geo.editor_x, .y = geo.task_panel_y, .w = geo.editor_w, .h = geo.task_panel_h };
        if (state.border_view) |v| v.frame = .{ .x = geo.editor_x, .y = geo.task_panel_y, .w = geo.editor_w, .h = 1 };
        if (state.agent_view) |v| v.frame = .{ .x = geo.agent_x, .y = layout.header_height, .w = geo.agent_w, .h = side_h };
        if (state.status_view) |v| v.frame = .{ .x = 0, .y = h - layout.status_height, .w = w, .h = layout.status_height };

        rv.render();
        header_toolbar.draw(w, wb.headerToolbarState(), state.header_hover_action, c(wb.theme.colors.header_bg));

        const subtle_border = c(wb.theme.colors.border);

        if (geo.shell_mode == .ide) {
            if (wb.sidebar_visible and geo.explorer_w > 0) {
                drawActivityBar(wb, geo.explorer_w);
                renderer.Renderer.drawRect(geo.explorer_x - 1, layout.header_height, 1, side_h, subtle_border);
                renderer.Renderer.drawRect(geo.editor_x - 1, layout.header_height, 1, side_h, subtle_border);
                switch (wb.sidebar_view) {
                    .explorer => drawExplorerPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .search => drawSearchPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .git => drawGitPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .run => drawDebugPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .extensions => drawExtensionsPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .ai => ai_settings_panel.drawSidebarHint(
                        geo.explorer_x,
                        geo.explorer_w,
                        layout.header_height + layout.activity_bar_height,
                        side_h - layout.activity_bar_height,
                    ),
                }
            }
            drawEditorPanel(wb, editor_buf, geo.editor_x, geo.editor_w, geo.editor_h, w);
            if (wb.bottom_panel_visible and geo.task_panel_h > 0) {
                drawTaskPanel(wb, geo.editor_x, geo.editor_w, geo.task_panel_y, geo.task_panel_h);
            }
        }
        if (wb.agent_panel_visible and geo.agent_w > 0) {
            renderer.Renderer.drawRect(geo.agent_x - 1, layout.header_height, 1, side_h, subtle_border);
            drawAgentPanel(wb, geo.agent_x, geo.agent_w, h);
        }
        drawStatusBar(wb, w, h, geo.shell_mode);
        header_toolbar.drawHoverTooltip(w, wb.headerToolbarState(), state.header_hover_action);

        if (wb.palette.open) drawPalette(wb, w, h);
        if (wb.focused_panel == .conflict) drawConflictDialog(wb, w, h);
        if (wb.focused_panel == .recovery) drawRecoveryDialog(wb, w, h);
        if (wb.agent.scope_picker_open) drawScopePicker(wb, geo.agent_x, geo.agent_w, h);
    }
}

fn drawAgentPanel(wb: *@import("../workbench.zig").Workbench, agent_x: f32, agent_w: f32, h: f32) void {
    const pad: f32 = 20;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;
    renderer.Renderer.setClipRect(agent_x, layout.header_height, agent_w, h - layout.header_height - layout.status_height);
    defer renderer.Renderer.clearClipRect();

    var status_copy: [320]u8 = undefined;
    var provider_copy: [128]u8 = undefined;
    const snap = wb.agent.snapshot(&status_copy, &provider_copy);
    if (snap.worker_running) wb.clampChatScroll(h);

    const chat_tab_x = agent_x;
    const chat_tab_w = 120;
    const chat_tab_y = layout.header_height; // 30
    const chat_tab_h = 35; // Match editor tab_height
    const subtle_border = c(wb.theme.colors.border);

    // Fill the tab bar background for the agent header
    renderer.Renderer.drawRect(agent_x, chat_tab_y, agent_w, chat_tab_h, c(wb.theme.colors.tab_bar_bg));

    // Draw bottom border for the whole header
    renderer.Renderer.drawRect(agent_x, chat_tab_y + chat_tab_h, agent_w, 1, subtle_border);

    // Draw active tab shape for "Chat"
    renderer.Renderer.drawRect(chat_tab_x, chat_tab_y, chat_tab_w, chat_tab_h + 1, c(wb.theme.colors.editor_bg)); // +1 to cover bottom border
    renderer.Renderer.drawRect(chat_tab_x, chat_tab_y, chat_tab_w, 1, subtle_border); // top
    renderer.Renderer.drawRect(chat_tab_x, chat_tab_y, 1, chat_tab_h, subtle_border); // left
    renderer.Renderer.drawRect(chat_tab_x + chat_tab_w - 1, chat_tab_y, 1, chat_tab_h, subtle_border); // right

    var mode_buf: [64:0]u8 = undefined;
    const mode_label = std.fmt.bufPrint(&mode_buf, "Chat", .{}) catch "Chat";
    mode_buf[mode_label.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&mode_buf), chat_tab_x + 16, 44, 13.0, .{ .r = 0.82, .g = 0.84, .b = 0.9, .a = 1.0 });

    const mx = state.last_mouse_x;
    const my = state.last_mouse_y;

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    var rx = inner_x + content_w - 20;

    if (mx >= rx and mx < rx + 16 and my >= 32 and my < 52) {
        renderer.Renderer.drawRoundedRect(rx - 2, 32, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, rx - 8, 27, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= 32 and my < 52) {
        renderer.Renderer.drawRoundedRect(rx - 2, 32, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.sync, rx - 8, 27, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= 32 and my < 52) {
        renderer.Renderer.drawRoundedRect(rx - 2, 32, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.plus, rx - 8, 27, 16, 16, icon_c);

    var run_y: f32 = 60.0;
    wb.agent.lock();
    const run_count = wb.agent.run_history.items.len;
    const selected_run = wb.agent.selected_run_index;
    for (wb.agent.run_history.items, 0..) |entry, index| {
        if (index >= 3) break;
        var run_buf: [128:0]u8 = undefined;
        const run_line = std.fmt.bufPrint(&run_buf, "{s} {s}", .{ entry.run_id, entry.state }) catch entry.run_id;
        run_buf[run_line.len] = 0;
        const color = if (index == selected_run)
            renderer.Color{ .r = 1.0, .g = 1.0, .b = 0.7, .a = 1.0 }
        else
            renderer.Color{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 };
        renderer.Renderer.drawText(@ptrCast(&run_buf), inner_x, run_y, 10.0, color);
        run_y += 14.0;
    }
    wb.agent.unlock();
    _ = run_count;

    const composer_layout = agent_composer.computeLayout(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer);
    wb.clampPromptScroll(agent_w);
    const visible_entries = context_inspector.effectiveEntryCount(&wb.agent, snap.context_entry_count);
    const strip_top = context_inspector.stripTop(h, snap.context_inspector_expanded, visible_entries, snap.attachment_count, agent_w, &wb.prompt_buffer);
    const chat_bottom = strip_top - 4;

    var content_y: f32 = run_y + 8.0 - wb.chat_scroll_y;

    if (snap.show_review) {
        renderer.Renderer.drawText("REVIEW", inner_x, content_y, 11.0, .{ .r = 1.0, .g = 0.7, .b = 0.4, .a = 1.0 });
        content_y += 16.0;
        if (snap.summary) |summary| {
            var summary_buf: [384:0]u8 = undefined;
            const clipped = if (summary.len > 383) summary[0..383] else summary;
            @memcpy(summary_buf[0..clipped.len], clipped);
            summary_buf[clipped.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&summary_buf), inner_x, content_y, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            content_y += 18.0;
        }

        var review_y = content_y - wb.agent.review_scroll_y;
        renderer.Renderer.drawText("CONTEXT", inner_x, review_y, 10.0, .{ .r = 0.55, .g = 0.75, .b = 1.0, .a = 1.0 });
        review_y += 14.0;
        wb.agent.lock();
        for (wb.agent.context_lines.items) |line| {
            if (review_y > chat_bottom) break;
            var ctx_buf: [512:0]u8 = undefined;
            const clipped = if (line.len > 511) line[0..511] else line;
            @memcpy(ctx_buf[0..clipped.len], clipped);
            ctx_buf[clipped.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&ctx_buf), inner_x + 6, review_y, 9.5, .{ .r = 0.7, .g = 0.78, .b = 0.9, .a = 1.0 });
            review_y += 11.0;
        }
        review_y += 6.0;
        renderer.Renderer.drawText("CHANGES (click to toggle)", inner_x, review_y, 10.0, .{ .r = 0.55, .g = 0.75, .b = 1.0, .a = 1.0 });
        review_y += 14.0;
        for (wb.agent.review.hunks) |hunk| {
            if (review_y > chat_bottom) break;
            const block_h = @import("../agent/review_store.zig").Store.hunkBlockHeight(hunk);
            const accepted = hunk.accepted;
            const header_bg = if (accepted)
                renderer.Color{ .r = 0.14, .g = 0.22, .b = 0.16, .a = 1.0 }
            else
                renderer.Color{ .r = 0.18, .g = 0.14, .b = 0.14, .a = 1.0 };
            renderer.Renderer.drawRoundedRect(inner_x, review_y - 2, content_w - 8, block_h + 4, 4, header_bg);
            var header_buf: [384:0]u8 = undefined;
            const marker = if (accepted) "[x] " else "[ ] ";
            const header = std.fmt.bufPrint(&header_buf, "{s}{s}", .{ marker, hunk.label }) catch hunk.label;
            header_buf[header.len] = 0;
            const header_color = if (accepted)
                renderer.Color{ .r = 0.75, .g = 0.95, .b = 0.75, .a = 1.0 }
            else
                renderer.Color{ .r = 0.65, .g = 0.55, .b = 0.55, .a = 1.0 };
            renderer.Renderer.drawText(@ptrCast(&header_buf), inner_x + 6, review_y, 10.0, header_color);
            var line_y = review_y + 14.0;
            for (hunk.diff_lines) |line| {
                if (line_y > chat_bottom) break;
                var line_buf: [512:0]u8 = undefined;
                const clipped = if (line.len > 511) line[0..511] else line;
                @memcpy(line_buf[0..clipped.len], clipped);
                line_buf[clipped.len] = 0;
                var color = renderer.Color{ .r = 0.75, .g = 0.75, .b = 0.75, .a = if (accepted) 1.0 else 0.45 };
                if (line.len > 0 and line[0] == '+') color = .{ .r = 0.5, .g = 0.9, .b = 0.5, .a = if (accepted) 1.0 else 0.45 };
                if (line.len > 0 and line[0] == '-') color = .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = if (accepted) 1.0 else 0.45 };
                if (line.len > 3 and std.mem.startsWith(u8, line, "---")) color = .{ .r = 0.95, .g = 0.85, .b = 0.45, .a = if (accepted) 1.0 else 0.45 };
                if (line.len > 3 and std.mem.startsWith(u8, line, "+++")) color = .{ .r = 0.55, .g = 0.85, .b = 0.95, .a = if (accepted) 1.0 else 0.45 };
                renderer.Renderer.drawText(@ptrCast(&line_buf), inner_x + 10, line_y, 9.5, color);
                line_y += 12.0;
            }
            review_y += block_h + 6.0;
        }
        wb.agent.unlock();
    } else {
        const user_style = chat_bubble.BubbleStyle{
            .bg = .{ .r = 0.2, .g = 0.2, .b = 0.25, .a = 1.0 },
            .fg = .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 },
        };
        const agent_style = chat_bubble.BubbleStyle{
            .bg = .{ .r = 0.15, .g = 0.25, .b = 0.15, .a = 1.0 },
            .fg = .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 },
        };
        for (state.chat_history.?.items) |msg| {
            const bubble_h = chat_bubble.bubbleHeight(msg.content, content_w, false);
            if (content_y + bubble_h > chat_bottom and content_y > run_y + 8) break;
            const style = if (msg.role == .user) user_style else agent_style;
            const drawn = chat_bubble.drawBubble(wb.allocator, agent_x, inner_x, content_w, content_y, null, msg.content, style);
            content_y += drawn;
        }

        if (snap.worker_running) {
            wb.agent.lock();
            defer wb.agent.unlock();

            var step_i: usize = 0;
            while (step_i < wb.agent.agent_steps.items.len) : (step_i += 1) {
                if (content_y > chat_bottom) break;
                const drawn = tool_step_card.drawStep(
                    agent_x,
                    inner_x,
                    content_w,
                    content_y,
                    wb.agent.agent_steps.items,
                    step_i,
                    wb.allocator,
                );
                if (drawn > 0) content_y += drawn;
            }

            const thinking_src = wb.agent.thinking_text.items;
            const stream_src = wb.agent.stream_text.items;

            if (thinking_src.len > 0) {
                const drawn = chat_bubble.drawBubble(
                    wb.allocator,
                    agent_x,
                    inner_x,
                    content_w,
                    content_y,
                    "Thinking",
                    thinking_src,
                    .{
                        .bg = .{ .r = 0.14, .g = 0.18, .b = 0.28, .a = 1.0 },
                        .fg = .{ .r = 0.75, .g = 0.82, .b = 0.95, .a = 1.0 },
                    },
                );
                content_y += drawn;
            } else if (stream_src.len == 0) {
                var live_buf: [256:0]u8 = undefined;
                const live_text = if (snap.status_line.len > 0)
                    std.fmt.bufPrint(&live_buf, "{s}", .{snap.status_line}) catch "Working..."
                else
                    std.fmt.bufPrint(&live_buf, "Working...", .{}) catch "Working...";
                live_buf[live_text.len] = 0;
                const drawn = chat_bubble.drawBubble(
                    wb.allocator,
                    agent_x,
                    inner_x,
                    content_w,
                    content_y,
                    null,
                    live_text,
                    .{
                        .bg = .{ .r = 0.12, .g = 0.22, .b = 0.32, .a = 1.0 },
                        .fg = .{ .r = 0.8, .g = 0.95, .b = 0.85, .a = 1.0 },
                    },
                );
                content_y += drawn;
            }

            if (stream_src.len > 0) {
                _ = chat_bubble.drawBubble(
                    wb.allocator,
                    agent_x,
                    inner_x,
                    content_w,
                    content_y,
                    if (thinking_src.len > 0) "Response" else null,
                    stream_src,
                    .{
                        .bg = .{ .r = 0.12, .g = 0.24, .b = 0.18, .a = 1.0 },
                        .fg = .{ .r = 0.85, .g = 0.95, .b = 0.88, .a = 1.0 },
                    },
                );
            }
        }
    }

    if (snap.show_review) {
        wb.agent.lock();
        const review_content = agent_panel.reviewContentHeight(&wb.agent);
        wb.agent.unlock();
        const review_top = run_y + 8;
        const review_viewport = @max(0, chat_bottom - review_top);
        const review_max = @max(0, review_content - review_viewport);
        const show_review_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, agent_x, review_top, agent_w, review_viewport);
        scrollbar.drawVertical(
            agent_x + agent_w - scrollbar.track_w - 4,
            review_top,
            review_viewport,
            wb.agent.review_scroll_y,
            review_max,
            review_content,
            review_viewport,
            show_review_scroll,
        );
    } else {
        var chat_lines: usize = 0;
        for (state.chat_history.?.items) |msg| {
            chat_lines += chat_bubble.visualLineCount(msg.content, content_w) + 1;
        }
        if (snap.worker_running) {
            wb.agent.lock();
            chat_lines += chat_bubble.estimateLiveLines(
                wb.agent.thinking_text.items,
                wb.agent.stream_text.items,
                true,
                content_w,
            );
            const steps_h = tool_step_card.totalStepsHeight(wb.agent.agent_steps.items, content_w);
            chat_lines += @as(usize, @intFromFloat(std.math.ceil(steps_h / chat_bubble.line_h)));
            wb.agent.unlock();
        }
        const chat_top = run_y + 8;
        const chat_viewport = @max(0, chat_bottom - chat_top);
        const chat_content = @as(f32, @floatFromInt(@max(1, chat_lines))) * chat_bubble.line_h;
        const chat_max = @max(0, chat_content - chat_viewport);
        const show_chat_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, agent_x, chat_top, agent_w, chat_viewport);
        scrollbar.drawVertical(
            agent_x + agent_w - scrollbar.track_w - 4,
            chat_top,
            chat_viewport,
            wb.chat_scroll_y,
            chat_max,
            chat_content,
            chat_viewport,
            show_chat_scroll,
        );
    }

    context_inspector.draw(
        &wb.agent,
        agent_x,
        agent_w,
        h,
        snap.context_used_bytes,
        snap.context_max_bytes,
        snap.context_entry_count,
        snap.context_inspector_expanded,
        snap.attachment_count,
        &wb.prompt_buffer,
    );

    const show_prompt_cursor = @mod(state.time, 1.0) < 0.5 and wb.focused_panel == .agent and !snap.show_review and !snap.worker_running;
    agent_composer.draw(
        &wb.agent,
        composer_layout,
        wb.ai_model,
        &wb.prompt_buffer,
        wb.prompt_scroll_y,
        show_prompt_cursor,
        snap.worker_running,
        snap.show_review,
    );

    if (snap.show_review) {
        wb.agent.lock();
        const show_rollback = wb.agent.last_checkpoint_id != null;
        const show_approve_spec = wb.agent.spec_pending;
        const accepted = wb.agent.review.acceptedCount();
        const total = wb.agent.review.hunks.len;
        wb.agent.unlock();
        const agent_actions = @import("agent_panel.zig").reviewActions(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer, show_rollback, show_approve_spec);
        renderer.Renderer.drawRoundedRect(agent_actions.apply.x, agent_actions.apply.y, agent_actions.apply.w, agent_actions.apply.h, 6, .{ .r = 0.2, .g = 0.55, .b = 0.35, .a = 1.0 });
        var apply_buf: [32:0]u8 = undefined;
        const apply_label = std.fmt.bufPrint(&apply_buf, "Apply ({d}/{d})", .{ accepted, total }) catch "Apply";
        apply_buf[apply_label.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&apply_buf), agent_actions.apply.x + 8, agent_actions.apply.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(agent_actions.reject.x, agent_actions.reject.y, agent_actions.reject.w, agent_actions.reject.h, 6, .{ .r = 0.45, .g = 0.2, .b = 0.2, .a = 1.0 });
        renderer.Renderer.drawText("Reject all", agent_actions.reject.x + 10, agent_actions.reject.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        if (agent_actions.rollback.w > 0) {
            renderer.Renderer.drawRoundedRect(agent_actions.rollback.x, agent_actions.rollback.y, agent_actions.rollback.w, agent_actions.rollback.h, 6, .{ .r = 0.35, .g = 0.35, .b = 0.45, .a = 1.0 });
            renderer.Renderer.drawText("Rollback", agent_actions.rollback.x + 12, agent_actions.rollback.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        }
        if (agent_actions.approve_spec.w > 0) {
            renderer.Renderer.drawRoundedRect(agent_actions.approve_spec.x, agent_actions.approve_spec.y, agent_actions.approve_spec.w, agent_actions.approve_spec.h, 6, .{ .r = 0.2, .g = 0.4, .b = 0.7, .a = 1.0 });
            renderer.Renderer.drawText("Approve spec", agent_actions.approve_spec.x + 8, agent_actions.approve_spec.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        }
        const hint_y = agent_actions.apply.y - 14;
        renderer.Renderer.drawText("Click hunks to accept/reject — Apply selected", inner_x, hint_y, 10.0, .{ .r = 0.65, .g = 0.65, .b = 0.65, .a = 1.0 });
    } else if (snap.spec_pending) {
        const agent_actions = @import("agent_panel.zig").reviewActions(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer, snap.last_checkpoint_id != null, true);
        if (agent_actions.approve_spec.w > 0) {
            renderer.Renderer.drawRoundedRect(agent_actions.approve_spec.x, agent_actions.approve_spec.y, agent_actions.approve_spec.w, agent_actions.approve_spec.h, 6, .{ .r = 0.2, .g = 0.4, .b = 0.7, .a = 1.0 });
            renderer.Renderer.drawText("Approve spec", agent_actions.approve_spec.x + 8, agent_actions.approve_spec.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        }
    }
}

fn drawScopePicker(wb: *@import("../workbench.zig").Workbench, agent_x: f32, agent_w: f32, h: f32) void {
    const pad: f32 = 10;
    renderer.Renderer.drawRect(agent_x, layout.header_height, agent_w, h - layout.header_height - layout.status_height, .{ .r = 0, .g = 0, .b = 0, .a = 0.45 });
    const box_x = agent_x + pad;
    const box_y: f32 = 120;
    const box_w = agent_w - pad * 2;
    const box_h: f32 = 280;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 8, .{ .r = 0.14, .g = 0.16, .b = 0.2, .a = 1.0 });
    renderer.Renderer.drawText("Add file to scope", box_x + 12, box_y + 10, 13.0, .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 });

    wb.agent.lock();
    var query_buf: [320:0]u8 = undefined;
    @memcpy(query_buf[0..wb.agent.scope_query_len], wb.agent.scope_query[0..wb.agent.scope_query_len]);
    query_buf[wb.agent.scope_query_len] = 0;
    const selected = wb.agent.scope_picker_selected;
    wb.agent.unlock();

    renderer.Renderer.drawRoundedRect(box_x + 10, box_y + 32, box_w - 20, 24, 4, .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 });
    renderer.Renderer.drawText(@ptrCast(&query_buf), box_x + 16, box_y + 38, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    var row_y = box_y + 64;
    const max_rows: usize = 12;
    const pinned_count = agent_scope_picker_mod.pinnedVisibleCount(query_buf[0..wb.agent.scope_query_len]);
    var visible_rows: usize = @min(wb.scope_picker_filtered.items.len, max_rows);
    if (pinned_count > 0 and visible_rows + pinned_count <= max_rows) {
        visible_rows += pinned_count;
    } else if (pinned_count > 0) {
        visible_rows = max_rows;
    }

    var draw_index: usize = 0;
    while (draw_index < pinned_count and draw_index < visible_rows) : (draw_index += 1) {
        if (draw_index == selected) {
            renderer.Renderer.drawRoundedRect(box_x + 8, row_y - 2, box_w - 16, 18, 3, .{ .r = 0.22, .g = 0.35, .b = 0.55, .a = 1.0 });
        }
        const label = agent_scope_picker_mod.pinnedLabelAt(query_buf[0..wb.agent.scope_query_len], draw_index) orelse "@pinned";
        var line_buf: [384:0]u8 = undefined;
        @memcpy(line_buf[0..label.len], label);
        line_buf[label.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&line_buf), box_x + 14, row_y, 11.0, .{ .r = 0.75, .g = 0.95, .b = 1.0, .a = 1.0 });
        row_y += 20;
    }

    while (draw_index < visible_rows) : (draw_index += 1) {
        const list_index = draw_index - pinned_count;
        if (list_index >= wb.scope_picker_filtered.items.len) break;
        const path_index = wb.scope_picker_filtered.items[list_index];
        const path = wb.scope_picker_paths.items[path_index];
        if (draw_index == selected) {
            renderer.Renderer.drawRoundedRect(box_x + 8, row_y - 2, box_w - 16, 18, 3, .{ .r = 0.22, .g = 0.35, .b = 0.55, .a = 1.0 });
        }
        var line_buf: [384:0]u8 = undefined;
        var label_buf: [384]u8 = undefined;
        const label = ai.scope_resolver.displayLabel(path, &label_buf);
        const n = @min(label.len, line_buf.len - 1);
        @memcpy(line_buf[0..n], label[0..n]);
        line_buf[n] = 0;
        renderer.Renderer.drawText(@ptrCast(&line_buf), box_x + 14, row_y, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        row_y += 20;
    }
}

fn drawActivityBar(wb: *@import("../workbench.zig").Workbench, w: f32) void {
    const theme = &wb.theme;
    const accent = c(theme.colors.accent);

    // Draw bottom border for activity bar
    renderer.Renderer.drawRect(0, layout.header_height + layout.activity_bar_height - 1, w, 1, c(theme.colors.border));

    for (sidebar_view.all) |view| {
        const x = activity_bar.iconX(view);
        const y = layout.header_height;
        const selected = wb.sidebar_view == view;
        if (selected) {
            // Draw top highlight for selected horizontal tab
            renderer.Renderer.drawRect(x + 6, y, activity_bar.icon_w - 12, 2, accent);
        }
        const color = if (selected)
            renderer.Color{ .r = 1, .g = 1, .b = 1, .a = 1 }
        else
            renderer.Color{ .r = 0.65, .g = 0.65, .b = 0.65, .a = 1 };
        const center = activity_bar.iconCenter(view, w);

        const svg = switch (view) {
            .explorer => renderer.icons.file_directory,
            .search => renderer.icons.search,
            .git => renderer.icons.git_branch,
            .run => renderer.icons.gear,
            .extensions => renderer.icons.plus, // placeholder for extensions
            .ai => renderer.icons.sparkle,
        };
        renderer.Renderer.drawSvg(svg, center.x - 8, center.y - 8, 16, 16, color);
    }
}

fn drawSearchPanel(wb: *@import("../workbench.zig").Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("SEARCH", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const query_y = search_panel.list_top - 32;
    renderer.Renderer.drawRoundedRect(panel_x + 12, query_y, panel_w - 24, search_panel.query_box_h, 4, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
    const show_cursor = @mod(state.time, 1.0) < 0.5;
    const query_str = wb.search_buffer.toDisplayString(show_cursor and wb.focused_panel == .search) catch return;
    defer state.gpa.free(query_str);
    renderer.Renderer.drawText(query_str, panel_x + 20, query_y + 6, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });

    renderer.Renderer.drawRoundedRect(panel_x + 12, query_y + 34, panel_w - 24, 18, 4, c(theme.colors.accent_soft));
    renderer.Renderer.drawText("Search workspace", panel_x + 20, query_y + 37, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

    var y = search_panel.list_top - wb.search_scroll_y + 28;
    if (wb.search_results) |results| {
        for (results.matches, 0..) |match, index| {
            if (y + search_panel.row_h >= 65 and y < h - layout.status_height) {
                renderer.Renderer.drawRect(panel_x, y, panel_w, search_panel.row_h - 4, c(theme.colors.selection));
                var path_buf: [160:0]u8 = undefined;
                @memcpy(path_buf[0..@min(match.path.len, path_buf.len - 1)], match.path[0..@min(match.path.len, path_buf.len - 1)]);
                path_buf[@min(match.path.len, path_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&path_buf), panel_x + 16, y + 2, 11.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                var preview_buf: [128:0]u8 = undefined;
                @memcpy(preview_buf[0..@min(match.preview.len, preview_buf.len - 1)], match.preview[0..@min(match.preview.len, preview_buf.len - 1)]);
                preview_buf[@min(match.preview.len, preview_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&preview_buf), panel_x + 16, y + 16, 10.0, .{ .r = 0.65, .g = 0.75, .b = 0.85, .a = 1.0 });
                _ = index;
            }
            y += search_panel.row_h;
        }
        if (results.matches.len == 0) {
            renderer.Renderer.drawText("No results.", panel_x + 16, search_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        }
    } else {
        renderer.Renderer.drawText("Enter query and click Search.", panel_x + 16, search_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    }
    renderer.Renderer.clearClipRect();
    const result_count = if (wb.search_results) |results| results.matches.len else 0;
    drawSidebarScrollbar(panel_x, panel_w, search_panel.list_top, h, wb.search_scroll_y, result_count, search_panel.row_h);
}

fn countLines(text: ?[]const u8) usize {
    const value = text orelse return 1;
    if (value.len == 0) return 1;
    var count: usize = 1;
    for (value) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn drawGitPanel(wb: *@import("../workbench.zig").Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    const my = state.last_mouse_y;
    const mx = state.last_mouse_x;
    const is_hovering_panel = mx >= panel_x and mx < panel_x + panel_w;

    // Header CHANGES
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 8, 16, 16, icon_c);
    renderer.Renderer.drawText("CHANGES", panel_x + 22, panel_y + 9, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const header_action_y = panel_y + 5;
    // more, refresh, commit, tree
    if (is_hovering_panel and my >= header_action_y and my < header_action_y + 20) {
        if (mx >= panel_x + panel_w - 24 and mx < panel_x + panel_w - 8) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 26, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + panel_w - 48 and mx < panel_x + panel_w - 32) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 50, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + panel_w - 72 and mx < panel_x + panel_w - 56) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 74, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + panel_w - 96 and mx < panel_x + panel_w - 80) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 98, header_action_y, 20, 20, 4, hover_c);
        }
    }
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, panel_x + panel_w - 24, header_action_y + 3, 16, 16, icon_c);
    renderer.Renderer.drawSvg(renderer.icons.sync, panel_x + panel_w - 48, header_action_y + 3, 16, 16, icon_c);
    renderer.Renderer.drawSvg(renderer.icons.check, panel_x + panel_w - 72, header_action_y + 3, 16, 16, icon_c);
    renderer.Renderer.drawSvg(renderer.icons.repo, panel_x + panel_w - 96, header_action_y + 3, 16, 16, icon_c);

    var y = panel_y + 36;
    y -= wb.git_scroll_y;

    // Input Box
    const input_h = 32.0;
    const is_input_focused = wb.focused_panel == .git;
    const input_bg = if (is_input_focused) renderer.Color{ .r = 0.15, .g = 0.15, .b = 0.18, .a = 1.0 } else renderer.Color{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 };
    const input_border = if (is_input_focused) renderer.Color{ .r = 0.3, .g = 0.4, .b = 0.6, .a = 1.0 } else renderer.Color{ .r = 0.2, .g = 0.2, .b = 0.25, .a = 1.0 };

    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, input_h, 4, input_border);
    renderer.Renderer.drawRoundedRect(panel_x + 9, y + 1, panel_w - 18, input_h - 2, 4, input_bg);

    var commit_msg_buf: [1024]u8 = undefined;
    const msg = wb.git_commit_msg.content() catch "";
    defer if (msg.len > 0) wb.allocator.free(msg);

    if (msg.len == 0) {
        renderer.Renderer.drawText("Message (Cmd+Enter to commit)", panel_x + 16, y + 8, 12.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
    } else {
        const display_msg = if (msg.len > 120) msg[0..120] else msg;
        @memcpy(commit_msg_buf[0..display_msg.len], display_msg);
        commit_msg_buf[display_msg.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&commit_msg_buf), panel_x + 16, y + 8, 12.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }

    if (is_input_focused) {
        const cursor_x = panel_x + 16 + renderer.Renderer.measureText(msg, 12.0);
        if (@mod(state.time, 1.0) < 0.5) {
            renderer.Renderer.drawRect(cursor_x, y + 8, 2, 14, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });
        }
    }

    renderer.Renderer.drawSvg(renderer.icons.sparkle, panel_x + panel_w - 28, y + 8, 16, 16, icon_c);

    y += 40;

    // Commit Button
    const btn_bg = renderer.Color{ .r = 0.25, .g = 0.45, .b = 0.65, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, 26, 4, btn_bg);
    renderer.Renderer.drawSvg(renderer.icons.check, panel_x + panel_w / 2 - 30, y + 5, 16, 16, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
    renderer.Renderer.drawText("Commit", panel_x + panel_w / 2 - 16, y + 5, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    y += 34;

    if (wb.git_status) |status| {
        if (!status.is_repo) {
            renderer.Renderer.drawText("Not a git repository.", panel_x + 16, y, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        } else if (status.entries.len == 0) {
            renderer.Renderer.drawText("Working tree clean.", panel_x + 16, y, 12.0, .{ .r = 0.6, .g = 0.8, .b = 0.6, .a = 1.0 });
        } else {
            var staged_count: usize = 0;
            var changes_count: usize = 0;
            for (status.entries) |e| {
                if (e.isStaged()) staged_count += 1;
                if (e.isUnstaged()) changes_count += 1;
            }

            const drawSection = struct {
                fn draw(py: *f32, count: usize, title: [:0]const u8, is_collapsed: bool, entries: []const @import("../git/status.zig").Entry, is_staged_section: bool, px: f32, pw: f32, ch: f32, my_y: f32, mx_x: f32, hc: renderer.Color) void {
                    if (count == 0) return;

                    if (mx_x >= px and mx_x < px + pw and my_y >= py.* and my_y < py.* + 24) {
                        renderer.Renderer.drawRect(px, py.*, pw, 24, hc);
                    }

                    const svg = if (is_collapsed) renderer.icons.chevron_right else renderer.icons.chevron_down;
                    renderer.Renderer.drawSvg(svg, px + 8, py.* + 4, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
                    renderer.Renderer.drawText(title, px + 22, py.* + 5, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

                    var badge_buf: [16:0]u8 = undefined;
                    const badge_str = std.fmt.bufPrintZ(&badge_buf, "{d}", .{count}) catch "0";
                    const badge_w = @as(f32, @floatFromInt(badge_str.len)) * 6.5 + 8;
                    const badge_x = px + pw - badge_w - 12;
                    renderer.Renderer.drawRoundedRect(badge_x, py.* + 4, badge_w, 16, 8, .{ .r = 0.3, .g = 0.5, .b = 0.5, .a = 1.0 });
                    renderer.Renderer.drawText(badge_str, badge_x + 4, py.* + 5, 10.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

                    py.* += 24;

                    if (!is_collapsed) {
                        for (entries) |entry| {
                            if ((is_staged_section and !entry.isStaged()) or (!is_staged_section and !entry.isUnstaged())) continue;
                            if (py.* + 22 >= 65 and py.* < ch - layout.status_height) {
                                const is_hovered = mx_x >= px and mx_x < px + pw and my_y >= py.* and my_y < py.* + 22;
                                if (is_hovered) {
                                    renderer.Renderer.drawRect(px, py.*, pw, 22, hc);
                                    if (is_staged_section) {
                                        renderer.Renderer.drawSvg(renderer.icons.dash, px + pw - 34, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                    } else {
                                        renderer.Renderer.drawSvg(renderer.icons.plus, px + pw - 34, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                    }
                                }

                                const basename = std.fs.path.basename(entry.path);
                                var dir_path: []const u8 = "";
                                if (entry.path.len > basename.len) {
                                    dir_path = entry.path[0 .. entry.path.len - basename.len];
                                    if (dir_path.len > 0 and (dir_path[dir_path.len - 1] == '/' or dir_path[dir_path.len - 1] == '\\')) {
                                        dir_path = dir_path[0 .. dir_path.len - 1];
                                    }
                                }

                                var display_path_buf: [256:0]u8 = undefined;
                                var display_len: usize = basename.len;
                                @memcpy(display_path_buf[0..@min(display_len, 255)], basename[0..@min(display_len, 255)]);
                                if (dir_path.len > 0) {
                                    const combined = std.fmt.bufPrint(&display_path_buf, "{s} {s}", .{ basename, dir_path }) catch display_path_buf[0..display_len];
                                    display_len = combined.len;
                                }
                                display_path_buf[display_len] = 0;

                                const max_w = pw - 60;
                                while (display_len > 0 and renderer.Renderer.measureText(display_path_buf[0..display_len], 11.0) > max_w) {
                                    display_len -= 1;
                                    display_path_buf[display_len] = 0;
                                    if (display_len > 3) {
                                        display_path_buf[display_len - 1] = '.';
                                        display_path_buf[display_len - 2] = '.';
                                        display_path_buf[display_len - 3] = '.';
                                    }
                                }

                                renderer.Renderer.drawText("≡", px + 16, py.* + 2, 12.0, .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 1.0 });

                                const text_color = if (entry.status[0] == 'M' or entry.status[1] == 'M')
                                    renderer.Color{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 }
                                else if (entry.status[0] == 'A')
                                    renderer.Color{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 }
                                else if (entry.status[0] == '?')
                                    renderer.Color{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 }
                                else
                                    renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

                                renderer.Renderer.drawText(@ptrCast(&display_path_buf), px + 30, py.* + 2, 11.0, text_color);

                                if (entry.status[0] == 'M' or entry.status[1] == 'M') {
                                    renderer.Renderer.drawText("M", px + pw - 16, py.* + 2, 11.0, text_color);
                                } else if (entry.status[0] == 'A') {
                                    renderer.Renderer.drawText("A", px + pw - 16, py.* + 2, 11.0, text_color);
                                } else if (entry.status[0] == '?') {
                                    renderer.Renderer.drawText("U", px + pw - 16, py.* + 2, 11.0, text_color);
                                } else {
                                    renderer.Renderer.drawText("M", px + pw - 16, py.* + 2, 11.0, text_color);
                                }
                            }
                            py.* += 22;
                        }
                    }
                }
            }.draw;

            drawSection(&y, staged_count, "Staged Changes", wb.git_staged_collapsed, status.entries, true, panel_x, panel_w, h, my, mx, hover_c);
            drawSection(&y, changes_count, "Changes", wb.git_changes_collapsed, status.entries, false, panel_x, panel_w, h, my, mx, hover_c);
        }
    }

    renderer.Renderer.clearClipRect();

    // Calculate total height for scrollbar
    var total_entries: usize = 0;
    if (wb.git_status) |status| {
        if (status.is_repo) {
            var sc: usize = 0;
            var cc: usize = 0;
            for (status.entries) |e| {
                if (e.isStaged()) sc += 1;
                if (e.isUnstaged()) cc += 1;
            }
            if (sc > 0) total_entries += 1 + if (wb.git_staged_collapsed) 0 else sc;
            if (cc > 0) total_entries += 1 + if (wb.git_changes_collapsed) 0 else cc;
        }
    }
    // const total_h = 36 + 32 + 40 + 34 + @as(f32, @floatFromInt(total_entries)) * 24; // approx
    // Using git_panel.maxScrollY logic roughly:
    // ... we need to make maxScrollY reflect this total_h. Wait, maxScrollY depends on total_h!

    drawSidebarScrollbar(panel_x, panel_w, layout.header_height + layout.activity_bar_height, h, wb.git_scroll_y, total_entries, 24);
}

fn drawDebugPanel(wb: *@import("../workbench.zig").Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const debug_active = wb.debug_lldb.isActive();
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("RUN AND DEBUG", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    var y = debug_panel.list_top - wb.run_scroll_y;
    if (y + 22 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, c(theme.colors.accent_soft));
        renderer.Renderer.drawText("Toggle breakpoint at cursor", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Clear all breakpoints", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 34;

    if (debug_active) {
        if (y + 14 >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawText("DEBUG CONTROLS", panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
        }
        y += 14;
        if (y + debug_panel.control_row_h >= 65 and y < h - layout.status_height) {
            const btn_w = (panel_w - 24) / @as(f32, @floatFromInt(debug_panel.controls.len));
            for (debug_panel.controls, 0..) |control, index| {
                const bx = panel_x + 12 + @as(f32, @floatFromInt(index)) * btn_w;
                renderer.Renderer.drawRoundedRect(bx, y, btn_w - 4, debug_panel.control_row_h - 4, 4, c(theme.colors.selection));
                renderer.Renderer.drawText(control.label, bx + 6, y + 4, 10.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
            }
        }
        y += debug_panel.controls_block_h;
    }

    if (y + 14 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawText("LAUNCH CONFIGURATIONS", panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
    }
    y += 18;
    for (debug_panel.default_launches) |launch| {
        if (y + debug_panel.launch_row_h >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, debug_panel.launch_row_h - 6, 4, c(theme.colors.selection));
            renderer.Renderer.drawText("▶", panel_x + 16, y + 6, 12.0, c(theme.colors.accent));
            renderer.Renderer.drawText(launch.label, panel_x + 32, y + 6, 11.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
        }
        y += debug_panel.launch_row_h;
    }
    y += 16;
    if (y + 14 >= 65 and y < h - layout.status_height) {
        var bp_hdr: [32:0]u8 = undefined;
        const hdr = std.fmt.bufPrint(&bp_hdr, "BREAKPOINTS ({d})", .{wb.breakpoints.items.items.len}) catch "BREAKPOINTS";
        bp_hdr[hdr.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&bp_hdr), panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
    }
    y += 18;
    for (wb.breakpoints.items.items) |bp| {
        if (y + debug_panel.row_h >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawRoundedRect(panel_x + 14, y + 4, 8, 8, 4, c(theme.colors.warning));
            var line_buf: [192:0]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}:{d}", .{ bp.path, bp.line + 1 }) catch bp.path;
            line_buf[line.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&line_buf), panel_x + 28, y + 2, 11.0, .{ .r = 0.88, .g = 0.88, .b = 0.88, .a = 1.0 });
        }
        y += debug_panel.row_h;
    }
    renderer.Renderer.clearClipRect();
    const bp_count = wb.breakpoints.items.items.len;
    const debug_viewport = debug_panel.viewportHeight(h);
    const debug_content = debug_panel.contentHeight(bp_count, debug_active);
    const debug_max = debug_panel.maxScrollY(bp_count, h, debug_active);
    const show_debug_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, debug_panel.list_top, panel_w, debug_viewport);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        debug_panel.list_top,
        debug_viewport,
        wb.run_scroll_y,
        debug_max,
        debug_content,
        debug_viewport,
        show_debug_scroll,
    );
}

fn drawExtensionsPanel(wb: *@import("../workbench.zig").Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const host = &wb.extension_host;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("EXTENSIONS", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const filter_y = extensions_panel.list_top - 20;
    renderer.Renderer.drawRoundedRect(panel_x + 12, filter_y, panel_w - 24, 18, 4, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
    var filter_buf: [128:0]u8 = undefined;
    @memcpy(filter_buf[0..wb.extensions_filter_len], wb.extensionsFilterSlice());
    filter_buf[wb.extensions_filter_len] = 0;
    renderer.Renderer.drawText(@ptrCast(&filter_buf), panel_x + 20, filter_y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

    var y = extensions_panel.list_top - wb.extensions_scroll_y;
    const btn_w = (panel_w - 44) / 2;
    const filter = wb.extensionsFilterSlice();

    if (y + 22 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, btn_w, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Reload", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(panel_x + 16 + btn_w, y, btn_w, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Open ext/", panel_x + 24 + btn_w, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Open .forge/extensions/", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        const installed_bg = if (wb.extensions_panel_mode == .installed)
            c(theme.colors.accent_soft)
        else
            renderer.Color{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 };
        const market_bg = if (wb.extensions_panel_mode == .marketplace)
            c(theme.colors.accent_soft)
        else
            renderer.Color{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 };
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, btn_w, 18, 4, installed_bg);
        renderer.Renderer.drawText("Installed", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(panel_x + 16 + btn_w, y, btn_w, 18, 4, market_bg);
        renderer.Renderer.drawText("Marketplace", panel_x + 24 + btn_w, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += extensions_panel.footer_h;

    if (wb.extensions_detail_index) |detail_index| {
        if (wb.marketplace_catalog) |catalog| {
            if (detail_index < catalog.entries.len) {
                const entry = catalog.entries[detail_index];
                if (y + 22 >= 65 and y < h - layout.status_height) {
                    renderer.Renderer.drawText("< Back", panel_x + 16, y + 4, 11.0, c(theme.colors.accent));
                }
                y += 24;
                var title_buf: [128:0]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}", .{ entry.name, entry.version }) catch entry.name;
                title_buf[title.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 13.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                y += 22;
                var id_buf: [128:0]u8 = undefined;
                @memcpy(id_buf[0..entry.id.len], entry.id);
                id_buf[entry.id.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&id_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.55, .g = 0.75, .b = 0.95, .a = 1.0 });
                y += 16;
                var publisher_buf: [128:0]u8 = undefined;
                const publisher_line = std.fmt.bufPrint(&publisher_buf, "Publisher: {s}", .{entry.publisher}) catch entry.publisher;
                publisher_buf[publisher_line.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&publisher_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                y += 18;
                var desc_buf: [256:0]u8 = undefined;
                @memcpy(desc_buf[0..@min(entry.description.len, desc_buf.len - 1)], entry.description);
                desc_buf[@min(entry.description.len, desc_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&desc_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });
                y += 40;
                renderer.Renderer.drawRoundedRect(panel_x + 12, y + 40, panel_w - 24, 18, 4, c(theme.colors.accent_soft));
                renderer.Renderer.drawText("Install extension", panel_x + 20, y + 43, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            }
        }
    } else if (wb.extensions_panel_mode == .installed) {
        for (host.extensions.items, 0..) |ext, index| {
            if (filter.len > 0 and !agent_scope_picker_mod.matchesQuery(filter, ext.name) and !agent_scope_picker_mod.matchesQuery(filter, ext.id)) continue;
            const block_h = extensions_panel.blockHeight(&ext);
            if (y + block_h >= 65 and y < h - layout.status_height) {
                const selected = wb.selected_extension_index == index;
                if (selected) {
                    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, block_h - 4, 4, c(theme.colors.selection));
                }

                var title_buf: [128:0]u8 = undefined;
                const status = if (ext.active) "active" else "off";
                const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}  {s}", .{ ext.name, ext.version, status }) catch ext.name;
                title_buf[title.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });

                var id_buf: [128:0]u8 = undefined;
                @memcpy(id_buf[0..ext.id.len], ext.id);
                id_buf[ext.id.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&id_buf), panel_x + 16, y + 20, 10.0, .{ .r = 0.55, .g = 0.75, .b = 0.95, .a = 1.0 });

                var path_buf: [160:0]u8 = undefined;
                const path_label = if (std.mem.eql(u8, ext.root_path, "(builtin)"))
                    "(built-in)"
                else
                    ext.root_path;
                @memcpy(path_buf[0..path_label.len], path_label);
                path_buf[path_label.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&path_buf), panel_x + 16, y + 34, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });

                var cmd_y = y + extensions_panel.header_h;
                for (ext.commands.items) |cmd| {
                    var cmd_buf: [160:0]u8 = undefined;
                    const cmd_line = std.fmt.bufPrint(&cmd_buf, "> {s}", .{cmd.title}) catch cmd.title;
                    cmd_buf[cmd_line.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&cmd_buf), panel_x + 20, cmd_y, 10.0, .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 });
                    cmd_y += extensions_panel.cmd_row_h;
                }
                if (wb.canUninstallExtension(&ext)) {
                    renderer.Renderer.drawText("Uninstall", panel_x + 16, y + block_h - 20, 10.0, .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 });
                }
            }
            y += block_h;
        }

        if (host.extensions.items.len == 0) {
            renderer.Renderer.drawText("No extensions loaded.", panel_x + 16, extensions_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            renderer.Renderer.drawText("Add forge.toml to extensions/", panel_x + 16, extensions_panel.list_top + 26, 10.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
        }
    } else if (wb.marketplace_catalog) |catalog| {
        for (catalog.entries, 0..) |entry, index| {
            if (filter.len > 0 and !agent_scope_picker_mod.matchesQuery(filter, entry.name) and !agent_scope_picker_mod.matchesQuery(filter, entry.id) and !agent_scope_picker_mod.matchesQuery(filter, entry.description)) continue;
            if (y + extensions_panel.marketplace_row_h >= 65 and y < h - layout.status_height) {
                renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, extensions_panel.marketplace_row_h - 6, 4, c(theme.colors.selection));
                var title_buf: [128:0]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}", .{ entry.name, entry.version }) catch entry.name;
                title_buf[title.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                var desc_buf: [192:0]u8 = undefined;
                @memcpy(desc_buf[0..@min(entry.description.len, desc_buf.len - 1)], entry.description);
                desc_buf[@min(entry.description.len, desc_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&desc_buf), panel_x + 16, y + 20, 10.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                renderer.Renderer.drawText("Install", panel_x + 16, y + 36, 10.0, c(theme.colors.accent));
                renderer.Renderer.drawText("Details >", panel_x + panel_w - 80, y + 36, 10.0, .{ .r = 0.65, .g = 0.75, .b = 0.95, .a = 1.0 });
                _ = index;
            }
            y += extensions_panel.marketplace_row_h;
        }
        if (catalog.entries.len == 0) {
            renderer.Renderer.drawText("Catalog is empty.", panel_x + 16, y + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        }
    } else {
        renderer.Renderer.drawText("No catalog found.", panel_x + 16, y + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        renderer.Renderer.drawText("Add extensions/catalog.toml", panel_x + 16, y + 26, 10.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
    }

    renderer.Renderer.clearClipRect();
    const catalog_ptr: ?*const plugin.MarketplaceCatalog = if (wb.marketplace_catalog) |*catalog| catalog else null;
    const ext_content = extensions_panel.contentHeight(host, catalog_ptr, wb.extensions_panel_mode, filter, wb.extensions_detail_index);
    const ext_viewport = extensions_panel.viewportHeight(h);
    const ext_max = extensions_panel.maxScrollY(host, catalog_ptr, wb.extensions_panel_mode, h, filter, wb.extensions_detail_index);
    const show_ext_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, extensions_panel.list_top, panel_w, ext_viewport);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        extensions_panel.list_top,
        ext_viewport,
        wb.extensions_scroll_y,
        ext_max,
        ext_content,
        ext_viewport,
        show_ext_scroll,
    );
}

fn drawExplorerPanel(wb: *@import("../workbench.zig").Workbench, explorer_x: f32, explorer_panel_width: f32, h: f32) void {
    const theme = &wb.theme;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(explorer_x, panel_y, explorer_panel_width, h - panel_y - layout.status_height);

    // Draw "v FORGE" header
    var ws_name_buf: [128:0]u8 = undefined;
    const basename = std.fs.path.basename(wb.workspace_path);
    var name_len: usize = 0;
    for (basename) |ch| {
        if (name_len >= ws_name_buf.len - 1) break;
        ws_name_buf[name_len] = std.ascii.toUpper(ch);
        name_len += 1;
    }
    ws_name_buf[name_len] = 0;

    // Draw chevron for workspace
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, explorer_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText(@ptrCast(&ws_name_buf), explorer_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    var rx = explorer_x + explorer_panel_width - 24;
    const my = state.last_mouse_y;
    const mx = state.last_mouse_x;

    const action_y = panel_y + 6;
    const action_icon_y = panel_y + 9;

    if (mx >= rx and mx < rx + 16 and my >= action_y and my < action_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, action_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, rx, action_icon_y, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= action_y and my < action_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, action_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.sync, rx, action_icon_y, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= action_y and my < action_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, action_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.file_directory, rx, action_icon_y, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= action_y and my < action_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, action_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.file, rx, action_icon_y, 16, 16, icon_c);

    var visible: std.ArrayList(@import("../explorer/tree.zig").VisibleEntry) = .empty;
    defer visible.deinit(state.gpa);
    wb.explorer.visibleRows(wb.activeFilePath(), &visible) catch {};

    var file_y: f32 = explorer_scroll.list_top - wb.explorer_scroll_y;
    const chevron_slot_w: f32 = 12;
    const label_gap: f32 = 8;
    for (visible.items, 0..) |row, row_index| {
        const indent = @as(f32, @floatFromInt(row.depth)) * 14.0;
        const label_x = explorer_x + 20 + indent + chevron_slot_w + label_gap;

        const row_h = explorer_scroll.row_height;
        if (file_y + row_h >= 65 and file_y < h - layout.status_height) {
            const hovered = state.explorer_hover_row == row_index and !row.selected and !row.active;

            // Full-width highlights
            if (hovered) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
            } else if (row.active) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, c(theme.colors.accent));
            } else if (row.selected) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, c(theme.colors.selection));
            }

            if (row.kind == .directory) {
                const chevron_color = if (row.selected or row.active)
                    renderer.Color{ .r = 0.89, .g = 0.89, .b = 0.89, .a = 1.0 }
                else
                    renderer.Color{ .r = 0.62, .g = 0.64, .b = 0.68, .a = 1.0 };
                renderer.Renderer.drawSvg(if (row.expanded) renderer.icons.chevron_down else renderer.icons.chevron_right, explorer_x + 20 + indent, file_y + 1, chevron_slot_w, row_h - 2, chevron_color);
            }

            if (wb.renaming and row.selected) {
                const rename_str = wb.rename_buffer.toDisplayString(true) catch "";
                defer state.gpa.free(rename_str);
                renderer.Renderer.drawRoundedRect(label_x - 4, file_y - 2, explorer_panel_width - 32, 18, 3, .{ .r = 0.2, .g = 0.25, .b = 0.35, .a = 1.0 });
                renderer.Renderer.drawText(rename_str, label_x, file_y, 13.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
            } else {
                var label_buf: [512:0]u8 = undefined;
                const name = row.name;
                const max_name = @min(name.len, label_buf.len - 1);
                @memcpy(label_buf[0..max_name], name[0..max_name]);
                label_buf[max_name] = 0;

                // Determine color based on git status
                var is_modified = false;
                var is_added = false;
                var is_untracked = false;

                if (wb.git_status) |*status| {
                    if (std.mem.startsWith(u8, row.path, wb.workspace_path)) {
                        var rel_path = row.path[wb.workspace_path.len..];
                        if (rel_path.len > 0 and (rel_path[0] == '/' or rel_path[0] == '\\')) {
                            rel_path = rel_path[1..];
                        }

                        for (status.entries) |entry| {
                            if (std.mem.eql(u8, entry.path, rel_path)) {
                                if (entry.status[0] == 'M' or entry.status[1] == 'M') is_modified = true;
                                if (entry.status[0] == 'A') is_added = true;
                                if (entry.status[0] == '?') is_untracked = true;
                            } else if (row.kind == .directory and std.mem.startsWith(u8, entry.path, rel_path) and entry.path.len > rel_path.len and (entry.path[rel_path.len] == '/' or entry.path[rel_path.len] == '\\')) {
                                if (entry.status[0] == 'M' or entry.status[1] == 'M') is_modified = true;
                                if (entry.status[0] == 'A') is_added = true;
                                if (entry.status[0] == '?') is_untracked = true;
                            }
                        }
                    }
                }

                var color = if (row.active)
                    renderer.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }
                else if (row.selected)
                    renderer.Color{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 }
                else
                    renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

                if (!row.active and !row.selected) {
                    if (is_modified) {
                        color = .{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 };
                    } else if (is_added or is_untracked) {
                        color = .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 };
                    }
                }

                renderer.Renderer.drawText(@ptrCast(&label_buf), label_x, file_y, 13.0, color);

                // Draw git status indicator on the far right
                if (row.kind == .file) {
                    if (is_modified) {
                        renderer.Renderer.drawText("M", explorer_x + explorer_panel_width - 16, file_y + 1, 11.0, .{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 });
                    } else if (is_added) {
                        renderer.Renderer.drawText("A", explorer_x + explorer_panel_width - 16, file_y + 1, 11.0, .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 });
                    } else if (is_untracked) {
                        renderer.Renderer.drawText("U", explorer_x + explorer_panel_width - 16, file_y + 1, 11.0, .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 });
                    }
                } else if (row.kind == .directory) {
                    if (is_modified) {
                        renderer.Renderer.drawRect(explorer_x + explorer_panel_width - 12, file_y + 8, 4, 4, .{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 });
                    } else if (is_added or is_untracked) {
                        renderer.Renderer.drawRect(explorer_x + explorer_panel_width - 12, file_y + 8, 4, 4, .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 });
                    }
                }
            }
        }
        file_y += row_h;
    }
    renderer.Renderer.clearClipRect();
    drawSidebarScrollbar(explorer_x, explorer_panel_width, explorer_scroll.list_top, h, wb.explorer_scroll_y, visible.items.len, explorer_scroll.row_height);
}

fn drawBracketHighlight(
    editor_buf: *@import("forge-editor").Buffer,
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
    editor_buf: *@import("forge-editor").Buffer,
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
    editor_buf: *@import("forge-editor").Buffer,
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

fn lineColAtBufferOffset(editor_buf: *@import("forge-editor").Buffer, offset: usize) struct { line: usize, col: usize } {
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
    wb: *@import("../workbench.zig").Workbench,
    editor_buf: *@import("forge-editor").Buffer,
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
    wb: *@import("../workbench.zig").Workbench,
    theme: *const @import("forge-workspace").Theme,
    editor_buf: *@import("forge-editor").Buffer,
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
    editor_buf: *@import("forge-editor").Buffer,
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
    wb: *@import("../workbench.zig").Workbench,
    editor_buf: *@import("forge-editor").Buffer,
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

    const diag_store = @import("../workbench/diagnostics_store.zig");
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

fn drawEditorPanel(wb: *@import("../workbench.zig").Workbench, editor_buf: ?*@import("forge-editor").Buffer, editor_x: f32, editor_w: f32, editor_h: f32, _: f32) void {
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

fn drawHoverTooltip(wb: *@import("../workbench.zig").Workbench, editor_x: f32, editor_w: f32) void {
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
    wb: *@import("../workbench.zig").Workbench,
    buf: *@import("forge-editor").Buffer,
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

fn drawEditorOverlay(wb: *@import("../workbench.zig").Workbench, editor_x: f32, editor_w: f32) void {
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

fn drawTaskPanel(wb: *@import("../workbench.zig").Workbench, editor_x: f32, editor_w: f32, panel_y: f32, panel_h: f32) void {
    const bottom_panel = @import("bottom_panel.zig");
    renderer.Renderer.setClipRect(editor_x, panel_y, editor_w, panel_h);
    const tab_y = bottom_panel.tabBarTop(panel_y);
    for (bottom_panel.tabs) |tab| {
        const selected = wb.bottom_panel_mode == tab.mode;
        const tab_x = editor_x + tab.x_offset;

        var label_buf: [32:0]u8 = undefined;
        if (tab.mode == .problems and wb.diagnostics.list.items.len > 0) {
            const prob = std.fmt.bufPrint(&label_buf, "{s} {d}", .{ tab.label, wb.diagnostics.list.items.len }) catch tab.label;
            label_buf[prob.len] = 0;
        } else {
            @memcpy(label_buf[0..tab.label.len], tab.label);
            label_buf[tab.label.len] = 0;
        }

        const text_color = if (selected)
            renderer.Color{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 }
        else
            renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };

        renderer.Renderer.drawText(@ptrCast(&label_buf), tab_x, tab_y + 3, 11.0, text_color);

        if (selected) {
            renderer.Renderer.drawRect(tab_x, tab_y + bottom_panel.tab_h + 2, tab.w - 8, 1.0, text_color);
        }
    }

    if (wb.bottom_panel_mode == .terminal) {
        const rx = editor_x + editor_w;
        const icon_y = tab_y + 3;
        const icon_color = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };

        renderer.Renderer.drawSvg(renderer.icons.x, rx - 24, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.chevron_up, rx - 44, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, rx - 64, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.trash, rx - 88, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.split, rx - 112, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.chevron_down, rx - 136, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.plus, rx - 156, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawText("zsh", rx - 188, icon_y + 3, 11.0, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.terminal, rx - 208, icon_y, 16, 16, icon_color);
    }

    switch (wb.bottom_panel_mode) {
        .output => {
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            if (wb.rename_preview.active) {
                renderer.Renderer.drawText("Rename preview — Enter=Accept  Esc=Reject", editor_x + 20, line_y, 12.0, .{ .r = 0.95, .g = 0.85, .b = 0.45, .a = 1.0 });
                line_y += 14.0;
                for (wb.rename_preview.lines) |item| {
                    var buf: [512:0]u8 = undefined;
                    const clipped = if (item.label.len > 511) item.label[0..511] else item.label;
                    @memcpy(buf[0..clipped.len], clipped);
                    buf[clipped.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.85, .g = 0.95, .b = 0.75, .a = 1.0 });
                    line_y += 14.0;
                }
            } else if (wb.references.active) {
                for (wb.references.items) |item| {
                    var buf: [512:0]u8 = undefined;
                    const clipped = if (item.label.len > 511) item.label[0..511] else item.label;
                    @memcpy(buf[0..clipped.len], clipped);
                    buf[clipped.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.75, .g = 0.85, .b = 1.0, .a = 1.0 });
                    line_y += 14.0;
                }
            } else {
                const task_state = wb.task_output.snapshotState();
                wb.task_output.lock();
                defer wb.task_output.unlock();
                for (wb.task_output.lines.items) |line| {
                    var buf: [512:0]u8 = undefined;
                    const clipped = if (line.len > 511) line[0..511] else line;
                    @memcpy(buf[0..clipped.len], clipped);
                    buf[clipped.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 });
                    line_y += 14.0;
                }
                if (task_state.last_exit_code) |code| {
                    var exit_buf: [64:0]u8 = undefined;
                    const exit_msg = std.fmt.bufPrint(&exit_buf, "exit code: {d}", .{code}) catch "";
                    exit_buf[exit_msg.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&exit_buf), editor_x + 20, panel_y + panel_h - 26, 12.0, .{ .r = 0.6, .g = 0.8, .b = 0.6, .a = 1.0 });
                }
            }
        },
        .problems => {
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            for (wb.diagnostics.list.items) |item| {
                var buf: [512:0]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "L{d}:{d}  {s}", .{ item.line + 1, item.character + 1, item.message }) catch item.message;
                buf[line.len] = 0;
                const color = switch (item.severity) {
                    .err => renderer.Color{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 },
                    .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                    else => renderer.Color{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 },
                };
                renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, color);
                line_y += 14.0;
            }
            if (wb.diagnostics.list.items.len == 0) {
                renderer.Renderer.drawText("No problems for active file.", editor_x + 20, panel_y + 40, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            }
        },
        .terminal => {
            const terminal_panel = @import("terminal_panel.zig");
            const terminal = wb.activeTerminal();
            terminal.lock();
            defer terminal.unlock();

            // In Cursor design, terminal contents start directly below the main tab bar
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            const git_ptr: ?*const @import("../git/status.zig").Status = if (wb.git_status) |*status| status else null;
            const show_cursor = @mod(state.time, 1.0) < 0.5;
            const show_terminal_cursor = show_cursor and wb.focused_panel == .terminal;

            if (wb.terminal_selection) |sel| {
                terminal_panel.drawSelection(editor_x, panel_y, wb.task_scroll_y, terminal.lines.items, sel);
            }
            var line_y = content_top - wb.task_scroll_y;
            for (terminal.lines.items) |line| {
                if (line_y + 14.0 >= content_top and line_y < content_top + content_h) {
                    terminal_panel.drawStyledLine(editor_x, line_y, line, wb.workspace_path, git_ptr);
                }
                line_y += 14.0;
            }
            if (terminal.local_input != null or terminal.isActive()) {
                if (line_y + 14.0 >= content_top and line_y < content_top + content_h) {
                    var active_buf: [512]u8 = undefined;
                    const active = terminal.activeLine(&active_buf);
                    terminal_panel.drawStyledLine(editor_x, line_y, active, wb.workspace_path, git_ptr);
                    const col = active.len;
                    terminal_panel.drawInputCursor(editor_x, line_y, active, col, show_terminal_cursor);
                }
            } else if (terminal.lines.items.len == 0) {
                const hint = if (terminal.isActive())
                    "Shell running — type here."
                else if (terminal.exited)
                    "Shell exited — click TERMINAL tab to restart."
                else
                    "Starting terminal…";
                renderer.Renderer.drawText(hint, editor_x + 20, content_top + 8, 12.0, .{ .r = 0.50, .g = 0.58, .b = 0.68, .a = 1.0 });
            }
        },
        .debug_console => {
            wb.debug_console.lock();
            defer wb.debug_console.unlock();
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            for (wb.debug_console.lines.items) |line| {
                var buf: [512:0]u8 = undefined;
                const clipped = if (line.len > 511) line[0..511] else line;
                @memcpy(buf[0..clipped.len], clipped);
                buf[clipped.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.75, .g = 0.85, .b = 1.0, .a = 1.0 });
                line_y += 14.0;
            }
            if (wb.debug_console.lines.items.len == 0) {
                renderer.Renderer.drawText("Debug console ready.", editor_x + 20, panel_y + 40, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            }
        },
        .debug_variables => {
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            if (line_y + 14 >= content_top and line_y < content_top + content_h) {
                renderer.Renderer.drawText("LOCAL VARIABLES", editor_x + 20, line_y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
            }
            line_y += 16;
            for (wb.debug_variables.items.items) |entry| {
                if (line_y + 14 < content_top or line_y >= content_top + content_h) {
                    line_y += 14;
                    continue;
                }
                var buf: [512:0]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s} ({s}) = {s}", .{ entry.name, entry.type_name, entry.value }) catch entry.name;
                buf[label.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.85, .g = 0.92, .b = 0.75, .a = 1.0 });
                line_y += 14;
            }
            if (wb.debug_variables.items.items.len == 0) {
                renderer.Renderer.drawText("No variables — start debug session and step.", editor_x + 20, panel_y + 40, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            } else if (wb.task_scroll_y < 1) {
                renderer.Renderer.drawText("Click a variable to copy its value.", editor_x + 20, panel_y + panel_h - 18, 11.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
            }
        },
        .debug_callstack => {
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            if (line_y + 14 >= content_top and line_y < content_top + content_h) {
                renderer.Renderer.drawText("CALL STACK", editor_x + 20, line_y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
            }
            line_y += 16;
            for (wb.debug_callstack.items.items) |frame| {
                if (line_y + 14 < content_top or line_y >= content_top + content_h) {
                    line_y += 14;
                    continue;
                }
                var buf: [512:0]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "#{d} {s} — {s}:{d}", .{ frame.index, frame.label, frame.path, frame.line + 1 }) catch frame.label;
                buf[label.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.75, .g = 0.85, .b = 1.0, .a = 1.0 });
                line_y += 14;
            }
            if (wb.debug_callstack.items.items.len == 0) {
                renderer.Renderer.drawText("No stack frames — start debug session and step.", editor_x + 20, panel_y + 40, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            } else if (wb.task_scroll_y < 1) {
                renderer.Renderer.drawText("Click a frame to jump to source.", editor_x + 20, panel_y + panel_h - 18, 11.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
            }
        },
    }
    renderer.Renderer.clearClipRect();
    const bottom_content_top = panel_y + 34.0;
    const bottom_content_h = panel_h - 34.0;
    const bottom_line_count = wb.bottomPanelLineCount();
    const bottom_content = @as(f32, @floatFromInt(@max(1, bottom_line_count))) * panel_scroll.bottom_line_h;
    const bottom_max = @max(0, bottom_content - bottom_content_h);
    const show_bottom_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, editor_x, bottom_content_top, editor_w, bottom_content_h);
    scrollbar.drawVertical(
        editor_x + editor_w - scrollbar.track_w - 4,
        bottom_content_top,
        bottom_content_h,
        wb.task_scroll_y,
        bottom_max,
        bottom_content,
        bottom_content_h,
        show_bottom_scroll,
    );
}

fn drawStatusBar(wb: *@import("../workbench.zig").Workbench, w: f32, h: f32, shell_mode: layout.ShellMode) void {
    var status_buf: [320:0]u8 = undefined;
    var font_name: [48:0]u8 = undefined;
    renderer.Renderer.getResolvedFontName(&font_name);
    const ext_count = wb.extension_host.activeExtensionCount();
    const lsp_label: []const u8 = blk: {
        if (wb.activeFilePath()) |path| {
            wb.lsp_registry.mutex.lock();
            defer wb.lsp_registry.mutex.unlock();
            if (wb.lsp_registry.findForPathUnlocked(path)) |server| {
                break :blk server.language_id;
            }
        }
        break :blk "-";
    };
    const mode_label = switch (shell_mode) {
        .ide => "IDE",
        .agent_window => "Agent",
    };
    const status_label = std.fmt.bufPrint(&status_buf, "{s}  |  {s}{s}  |  {d:.0}pt {s}  |  ext: {d}  |  lsp: {s}  |  problems: {d}  |  Cmd+Shift+P", .{
        mode_label,
        wb.activePathBasename(),
        if (wb.tabs.tabs.items.len > 0 and wb.tabs.active < wb.tabs.tabs.items.len)
            if (wb.tabs.tabs.items[wb.tabs.active].isDirty()) " • modified" else ""
        else
            "",
        wb.theme.editor_font_size,
        font_name,
        ext_count,
        lsp_label,
        wb.diagnostics.list.items.len,
    }) catch wb.activePathBasename();
    status_buf[status_label.len] = 0;
    if (wb.status_message.len > 0) {
        renderer.Renderer.drawText(wb.status_message, w - 320, h - 18, 12.0, .{ .r = 0.9, .g = 0.9, .b = 0.6, .a = 1.0 });
    }
    renderer.Renderer.drawText(@ptrCast(&status_buf), 20, h - 18, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
}

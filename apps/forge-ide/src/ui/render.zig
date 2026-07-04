const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("state.zig");
const layout = @import("layout.zig");
const editor_scroll = @import("editor_scroll.zig");
const activity_bar = @import("activity_bar.zig");
const sidebar_view = @import("sidebar_view.zig");
const extensions_panel = @import("extensions_panel.zig");
const search_panel = @import("search_panel.zig");
const activity_icons = @import("activity_icons.zig");
const debug_panel = @import("debug_panel.zig");
const git_panel = @import("git_panel.zig");
const explorer_scroll = @import("explorer_scroll.zig");
const tabs_ui = @import("tabs.zig");
const theme_loader = @import("../theme_loader.zig");

fn c(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return theme_loader.toColor(rgba);
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

    var w: f32 = 0;
    var h: f32 = 0;
    renderer.Renderer.getWindowSize(&w, &h);

    const geo = layout.compute(wb.shell_mode, w, h, wb.explorer_panel_width, wb.agent_panel_width, wb.bottom_panel_height);
    wb.clampEditorScroll(geo.editor_w, geo.editor_h);
    wb.clampTabScroll(geo.editor_w);
    wb.clampExplorerScroll(h);
    wb.clampExtensionsScroll(h);
    wb.clampSearchScroll(h);
    wb.clampGitScroll(h);
    wb.clampRunScroll(h);
    const side_h = geo.content_h;

    if (state.root_view) |rv| {
        rv.frame = .{ .x = 0, .y = 0, .w = w, .h = h };
        if (state.header_view) |v| v.frame = .{ .x = 0, .y = 0, .w = w, .h = layout.header_height };
        if (state.activity_view) |v| v.frame = .{ .x = 0, .y = layout.header_height, .w = layout.activity_bar_width, .h = side_h };
        if (state.explorer_view) |v| v.frame = .{ .x = geo.explorer_x, .y = layout.header_height, .w = geo.explorer_w, .h = side_h };
        if (state.editor_view) |v| v.frame = .{ .x = geo.editor_x, .y = layout.header_height, .w = geo.editor_w, .h = geo.editor_h };
        if (state.panel_view) |v| v.frame = .{ .x = geo.editor_x, .y = geo.task_panel_y, .w = geo.editor_w, .h = geo.task_panel_h };
        if (state.border_view) |v| v.frame = .{ .x = geo.editor_x, .y = geo.task_panel_y, .w = geo.editor_w, .h = 1 };
        if (state.agent_view) |v| v.frame = .{ .x = geo.agent_x, .y = layout.header_height, .w = geo.agent_w, .h = side_h };
        if (state.status_view) |v| v.frame = .{ .x = 0, .y = h - layout.status_height, .w = w, .h = layout.status_height };

        rv.render();
        renderer.Renderer.drawText("Forge IDE", w / 2 - 40, 8, 14.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

        if (geo.shell_mode == .ide) {
            drawActivityBar(wb);
            switch (wb.sidebar_view) {
                .explorer => drawExplorerPanel(wb, geo.explorer_x, geo.explorer_w, h),
                .search => drawSearchPanel(wb, geo.explorer_x, geo.explorer_w, h),
                .git => drawGitPanel(wb, geo.explorer_x, geo.explorer_w, h),
                .run => drawDebugPanel(wb, geo.explorer_x, geo.explorer_w, h),
                .extensions => drawExtensionsPanel(wb, geo.explorer_x, geo.explorer_w, h),
            }
            drawEditorPanel(wb, editor_buf, geo.editor_x, geo.editor_w, geo.editor_h, w);
            drawTaskPanel(wb, geo.editor_x, geo.editor_w, geo.task_panel_y, geo.task_panel_h);
        }
        drawAgentPanel(wb, geo.agent_x, geo.agent_w, h);
        drawStatusBar(wb, w, h, geo.shell_mode);

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

    const snap = wb.agent.snapshot();
    var mode_buf: [32:0]u8 = undefined;
    const mode_label = std.fmt.bufPrint(&mode_buf, "AGENT — {s}", .{@tagName(snap.mode)}) catch "AGENT";
    mode_buf[mode_label.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&mode_buf), inner_x, 45, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });

    if (snap.status_line.len > 0) {
        var status_buf: [256:0]u8 = undefined;
        const clipped = if (snap.status_line.len > 255) snap.status_line[0..255] else snap.status_line;
        @memcpy(status_buf[0..clipped.len], clipped);
        status_buf[clipped.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&status_buf), inner_x, 62, 11.0, .{ .r = 0.75, .g = 0.85, .b = 1.0, .a = 1.0 });
    }

    var run_y: f32 = 82.0;
    wb.agent.lock();
    const run_count = wb.agent.run_history.items.len;
    const selected_run = wb.agent.selected_run_index;
    for (wb.agent.run_history.items, 0..) |entry, index| {
        if (index >= 4) break;
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

    var scope_y = run_y;
    wb.agent.lock();
    for (wb.agent.scope_files.items) |path| {
        var chip_buf: [160:0]u8 = undefined;
        const base = std.fs.path.basename(path);
        const chip = std.fmt.bufPrint(&chip_buf, "@ {s}", .{base}) catch base;
        chip_buf[chip.len] = 0;
        renderer.Renderer.drawRoundedRect(inner_x - 2, scope_y - 2, content_w - 10, 16, 4, .{ .r = 0.18, .g = 0.28, .b = 0.38, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&chip_buf), inner_x + 4, scope_y, 10.0, .{ .r = 0.85, .g = 0.95, .b = 1.0, .a = 1.0 });
        scope_y += 18.0;
    }
    wb.agent.unlock();

    var content_y: f32 = scope_y + 8.0 - wb.chat_scroll_y;

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
            if (review_y > h - 180) break;
            var ctx_buf: [512:0]u8 = undefined;
            const clipped = if (line.len > 511) line[0..511] else line;
            @memcpy(ctx_buf[0..clipped.len], clipped);
            ctx_buf[clipped.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&ctx_buf), inner_x + 6, review_y, 9.5, .{ .r = 0.7, .g = 0.78, .b = 0.9, .a = 1.0 });
            review_y += 11.0;
        }
        review_y += 6.0;
        renderer.Renderer.drawText("DIFF", inner_x, review_y, 10.0, .{ .r = 0.55, .g = 0.75, .b = 1.0, .a = 1.0 });
        review_y += 14.0;
        for (wb.agent.diff_lines.items) |line| {
            if (review_y > h - 180) break;
            var line_buf: [512:0]u8 = undefined;
            const clipped = if (line.len > 511) line[0..511] else line;
            @memcpy(line_buf[0..clipped.len], clipped);
            line_buf[clipped.len] = 0;
            var color = renderer.Color{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 };
            if (line.len > 0 and line[0] == '+') color = .{ .r = 0.5, .g = 0.9, .b = 0.5, .a = 1.0 };
            if (line.len > 0 and line[0] == '-') color = .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 };
            if (line.len > 3 and std.mem.startsWith(u8, line, "---")) color = .{ .r = 0.95, .g = 0.85, .b = 0.45, .a = 1.0 };
            if (line.len > 3 and std.mem.startsWith(u8, line, "+++")) color = .{ .r = 0.55, .g = 0.85, .b = 0.95, .a = 1.0 };
            renderer.Renderer.drawText(@ptrCast(&line_buf), inner_x + 6, review_y, 10.0, color);
            review_y += 12.0;
        }
        wb.agent.unlock();

        renderer.Renderer.drawText("Cmd+Enter apply  Esc reject  Up/Down scroll", inner_x, h - 120, 10.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    } else {
        for (state.chat_history.?.items) |msg| {
            const lines = @as(f32, @floatFromInt(std.mem.count(u8, msg.content, "\n") + 1));
            const bubble_h = lines * 16.0 + 10.0;
            const bubble_x = agent_x + 10;
            if (msg.role == .user) {
                renderer.Renderer.drawRoundedRect(bubble_x, content_y - 4, content_w, bubble_h, 8.0, .{ .r = 0.2, .g = 0.2, .b = 0.25, .a = 1.0 });
                renderer.Renderer.drawText(msg.content, inner_x + 40, content_y, 14.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            } else {
                renderer.Renderer.drawRoundedRect(bubble_x, content_y - 4, content_w, bubble_h, 8.0, .{ .r = 0.15, .g = 0.25, .b = 0.15, .a = 1.0 });
                renderer.Renderer.drawText(msg.content, inner_x + 50, content_y, 14.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            }
            content_y += bubble_h + 10.0;
        }
    }

    const input_y = h - layout.status_height - 100;
    renderer.Renderer.drawRoundedRect(agent_x + 10, input_y, content_w, 80, 12.0, .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 });
    const show_cursor = @mod(state.time, 1.0) < 0.5;
    const show_prompt_cursor = show_cursor and wb.focused_panel == .agent and !snap.show_review and !snap.worker_running;
    const prompt_str = wb.prompt_buffer.toDisplayString(show_prompt_cursor) catch return;
    defer state.gpa.free(prompt_str);
    renderer.Renderer.drawText(prompt_str, inner_x, input_y + 10, 14.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
    if (!snap.show_review and !snap.worker_running) {
        renderer.Renderer.drawText("@ add scope file", inner_x, input_y + 58, 10.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
    }
    renderer.Renderer.clearClipRect();
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
    const show_rows = @min(wb.scope_picker_filtered.items.len, max_rows);
    for (0..show_rows) |visible_index| {
        const path_index = wb.scope_picker_filtered.items[visible_index];
        const path = wb.scope_picker_paths.items[path_index];
        if (visible_index == selected) {
            renderer.Renderer.drawRoundedRect(box_x + 8, row_y - 2, box_w - 16, 18, 3, .{ .r = 0.22, .g = 0.35, .b = 0.55, .a = 1.0 });
        }
        var line_buf: [384:0]u8 = undefined;
        @memcpy(line_buf[0..path.len], path);
        line_buf[path.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&line_buf), box_x + 14, row_y, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        row_y += 20;
    }
}

fn drawActivityBar(wb: *@import("../workbench.zig").Workbench) void {
    const theme = &wb.theme;
    const accent = c(theme.colors.accent);

    for (sidebar_view.all) |view| {
        const y = activity_bar.iconY(view);
        const selected = wb.sidebar_view == view;
        if (selected) {
            renderer.Renderer.drawRect(0, y + 6, 3, activity_bar.icon_h - 12, accent);
            renderer.Renderer.drawRoundedRect(6, y + 2, 38, activity_bar.icon_h - 4, 4, .{ .r = 0.28, .g = 0.32, .b = 0.38, .a = 1.0 });
        }
        const color = if (selected)
            renderer.Color{ .r = 1, .g = 1, .b = 1, .a = 1 }
        else
            renderer.Color{ .r = 0.65, .g = 0.65, .b = 0.65, .a = 1 };
        const center = activity_bar.iconCenter(view);
        activity_icons.draw(view, center.x, center.y, color);
    }
}

fn drawSearchPanel(wb: *@import("../workbench.zig").Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    renderer.Renderer.setClipRect(panel_x, 30, panel_w, h - 52);
    renderer.Renderer.drawText("SEARCH", panel_x + 20, 45, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });

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
                renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, search_panel.row_h - 4, 4, c(theme.colors.selection));
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
}

fn drawGitPanel(wb: *@import("../workbench.zig").Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    renderer.Renderer.setClipRect(panel_x, 30, panel_w, h - 52);
    renderer.Renderer.drawText("SOURCE CONTROL", panel_x + 20, 45, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });

    const btn_y = git_panel.list_top - 32;
    renderer.Renderer.drawRoundedRect(panel_x + 12, btn_y, panel_w - 24, 18, 4, c(theme.colors.accent_soft));
    renderer.Renderer.drawText("Refresh git status", panel_x + 20, btn_y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

    var y = git_panel.list_top - wb.git_scroll_y + 28;
    if (wb.git_status) |status| {
        if (!status.is_repo) {
            renderer.Renderer.drawText("Not a git repository.", panel_x + 16, git_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        } else if (status.entries.len == 0) {
            renderer.Renderer.drawText("Working tree clean.", panel_x + 16, git_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.8, .b = 0.6, .a = 1.0 });
        } else {
            for (status.entries) |entry| {
                if (y + git_panel.row_h >= 65 and y < h - layout.status_height) {
                    var status_buf: [8:0]u8 = undefined;
                    status_buf[0] = entry.status[0];
                    status_buf[1] = entry.status[1];
                    status_buf[2] = 0;
                    renderer.Renderer.drawText(@ptrCast(&status_buf), panel_x + 16, y + 2, 11.0, c(theme.colors.warning));
                    var path_buf: [160:0]u8 = undefined;
                    @memcpy(path_buf[0..@min(entry.path.len, path_buf.len - 1)], entry.path[0..@min(entry.path.len, path_buf.len - 1)]);
                    path_buf[@min(entry.path.len, path_buf.len - 1)] = 0;
                    renderer.Renderer.drawText(@ptrCast(&path_buf), panel_x + 40, y + 2, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
                    var label_buf: [64:0]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buf, "{s}", .{entry.label()}) catch "";
                    label_buf[label.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&label_buf), panel_x + 40, y + 14, 9.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
                }
                y += git_panel.row_h;
            }
        }
    } else {
        renderer.Renderer.drawText("Click Refresh to load status.", panel_x + 16, git_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    }
    renderer.Renderer.clearClipRect();
}

fn drawDebugPanel(wb: *@import("../workbench.zig").Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    renderer.Renderer.setClipRect(panel_x, 30, panel_w, h - 52);
    renderer.Renderer.drawText("RUN AND DEBUG", panel_x + 20, 45, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });

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
}

fn drawExtensionsPanel(wb: *@import("../workbench.zig").Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const host = &wb.extension_host;
    renderer.Renderer.setClipRect(panel_x, 30, panel_w, h - 52);
    renderer.Renderer.drawText("EXTENSIONS", panel_x + 20, 45, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });

    const filter_y = extensions_panel.list_top - 20;
    renderer.Renderer.drawRoundedRect(panel_x + 12, filter_y, panel_w - 24, 18, 4, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
    var filter_buf: [128:0]u8 = undefined;
    @memcpy(filter_buf[0..wb.extensions_filter_len], wb.extensionsFilterSlice());
    filter_buf[wb.extensions_filter_len] = 0;
    renderer.Renderer.drawText(@ptrCast(&filter_buf), panel_x + 20, filter_y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

    var y = extensions_panel.list_top - wb.extensions_scroll_y;
    const btn_w = (panel_w - 44) / 2;
    const filter = wb.extensionsFilterSlice();
    const scope_picker = @import("../agent/scope_picker.zig");

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
            if (filter.len > 0 and !scope_picker.matchesQuery(filter, ext.name) and !scope_picker.matchesQuery(filter, ext.id)) continue;
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
            if (filter.len > 0 and !scope_picker.matchesQuery(filter, entry.name) and !scope_picker.matchesQuery(filter, entry.id) and !scope_picker.matchesQuery(filter, entry.description)) continue;
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
}

fn drawExplorerPanel(wb: *@import("../workbench.zig").Workbench, explorer_x: f32, explorer_panel_width: f32, h: f32) void {
    const theme = &wb.theme;
    renderer.Renderer.setClipRect(explorer_x, 30, explorer_panel_width, h - 52);
    renderer.Renderer.drawText("EXPLORER", explorer_x + 20, 45, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });

    var visible: std.ArrayList(@import("../explorer/tree.zig").VisibleEntry) = .empty;
    defer visible.deinit(state.gpa);
    wb.explorer.visibleRows(wb.activeFilePath(), &visible) catch {};

    var file_y: f32 = explorer_scroll.list_top - wb.explorer_scroll_y;
    for (visible.items) |row| {
        const indent = @as(f32, @floatFromInt(row.depth)) * 14.0;
        const prefix = if (row.kind == .directory)
            if (row.expanded) "v " else "> "
        else
            "  ";

        const row_h = explorer_scroll.row_height;
        if (file_y + row_h >= 65 and file_y < h - layout.status_height) {
            if (row.active) {
                renderer.Renderer.drawRoundedRect(explorer_x + 8, file_y - 2, explorer_panel_width - 16, 18, 3, c(theme.colors.accent));
            } else if (row.selected) {
                renderer.Renderer.drawRoundedRect(explorer_x + 8, file_y - 2, explorer_panel_width - 16, 18, 3, c(theme.colors.selection));
            }

            if (wb.renaming and row.selected) {
                const rename_str = wb.rename_buffer.toDisplayString(true) catch "";
                defer state.gpa.free(rename_str);
                renderer.Renderer.drawRoundedRect(explorer_x + 16 + indent, file_y - 2, explorer_panel_width - 32, 18, 3, .{ .r = 0.2, .g = 0.25, .b = 0.35, .a = 1.0 });
                renderer.Renderer.drawText(rename_str, explorer_x + 20 + indent, file_y, 13.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
            } else {
                var label_buf: [512:0]u8 = undefined;
                const name = row.name;
                const max_name = @min(name.len, label_buf.len - 4);
                @memcpy(label_buf[0..prefix.len], prefix);
                @memcpy(label_buf[prefix.len .. prefix.len + max_name], name[0..max_name]);
                label_buf[prefix.len + max_name] = 0;
                const color = if (row.active)
                    renderer.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }
                else if (row.selected)
                    renderer.Color{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 }
                else
                    renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };
                renderer.Renderer.drawText(@ptrCast(&label_buf), explorer_x + 20 + indent, file_y, 13.0, color);
            }
        }
        file_y += row_h;
    }
    renderer.Renderer.clearClipRect();
}

fn drawEditorPanel(wb: *@import("../workbench.zig").Workbench, editor_buf: ?*@import("forge-editor").Buffer, editor_x: f32, editor_w: f32, editor_h: f32, _: f32) void {
    const theme = &wb.theme;
    const ui_size = theme.ui_font_size;
    renderer.Renderer.drawRect(editor_x, tabs_ui.tab_bar_top, editor_w, tabs_ui.tab_bar_height, c(theme.colors.tab_bar_bg));
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
            renderer.Renderer.drawRoundedRect(tab_layout.x, tabs_ui.tab_y, tab_layout.width, tabs_ui.tab_height, 6.0, c(theme.colors.tab_active_bg));
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

    renderer.Renderer.clearClipRect();

    const editor_view_h = editor_scroll.viewportHeight(editor_h);
    const gutter = editor_scroll.gutterWidth(theme);
    const line_h = editor_scroll.lineHeight(theme);
    const char_w = editor_scroll.charWidth(theme);
    const font_size = theme.editor_font_size;
    const text_x = editor_x + gutter - wb.editor_scroll_x;

    renderer.Renderer.drawRect(editor_x, 65, gutter, editor_view_h, c(theme.colors.sidebar_bg));
    renderer.Renderer.setClipRect(editor_x, 65, editor_w, editor_view_h);
    const show_cursor = @mod(state.time, 1.0) < 0.5;
    const show_editor_cursor = show_cursor and wb.focused_panel == .editor;

    if (editor_buf) |buf| {
        const line_count = buf.lineCount();
        const content_h = editor_scroll.contentHeight(line_count, theme);
        const max_scroll_y = editor_scroll.maxScrollY(line_count, editor_h, theme);
        const max_line_len = editor_scroll.longestLineLen(buf);
        const content_w = @as(f32, @floatFromInt(max_line_len)) * char_w;
        const viewport_w = editor_scroll.viewportWidth(editor_w, theme);
        const max_scroll_x = editor_scroll.maxScrollX(content_w, editor_w, theme);

        const active_path = wb.activeFilePath();
        var line_num_y = editor_scroll.firstLineY(theme) - wb.editor_scroll_y;
        const diag_store = @import("../workbench/diagnostics_store.zig");
        for (0..line_count) |idx| {
            if (line_num_y + line_h >= 65 and line_num_y < 65 + editor_view_h) {
                if (active_path) |path| {
                    if (wb.breakpoints.hasAt(path, idx)) {
                        renderer.Renderer.drawRoundedRect(editor_x + 4, line_num_y + 4, 8, 8, 4, c(theme.colors.warning));
                    }
                }
                var num_buf: [16]u8 = undefined;
                const line_str = std.fmt.bufPrintZ(&num_buf, "{d}", .{idx + 1}) catch "";
                renderer.Renderer.drawText(line_str, editor_x + 10, line_num_y, font_size, c(theme.colors.line_number));
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
            line_num_y += line_h;
        }

        renderer.Renderer.setClipRect(editor_x + gutter, 65, editor_w - gutter, editor_view_h);
        line_num_y = editor_scroll.firstLineY(theme) - wb.editor_scroll_y;
        for (0..line_count) |idx| {
            if (line_num_y + line_h >= 65 and line_num_y < 65 + editor_view_h) {
                drawFindHighlights(wb, buf, idx, text_x, line_num_y, line_h, font_size);
                drawHighlightedLine(buf.lineAt(idx), text_x, line_num_y, theme);
                for (wb.diagnostics.list.items) |diag| {
                    if (diag.line != idx) continue;
                    const line = buf.lineAt(idx);
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
                if (show_editor_cursor and idx == buf.cursor.row) {
                    const line = buf.lineAt(idx);
                    const cursor_x = text_x + editor_scroll.cursorX(line, buf.cursor.col, font_size);
                    renderer.Renderer.drawText("|", cursor_x, line_num_y, font_size, c(theme.colors.cursor));
                }
            }
            line_num_y += line_h;
        }

        renderer.Renderer.setClipRect(editor_x, 65, editor_w, editor_view_h);
        if (max_scroll_y > 0) {
            const scroll_ratio = wb.editor_scroll_y / max_scroll_y;
            const scrollbar_h = @max(20.0, editor_view_h * (editor_view_h / content_h));
            const scrollbar_y = 65.0 + scroll_ratio * (editor_view_h - scrollbar_h);
            renderer.Renderer.drawRoundedRect(editor_x + editor_w - 12, scrollbar_y, 8, scrollbar_h, 4.0, .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 0.5 });
        }

        if (max_scroll_x > 0) {
            const scroll_ratio = wb.editor_scroll_x / max_scroll_x;
            const scrollbar_w = @max(20.0, viewport_w * (viewport_w / content_w));
            const scrollbar_x = editor_x + gutter + scroll_ratio * (viewport_w - scrollbar_w);
            const scrollbar_y = 65.0 + editor_view_h - 10;
            renderer.Renderer.drawRoundedRect(scrollbar_x, scrollbar_y, scrollbar_w, 8, 4.0, .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 0.5 });
        }
    }
    if (wb.completions.visible and wb.completions.list.items.len > 0) {
        const popup_x = editor_x + gutter + 8;
        const popup_y: f32 = 90;
        const popup_w = @min(editor_w - gutter - 16, 360);
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
    if (wb.find_bar.open or wb.goto_bar.open) {
        drawEditorOverlay(wb, editor_x, editor_w);
    }
    drawHoverTooltip(wb, editor_x, editor_w);
    renderer.Renderer.clearClipRect();
}

fn drawHoverTooltip(wb: *@import("../workbench.zig").Workbench, editor_x: f32, editor_w: f32) void {
    const text = wb.hover.text orelse return;
    if (text.len == 0) return;

    var display_buf: [512:0]u8 = undefined;
    const clipped = if (text.len > 511) text[0..511] else text;
    @memcpy(display_buf[0..clipped.len], clipped);
    display_buf[clipped.len] = 0;

    const font_size: f32 = 11.0;
    const padding: f32 = 8.0;
    const max_w: f32 = @min(420, editor_w - 24);
    const text_w = renderer.Renderer.measureText(@ptrCast(&display_buf), font_size);
    const box_w = @min(max_w, text_w + padding * 2);
    const box_h: f32 = font_size + padding * 2;
    var box_x = wb.hover.anchor_x + 12;
    var box_y = wb.hover.anchor_y - box_h - 8;
    if (box_x + box_w > editor_x + editor_w - 8) box_x = editor_x + editor_w - box_w - 8;
    if (box_x < editor_x + 8) box_x = editor_x + 8;
    if (box_y < 70) box_y = wb.hover.anchor_y + 18;

    renderer.Renderer.drawRect(box_x, box_y, box_w, box_h, .{ .r = 0.14, .g = 0.16, .b = 0.2, .a = 0.98 });
    renderer.Renderer.drawText(@ptrCast(&display_buf), box_x + padding, box_y + padding, font_size, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
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
}

fn drawTaskPanel(wb: *@import("../workbench.zig").Workbench, editor_x: f32, editor_w: f32, panel_y: f32, panel_h: f32) void {
    const bottom_panel = @import("bottom_panel.zig");
    renderer.Renderer.setClipRect(editor_x, panel_y, editor_w, panel_h);
    const tab_y = bottom_panel.tabBarTop(panel_y);
    for (bottom_panel.tabs) |tab| {
        const selected = wb.bottom_panel_mode == tab.mode;
        const bg = if (selected)
            renderer.Color{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 }
        else
            renderer.Color{ .r = 0.16, .g = 0.16, .b = 0.18, .a = 1.0 };
        const tab_x = editor_x + tab.x_offset;
        renderer.Renderer.drawRoundedRect(tab_x, tab_y, tab.w, bottom_panel.tab_h, 4, bg);
        var label_buf: [32:0]u8 = undefined;
        if (tab.mode == .problems) {
            const prob = std.fmt.bufPrint(&label_buf, "PROB {d}", .{wb.diagnostics.list.items.len}) catch tab.label;
            label_buf[prob.len] = 0;
        } else {
            @memcpy(label_buf[0..tab.label.len], tab.label);
            label_buf[tab.label.len] = 0;
        }
        renderer.Renderer.drawText(@ptrCast(&label_buf), tab_x + 8, tab_y + 4, 10.0, .{ .r = 0.75, .g = 0.75, .b = 0.75, .a = 1.0 });
    }

    switch (wb.bottom_panel_mode) {
        .output => {
            const task_state = wb.task_output.snapshotState();
            wb.task_output.lock();
            defer wb.task_output.unlock();
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
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
            wb.terminal.lock();
            defer wb.terminal.unlock();
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            const git_ptr: ?*const @import("../git/status.zig").Status = if (wb.git_status) |*status| status else null;
            const show_cursor = @mod(state.time, 1.0) < 0.5;
            const show_terminal_cursor = show_cursor and wb.focused_panel == .terminal;

            if (wb.terminal_selection) |sel| {
                terminal_panel.drawSelection(editor_x, panel_y, wb.task_scroll_y, wb.terminal.lines.items, sel);
            }
            var line_y = content_top - wb.task_scroll_y;
            for (wb.terminal.lines.items) |line| {
                if (line_y + 14.0 >= content_top and line_y < content_top + content_h) {
                    terminal_panel.drawStyledLine(editor_x, line_y, line, wb.workspace_path, git_ptr);
                }
                line_y += 14.0;
            }
            if (wb.terminal.local_input != null or wb.terminal.isActive()) {
                if (line_y + 14.0 >= content_top and line_y < content_top + content_h) {
                    var active_buf: [512]u8 = undefined;
                    const active = wb.terminal.activeLine(&active_buf);
                    terminal_panel.drawStyledLine(editor_x, line_y, active, wb.workspace_path, git_ptr);
                    const col = active.len;
                    terminal_panel.drawInputCursor(editor_x, line_y, active, col, show_terminal_cursor);
                }
            } else if (wb.terminal.lines.items.len == 0) {
                const hint = if (wb.terminal.isActive())
                    "Shell running — type here."
                else if (wb.terminal.exited)
                    "Shell exited — click TERMINAL tab to restart."
                else
                    "Starting terminal…";
                renderer.Renderer.drawText(hint, editor_x + 20, content_top + 8, 12.0, .{ .r = 0.50, .g = 0.58, .b = 0.68, .a = 1.0 });
            }
            renderer.Renderer.setClipRect(0, 0, 100000, 100000);
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
    }
    renderer.Renderer.clearClipRect();
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

const std = @import("std");
const renderer = @import("forge-renderer");
const core = @import("forge-core");
const telemetry = core.telemetry;
const state = @import("../core/state.zig");
const layout = @import("../core/layout.zig");
const settings_modal = @import("../settings_modal.zig");
const header_toolbar = @import("../chrome/header_toolbar.zig");
const theme_loader = @import("../../theme_loader.zig");
const agent_render = @import("agent.zig");
const chat_markdown = @import("../agent/chat_markdown.zig");
const editor_render = @import("editor.zig");
const sidebar_render = @import("sidebar.zig");
const status_bar_render = @import("status_bar.zig");
const task_panel_render = @import("task_panel.zig");
const outline_panel = @import("../sidebar/outline_panel.zig");
const notifications_render = @import("notifications.zig");
const ai_render = @import("sidebar/ai.zig");

const dialogs = @import("dialogs.zig");
const login_modal = @import("login_modal.zig");

fn c(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return theme_loader.toColor(rgba);
}

fn needsContinuousRendering(wb: anytype) bool {
    if (wb.agent_ui.session.worker_running) return true;
    if (wb.lsp.completions.visible) return true;
    if (wb.palette.open or wb.workspace_symbol_picker.open or wb.git_branch_picker.open or wb.output_channel_picker.open) return true;
    if (wb.agent_panel_visible) {
        wb.agent_ui.session.lock();
        const live = wb.agent_ui.session.stream_live or wb.agent_ui.session.phase == .building_context or wb.agent_ui.session.phase == .sending or wb.agent_ui.session.phase == .streaming or wb.agent_ui.session.phase == .parsing or wb.agent_ui.session.phase == .waiting_approval;
        wb.agent_ui.session.unlock();
        if (live) return true;
    }
    // Caret blink — when the editor (or any text input) has focus, run
    // continuously so the caret blinks at 1.06s period. Without this,
    // the X11 event loop blocks on XNextEvent when idle and the caret
    // freezes between keystrokes.
    //
    // Cost analysis: 60fps × 5-12ms/frame = ~30-60% CPU on a single core
    // at 1080p. This is the same tradeoff VSCode/Sublime make — modern
    // IDEs run their compositor continuously while focused.
    if (wb.focused_panel == .editor or wb.focused_panel == .agent or wb.focused_panel == .palette) {
        return true;
    }
    return false;
}

pub fn onRenderFrame() void {
    const wb = state.wb orelse return;
    const frame_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();

    // Reuse persistent frame arena — reset instead of init/deinit per frame.
    // This avoids the overhead of ArenaAllocator.init + deinit every frame.
    if (!state.frame_arena_inited) {
        state.frame_arena = std.heap.ArenaAllocator.init(wb.allocator);
        state.frame_arena_inited = true;
    }
    var frame_arena = &state.frame_arena.?;
    _ = frame_arena.reset(.retain_capacity);
    const frame_alloc = frame_arena.allocator();

    const editor_buf = wb.activeBuffer();
    const theme = &wb.theme;

    state.time += 0.016;
    var tick_span = telemetry.startSpan("render", "tick");
    const tick_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
    wb.tickFrame(0.016) catch {};
    const tick_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
    tick_span.end();
    theme_loader.applyShellColors(theme.*);

    renderer.Renderer.clearClipRect();

    var w: f32 = 0;
    var h: f32 = 0;
    renderer.Renderer.getWindowSize(&w, &h);

    var layout_span = telemetry.startSpan("render", "layout");
    const layout_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
    const geo = wb.layoutGeometry(w, h);
    wb.clampEditorScroll(geo.editor_w, geo.editor_h);
    wb.clampTabScroll(geo.editor_w);
    wb.clampExplorerScroll(h);
    wb.clampExtensionsScroll(h);
    wb.clampSearchScroll(h);
    wb.clampGitScroll(h);
    wb.clampRunScroll(h);
    if (wb.proposal_review_open) wb.clampProposalReviewScroll(geo.editor_h);
    const side_h = geo.content_h;
    const layout_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
    layout_span.end();

    if (state.root_view) |rv| {
        var draw_span = telemetry.startSpan("render", "draw");
        const draw_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
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
        renderer.Renderer.drawRect(0, layout.header_height, w, 1.5, subtle_border);

        state.perf_sidebar_ms = 0;
        state.perf_editor_ms = 0;
        state.perf_panel_ms = 0;
        state.perf_agent_ms = 0;
        state.perf_status_ms = 0;

        // Always draw all panels every frame. The previous dirty-region
        // skip optimization had a critical bug: g_full_clear_needed was
        // set at end of frame N based on dirty_full, but clearDirty()
        // ran immediately after — so frame N+1 cleared g_pixels but had
        // all dirty=false, drawing nothing. Result: blank panels until
        // hover, text disappearing on scroll.
        //
        // The rendering pipeline is now fast enough (glyph cache first,
        // FT_Set_Pixel_Sizes skip, styled text O(n), SHM direct-write,
        // rounded rect split) that drawing all panels every frame costs
        // <5ms on a 1080p display. Dirty-region skip was a premature
        // optimization that caused more harm than good.
        if (geo.shell_mode == .ide) {
            if (wb.sidebar_visible and geo.explorer_w > 0) {
                var sidebar_span = telemetry.startSpan("render", "sidebar");
                const sidebar_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
                renderer.Renderer.setClipRect(0, layout.header_height, geo.explorer_x + geo.explorer_w, side_h);
                sidebar_render.drawActivityBar(wb, geo.explorer_w, frame_alloc);
                renderer.Renderer.drawRect(geo.explorer_x - 1, layout.header_height, 1, side_h, subtle_border);
                renderer.Renderer.drawRect(geo.editor_x - 1, layout.header_height, 1, side_h, subtle_border);
                switch (wb.sidebar_view) {
                    .explorer => sidebar_render.drawExplorerPanel(wb, geo.explorer_x, geo.explorer_w, h, frame_alloc),
                    .search => sidebar_render.drawSearchPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .git => sidebar_render.drawGitPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .run => sidebar_render.drawDebugPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .extensions => sidebar_render.drawExtensionsPanel(wb, geo.explorer_x, geo.explorer_w, h),
                    .outline => outline_panel.drawOutline(wb, geo.explorer_x, geo.explorer_w, h),
                    .ai => ai_render.drawAiPanel(wb, geo.explorer_x, geo.explorer_w, h),
                }
                renderer.Renderer.clearClipRect();
                const sidebar_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
                state.perf_sidebar_ms = @floatFromInt(sidebar_end_ms - sidebar_start_ms);
                sidebar_span.end();
            }
            {
                var editor_span = telemetry.startSpan("render", "editor");
                const editor_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
                renderer.Renderer.setClipRect(geo.editor_x, layout.header_height, geo.editor_w, geo.editor_h);
                editor_render.drawEditorPanel(wb, editor_buf, geo.editor_x, geo.editor_w, geo.editor_h, w);
                renderer.Renderer.clearClipRect();
                const editor_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
                state.perf_editor_ms = @floatFromInt(editor_end_ms - editor_start_ms);
                editor_span.end();
            }
            if (wb.bottom_panel_visible and geo.task_panel_h > 0) {
                var panel_span = telemetry.startSpan("render", "panel");
                const panel_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
                renderer.Renderer.setClipRect(geo.editor_x, geo.task_panel_y, geo.editor_w, geo.task_panel_h);
                task_panel_render.drawTaskPanel(wb, geo.editor_x, geo.editor_w, geo.task_panel_y, geo.task_panel_h);
                renderer.Renderer.clearClipRect();
                const panel_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
                state.perf_panel_ms = @floatFromInt(panel_end_ms - panel_start_ms);
                panel_span.end();
            }
        }
        if (wb.agent_panel_visible and geo.agent_w > 0) {
            var agent_span = telemetry.startSpan("render", "agent");
            const agent_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
            renderer.Renderer.setClipRect(geo.agent_x, layout.header_height, geo.agent_w, side_h);
            renderer.Renderer.drawRect(geo.agent_x, layout.header_height, geo.agent_w, side_h, .{ .r = 0.055, .g = 0.055, .b = 0.06, .a = 1.0 });
            renderer.Renderer.drawRect(geo.agent_x - 1, layout.header_height, 1, side_h, subtle_border);
            agent_render.drawAgentPanel(wb, geo.agent_x, geo.agent_w, h);
            renderer.Renderer.clearClipRect();
            const agent_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
            state.perf_agent_ms = @floatFromInt(agent_end_ms - agent_start_ms);
            agent_span.end();
        }
        {
            var status_span = telemetry.startSpan("render", "status");
            const status_start_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
            renderer.Renderer.setClipRect(0, h - layout.status_height, w, layout.status_height);
            status_bar_render.drawStatusBar(wb, w, h, geo.shell_mode);
            renderer.Renderer.clearClipRect();
            const status_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
            state.perf_status_ms = @floatFromInt(status_end_ms - status_start_ms);
            status_span.end();
        }
        // P1-4: Toast notifications (bottom-right corner, on top of everything).
        notifications_render.drawNotifications(wb, w, h);
        header_toolbar.drawHoverTooltip(w, wb.headerToolbarState(), state.header_hover_action);

        if (wb.palette.open) dialogs.drawPalette(wb, w, h);
        if (wb.quick_open_open) dialogs.drawQuickOpen(wb, w, h);
        if (wb.workspace_symbol_picker.open) dialogs.drawWorkspaceSymbolPicker(wb, w, h);
        if (wb.git_branch_picker.open) dialogs.drawGitBranchPicker(wb, w, h);
        if (wb.output_channel_picker.open) dialogs.drawOutputChannelPicker(wb, w, h);
        if (wb.focused_panel == .conflict) dialogs.drawConflictDialog(wb, w, h);
        if (wb.focused_panel == .recovery) dialogs.drawRecoveryDialog(wb, w, h);
        if (wb.agent_ui.session.scope_picker_open) agent_render.drawScopePicker(wb, geo.agent_x, geo.agent_w, h);

        // Settings Modal must be drawn last to be on top
        if (wb.settings_modal_open) {
            settings_modal.draw(wb, w, h);
        }

        // Login modal — drawn on top of everything else when user is
        // not authenticated. Blocks interaction with the IDE until
        // the user signs in or skips.
        if (wb.focused_panel == .login) {
            login_modal.drawLoginModal(wb, w, h);
        }

        const draw_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
        state.perf_draw_ms = @floatFromInt(draw_end_ms - draw_start_ms);
        draw_span.end();
    }
    const frame_end_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
    state.perf_tick_ms = @floatFromInt(tick_end_ms - tick_start_ms);
    state.perf_layout_ms = @floatFromInt(layout_end_ms - layout_start_ms);
    state.perf_frame_ms = @floatFromInt(frame_end_ms - frame_start_ms);
    renderer.Renderer.measureTextCacheStats(&state.perf_measure_hits, &state.perf_measure_misses);
    renderer.Renderer.renderStats(&state.perf_redraw_requests, &state.perf_frames);
    chat_markdown.heightCacheStats(&state.perf_markdown_height_hits, &state.perf_markdown_height_misses);
    state.perf_agent_queue_coalesced = wb.agent_ui.ui_queue.coalescedCount();

    // Always full-clear when drawing all panels (which is every frame now).
    // The clear fills g_pixels with the editor background color, then each
    // panel draws its opaque content on top. This is the safe path — the
    // previous "skip clear when not dirty_full" optimization caused a
    // 1-frame off-by-one bug where g_pixels was cleared but no panels drew.
    renderer.backend_c.forge_backend_set_full_clear(1);

    state.clearDirty();

    const continuous = needsContinuousRendering(wb);
    if (state.continuous_rendering_enabled != continuous) {
        state.continuous_rendering_enabled = continuous;
        renderer.Renderer.setContinuousRendering(continuous);
    }

    // Update caret blink scheduler — `setEditorFocused` is a no-op when
    // the state hasn't changed, so calling it every frame is cheap.
    state.setEditorFocused(continuous);

    // Frame timing — log slow frames (>16ms = dropped 60fps frame)
    const frame_duration = frame_end_ms - frame_start_ms;
    state.perf_last_frame_ms = frame_duration;
    if (frame_duration > 16 and state.perf_frame_count % 60 == 0) {
        // Log every 60th slow frame to avoid spam
        std.debug.print("[perf] slow frame: {d}ms (tick={d}ms layout={d}ms)\n", .{
            frame_duration,
            tick_end_ms - tick_start_ms,
            layout_end_ms - layout_start_ms,
        });
    }
    state.perf_frame_count += 1;

    // Perf overlay — drawn last so it appears on top of everything.
    // Enabled via `FORGE_PERF=1` env var. Shows per-panel timings and
    // cache hit rates in the top-right corner so users can diagnose
    // jank without a debugger.
    if (state.perf_overlay_enabled) {
        drawPerfOverlay(w, h);
    }
}

fn drawPerfOverlay(w: f32, h: f32) void {
    const overlay_w: f32 = 280;
    const overlay_h: f32 = 168;
    const x = w - overlay_w - 12;
    const y = 38.0;

    // Background panel — semi-transparent dark for readability.
    renderer.Renderer.drawRect(x, y, overlay_w, overlay_h, .{ .r = 0.05, .g = 0.05, .b = 0.06, .a = 0.92 });
    renderer.Renderer.drawRect(x, y, overlay_w, 1, .{ .r = 0.3, .g = 0.6, .b = 0.95, .a = 1.0 });

    var buf: [256]u8 = undefined;
    const text_color = renderer.Color{ .r = 0.85, .g = 0.9, .b = 0.95, .a = 1.0 };
    const label_color = renderer.Color{ .r = 0.55, .g = 0.6, .b = 0.65, .a = 1.0 };
    const value_color = renderer.Color{ .r = 0.95, .g = 0.85, .b = 0.55, .a = 1.0 };
    const good_color = renderer.Color{ .r = 0.55, .g = 0.95, .b = 0.65, .a = 1.0 };
    const bad_color = renderer.Color{ .r = 0.95, .g = 0.55, .b = 0.55, .a = 1.0 };

    var line_y: f32 = y + 8;
    const line_h: f32 = 14;
    const label_x = x + 10;
    const value_x = x + 110;

    // Title
    renderer.Renderer.drawText("Perf Monitor", label_x, line_y, 11, .{ .r = 0.8, .g = 0.85, .b = 0.95, .a = 1.0 });
    line_y += line_h + 4;

    // Frame time
    {
        const s = std.fmt.bufPrint(&buf, "frame", .{}) catch return;
        renderer.Renderer.drawText(s, label_x, line_y, 11, label_color);
        const v = std.fmt.bufPrint(&buf, "{d:>6.1} ms", .{state.perf_frame_ms}) catch return;
        const vc = if (state.perf_frame_ms > 16.0) bad_color else if (state.perf_frame_ms > 12.0) value_color else good_color;
        renderer.Renderer.drawText(v, value_x, line_y, 11, vc);
        line_y += line_h;
    }
    // Per-panel
    {
        const items = [_]struct { label: []const u8, value: f32 }{
            .{ .label = "tick", .value = state.perf_tick_ms },
            .{ .label = "layout", .value = state.perf_layout_ms },
            .{ .label = "sidebar", .value = state.perf_sidebar_ms },
            .{ .label = "editor", .value = state.perf_editor_ms },
            .{ .label = "agent", .value = state.perf_agent_ms },
            .{ .label = "panel", .value = state.perf_panel_ms },
            .{ .label = "status", .value = state.perf_status_ms },
        };
        for (items) |it| {
            renderer.Renderer.drawText(it.label, label_x, line_y, 11, label_color);
            const v = std.fmt.bufPrint(&buf, "{d:>6.1} ms", .{it.value}) catch return;
            const vc = if (it.value > 5.0) bad_color else if (it.value > 2.0) value_color else good_color;
            renderer.Renderer.drawText(v, value_x, line_y, 11, vc);
            line_y += line_h;
        }
    }

    // Cache hit rate
    line_y += 2;
    const total_lookups = state.perf_measure_hits + state.perf_measure_misses;
    const hit_rate: f32 = if (total_lookups > 0)
        @as(f32, @floatFromInt(state.perf_measure_hits)) / @as(f32, @floatFromInt(total_lookups)) * 100.0
    else
        0.0;
    renderer.Renderer.drawText("text cache", label_x, line_y, 11, label_color);
    const v = std.fmt.bufPrint(&buf, "{d:>5.1}%  ({d})", .{ hit_rate, state.perf_measure_hits }) catch return;
    const vc = if (hit_rate > 95.0) good_color else if (hit_rate > 80.0) value_color else bad_color;
    renderer.Renderer.drawText(v, value_x, line_y, 11, vc);

    _ = h;
    _ = text_color;
}

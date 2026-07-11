const std = @import("std");
const renderer = @import("forge-renderer");
const layout = @import("../core/layout.zig");
const state = @import("../core/state.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn drawStatusBar(wb: *Workbench, w: f32, h: f32, shell_mode: layout.ShellMode) void {
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
    if (state.perf_overlay_enabled) {
        var perf_buf: [320:0]u8 = undefined;
        const measure_total = state.perf_measure_hits + state.perf_measure_misses;
        const hit_pct: u64 = if (measure_total == 0) 0 else (state.perf_measure_hits * 100) / measure_total;
        const md_total = state.perf_markdown_height_hits + state.perf_markdown_height_misses;
        const md_hit_pct: u64 = if (md_total == 0) 0 else (state.perf_markdown_height_hits * 100) / md_total;
        const perf = std.fmt.bufPrint(&perf_buf, "frame {d:.1} tick {d:.1} layout {d:.1} draw {d:.1} | side {d:.1} edit {d:.1} panel {d:.1} ai {d:.1} | text {d}% md {d}% | redraw {d}/{d} q {d}", .{
            state.perf_frame_ms,
            state.perf_tick_ms,
            state.perf_layout_ms,
            state.perf_draw_ms,
            state.perf_sidebar_ms,
            state.perf_editor_ms,
            state.perf_panel_ms,
            state.perf_agent_ms,
            hit_pct,
            md_hit_pct,
            state.perf_redraw_requests,
            state.perf_frames,
            state.perf_agent_queue_coalesced,
        }) catch "";
        perf_buf[perf.len] = 0;
        renderer.Renderer.drawRect(@max(12, w - 860), h - 22, 848, 22, .{ .r = 0.08, .g = 0.08, .b = 0.09, .a = 0.92 });
        renderer.Renderer.drawText(@ptrCast(&perf_buf), @max(20, w - 852), h - 18, 10.5, .{ .r = 0.65, .g = 0.75, .b = 0.9, .a = 1.0 });
    }
}

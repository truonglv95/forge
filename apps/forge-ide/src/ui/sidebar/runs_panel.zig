//! Background runs panel — Antigravity-style run history and active run monitor.
//!
//! Lists all agent runs in the workspace (.forge/sessions/runs/index.jsonl),
//! shows their state (planning/proposed/reviewing/applying/verifying/done/
//! cancelled/failed), and lets the user inspect/cancel/approve runs.
//!
//! This panel is the IDE equivalent of `forge agent runs` +
//! `forge agent wait` + `forge agent cancel`. It reuses `forge-workspace.runs`
//! for all file I/O so the CLI and IDE share the same data format.
//!
//! Active runs (state = planning/proposed/reviewing/applying/verifying)
//! show a live indicator. Completed runs (done/cancelled/failed) show
//! their final state with a colored badge.

const std = @import("std");
const renderer = @import("forge-renderer");
const workspace = @import("forge-workspace");
const theme_mod = @import("../render/theme.zig");
const layout = @import("../core/layout.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub const list_top: f32 = layout.header_height + 32;
pub const row_h: f32 = 32;

/// Hit-test a click in the runs panel. Returns the clicked row index
/// (0 = newest, since runs are displayed newest-first).
pub fn hitTest(panel_x: f32, panel_w: f32, y: f32, scroll_y: f32, item_count: usize) ?usize {
    _ = panel_w;
    _ = panel_x;
    if (y < list_top) return null;
    const rel_y = y - list_top + scroll_y;
    if (rel_y < 0) return null;
    const idx = @as(usize, @intFromFloat(rel_y / row_h));
    if (idx >= item_count) return null;
    return idx;
}

/// Draw the runs panel. Reads runs from the workspace via
/// `workspace.runs.listEntries`.
pub fn drawRunsPanel(wb: *Workbench, panel_x: f32, panel_w: f32, panel_h: f32) void {
    const theme = &wb.theme;
    const font_size = theme.ui_font_size;

    // Background.
    renderer.Renderer.drawRect(panel_x, layout.header_height, panel_w, panel_h - layout.header_height, theme_mod.color(theme.colors.sidebar_bg));

    // Header.
    renderer.Renderer.drawText("RUNS", panel_x + 16, layout.header_height + 8, 11.0, theme_mod.color(theme.colors.text_muted));
    renderer.Renderer.drawText("Agent run history (Antigravity-style)", panel_x + 16, layout.header_height + 20, 10.0, theme_mod.color(theme.colors.text_muted));

    // Load runs from workspace.
    var runs_list = workspace.runs.listEntries(wb.allocator, wb.io, wb.workspace_root) catch {
        renderer.Renderer.drawText("Failed to load runs", panel_x + 16, list_top + 8, font_size, theme_mod.color(theme.colors.text_muted));
        return;
    };
    defer runs_list.deinit();

    // Empty state.
    if (runs_list.items.len == 0) {
        renderer.Renderer.drawText("No runs yet", panel_x + 16, list_top + 8, font_size, theme_mod.color(theme.colors.text_muted));
        renderer.Renderer.drawText("Run an agent task to see", panel_x + 16, list_top + 24, 11.0, theme_mod.color(theme.colors.text_muted));
        renderer.Renderer.drawText("its history here.", panel_x + 16, list_top + 40, 11.0, theme_mod.color(theme.colors.text_muted));
        return;
    }

    // Set clip rect so runs don't overflow into editor.
    renderer.Renderer.setClipRect(panel_x, list_top, panel_w, panel_h - list_top - layout.status_height);

    const scroll_y = wb.runs_scroll_y;
    const items = runs_list.items;

    // Show most recent first (reverse order).
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const idx = items.len - 1 - i;
        const entry = items[idx];
        const y = list_top + @as(f32, @floatFromInt(i)) * row_h - scroll_y;
        if (y + row_h < list_top) continue;
        if (y > panel_h) break;

        const x = panel_x + 16;

        // Row background on hover.
        const is_hover = (i == wb.runs_hover_index);
        if (is_hover) {
            renderer.Renderer.drawRect(panel_x, y, panel_w, row_h, .{ .r = 0.18, .g = 0.20, .b = 0.24, .a = 1.0 });
        }

        // State badge — colored dot indicating run state.
        const is_active = isStateActive(entry.state);
        const state_color = stateColor(entry.state);
        renderer.Renderer.drawRect(x, y + 10, 8, 8, state_color);

        // For active runs, add a pulsing ring (just a brighter dot for now).
        if (is_active) {
            renderer.Renderer.drawRect(x - 2, y + 8, 12, 12, .{ .r = state_color.r, .g = state_color.g, .b = state_color.b, .a = 0.3 });
            renderer.Renderer.drawRect(x, y + 10, 8, 8, state_color);
        }

        // Run ID (truncated).
        var run_id_buf: [40]u8 = undefined;
        const run_id_display = if (entry.run_id.len > 36) blk: {
            const truncated = std.fmt.bufPrint(&run_id_buf, "{s}…", .{entry.run_id[0..35]}) catch entry.run_id;
            break :blk truncated;
        } else entry.run_id;
        renderer.Renderer.drawText(run_id_display, x + 16, y + 6, 12.0, theme_mod.color(theme.colors.text_primary));

        // State label.
        renderer.Renderer.drawText(entry.state, x + 16, y + 20, 10.0, state_color);

        // Timestamp (relative).
        var ts_buf: [40]u8 = undefined;
        const ts_text = formatRelativeTime(&ts_buf, wb.io, entry.timestamp_ms) catch "?";
        renderer.Renderer.drawText(ts_text, panel_x + panel_w - 80, y + 6, 10.0, theme_mod.color(theme.colors.text_muted));

        // Active indicator.
        if (is_active) {
            renderer.Renderer.drawText("● live", panel_x + panel_w - 80, y + 20, 10.0, .{ .r = 0.5, .g = 0.9, .b = 0.6, .a = 1.0 });
        }
    }

    renderer.Renderer.clearClipRect();

    // Footer: count + active count + hint.
    const footer_y = panel_h - layout.status_height - 24;
    var active_count: usize = 0;
    for (items) |entry| if (isStateActive(entry.state)) {
        active_count += 1;
    };
    var count_buf: [80]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d} run{s} ({d} active)", .{ items.len, if (items.len == 1) "" else "s", active_count }) catch "runs";
    renderer.Renderer.drawText(count_text, panel_x + 16, footer_y, 10.0, theme_mod.color(theme.colors.text_muted));
    renderer.Renderer.drawText("'forge agent runs' CLI for full control", panel_x + 16, footer_y + 12, 10.0, theme_mod.color(theme.colors.text_muted));
}

fn isStateActive(state: []const u8) bool {
    return std.mem.eql(u8, state, "planning") or
        std.mem.eql(u8, state, "proposed") or
        std.mem.eql(u8, state, "reviewing") or
        std.mem.eql(u8, state, "applying") or
        std.mem.eql(u8, state, "verifying");
}

fn stateColor(state: []const u8) renderer.Color {
    if (std.mem.eql(u8, state, "done")) return .{ .r = 0.40, .g = 0.80, .b = 0.45, .a = 1.0 }; // green
    if (std.mem.eql(u8, state, "failed")) return .{ .r = 0.85, .g = 0.40, .b = 0.40, .a = 1.0 }; // red
    if (std.mem.eql(u8, state, "cancelled")) return .{ .r = 0.55, .g = 0.55, .b = 0.60, .a = 1.0 }; // gray
    if (isStateActive(state)) return .{ .r = 0.85, .g = 0.65, .b = 0.30, .a = 1.0 }; // amber (active)
    return .{ .r = 0.65, .g = 0.65, .b = 0.70, .a = 1.0 }; // default gray
}

fn formatRelativeTime(buf: []u8, io: std.Io, timestamp_ms: i64) ![]const u8 {
    // Use wall clock via std.Io.Timestamp for accurate "X ago" display.
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const delta_ms = now_ms - timestamp_ms;
    if (delta_ms < 0) return "just now";
    if (delta_ms < 60 * 1000) return std.fmt.bufPrint(buf, "{d}s ago", .{@divFloor(delta_ms, 1000)});
    if (delta_ms < 60 * 60 * 1000) return std.fmt.bufPrint(buf, "{d}m ago", .{@divFloor(delta_ms, 60 * 1000)});
    if (delta_ms < 24 * 60 * 60 * 1000) return std.fmt.bufPrint(buf, "{d}h ago", .{@divFloor(delta_ms, 60 * 60 * 1000)});
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divFloor(delta_ms, 24 * 60 * 60 * 1000)});
}

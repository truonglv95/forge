//! Spec-driven development panel — Kiro-style spec management in the IDE.
//!
//! Lists all specs in the workspace (.forge/sessions/specs/<run_id>/), shows
//! their status (pending/approved/rejected/implemented), and lets the user
//! open the spec files (requirements.md, design.md, tasks.md) for editing.
//!
//! This panel is the IDE equivalent of `forge spec list` + `forge spec show`.
//! It reuses `forge-ai.spec_writer` for all file I/O so the CLI and IDE
//! share the same data format.
//!
//! Future: integrate with agent context (Gap #2 from AI_FEATURE_AUDIT_2026.md)
//! so when a spec exists for the current intent, the agent automatically
//! injects requirements + design + tasks into the context builder.

const std = @import("std");
const renderer = @import("forge-renderer");
const ai = @import("forge-ai");
const theme_mod = @import("../render/theme.zig");
const layout = @import("../core/layout.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub const list_top: f32 = layout.header_height + 32;
pub const row_h: f32 = 28;
pub const header_h: f32 = 24;

pub const Hit = union(enum) {
    none,
    select_spec: usize,
    open_requirements: usize,
    open_design: usize,
    open_tasks: usize,
    approve: usize,
    reject: usize,
};

/// Returns the screen-space rectangle for a spec row.
pub fn rowRect(panel_x: f32, panel_w: f32, index: usize, scroll_y: f32) struct { x: f32, y: f32, w: f32, h: f32 } {
    const y = list_top + @as(f32, @floatFromInt(index)) * row_h - scroll_y;
    return .{
        .x = panel_x,
        .y = y,
        .w = panel_w,
        .h = row_h,
    };
}

/// Hit-test a click in the spec panel.
pub fn hitTest(panel_x: f32, panel_w: f32, y: f32, scroll_y: f32, item_count: usize) ?usize {
    _ = panel_w;
    if (y < list_top) return null;
    const rel_y = y - list_top + scroll_y;
    if (rel_y < 0) return null;
    const idx = @as(usize, @intFromFloat(rel_y / row_h));
    if (idx >= item_count) return null;
    if (panel_x < 0) return null;
    return idx;
}

/// Draw the spec panel. Reads specs from the workspace via `ai.spec_writer`.
pub fn drawSpecsPanel(wb: *Workbench, panel_x: f32, panel_w: f32, panel_h: f32) void {
    const theme = &wb.theme;
    const font_size = theme.ui_font_size;

    // Background.
    renderer.Renderer.drawRect(panel_x, layout.header_height, panel_w, panel_h - layout.header_height, theme_mod.color(theme.colors.sidebar_bg));

    // Header.
    renderer.Renderer.drawText("SPECS", panel_x + 16, layout.header_height + 8, 11.0, theme_mod.color(theme.colors.text_muted));
    renderer.Renderer.drawText("Kiro-style spec-driven dev", panel_x + 16, layout.header_height + 20, 10.0, theme_mod.color(theme.colors.text_muted));

    // Load specs from workspace. This is called every frame for simplicity —
    // in the future we should cache and refresh on workspace change.
    const specs: []ai.spec_writer.SpecInfo = ai.spec_writer.listSpecs(wb.allocator, wb.io, wb.workspace_root) catch {
        renderer.Renderer.drawText("Failed to load specs", panel_x + 16, list_top + 8, font_size, theme_mod.color(theme.colors.text_muted));
        return;
    };
    defer ai.spec_writer.freeSpecList(wb.allocator, specs);

    // Empty state.
    if (specs.len == 0) {
        renderer.Renderer.drawText("No specs yet", panel_x + 16, list_top + 8, font_size, theme_mod.color(theme.colors.text_muted));
        renderer.Renderer.drawText("Run an agent task to generate", panel_x + 16, list_top + 24, 11.0, theme_mod.color(theme.colors.text_muted));
        renderer.Renderer.drawText("a spec, or use 'forge spec init'", panel_x + 16, list_top + 40, 11.0, theme_mod.color(theme.colors.text_muted));
        return;
    }

    // Set clip rect so specs don't overflow into editor.
    renderer.Renderer.setClipRect(panel_x, list_top, panel_w, panel_h - list_top - layout.status_height);

    const scroll_y = wb.spec_scroll_y;

    for (specs, 0..) |spec, i| {
        const y = list_top + @as(f32, @floatFromInt(i)) * row_h - scroll_y;
        if (y + row_h < list_top) continue;
        if (y > panel_h) break;

        const x = panel_x + 16;

        // Row background on hover.
        const is_hover = (i == wb.spec_hover_index);
        if (is_hover) {
            renderer.Renderer.drawRect(panel_x, y, panel_w, row_h, .{ .r = 0.18, .g = 0.20, .b = 0.24, .a = 1.0 });
        }

        // Status badge (colored dot).
        const status_color = switch (spec.status) {
            .pending => renderer.Color{ .r = 0.85, .g = 0.65, .b = 0.30, .a = 1.0 }, // amber
            .approved => renderer.Color{ .r = 0.40, .g = 0.80, .b = 0.45, .a = 1.0 }, // green
            .rejected => renderer.Color{ .r = 0.85, .g = 0.40, .b = 0.40, .a = 1.0 }, // red
            .implemented => renderer.Color{ .r = 0.45, .g = 0.65, .b = 0.95, .a = 1.0 }, // blue
        };
        renderer.Renderer.drawRect(x, y + 9, 8, 8, status_color);

        // Spec run_id (truncated).
        var run_id_buf: [40]u8 = undefined;
        const run_id_display = if (spec.run_id.len > 36) blk: {
            const truncated = std.fmt.bufPrint(&run_id_buf, "{s}…", .{spec.run_id[0..35]}) catch spec.run_id;
            break :blk truncated;
        } else spec.run_id;
        renderer.Renderer.drawText(run_id_display, x + 16, y + 6, 12.0, theme_mod.color(theme.colors.text_primary));

        // Status label.
        const status_label = spec.status.label();
        renderer.Renderer.drawText(status_label, x + 16, y + 18, 10.0, theme_mod.color(theme.colors.text_muted));

        // File availability indicators (R/D/T).
        const file_indicators_x = panel_x + panel_w - 80;
        var indicator_buf: [16]u8 = undefined;
        const r_marker: []const u8 = if (spec.has_requirements) "R" else "-";
        const d_marker: []const u8 = if (spec.has_design) "D" else "-";
        const t_marker: []const u8 = if (spec.has_tasks) "T" else "-";
        const indicators = std.fmt.bufPrint(&indicator_buf, "{s} {s} {s}", .{ r_marker, d_marker, t_marker }) catch "R D T";
        const indicator_color = if (spec.has_requirements and spec.has_design and spec.has_tasks)
            theme_mod.color(theme.colors.text_primary)
        else
            theme_mod.color(theme.colors.text_muted);
        renderer.Renderer.drawText(indicators, file_indicators_x, y + 6, 11.0, indicator_color);

        // Intent (if any) on second line.
        if (spec.intent.len > 0) {
            var intent_buf: [60]u8 = undefined;
            const intent_display = if (spec.intent.len > 56) blk: {
                const truncated = std.fmt.bufPrint(&intent_buf, "{s}…", .{spec.intent[0..55]}) catch spec.intent;
                break :blk truncated;
            } else spec.intent;
            renderer.Renderer.drawText(intent_display, file_indicators_x, y + 18, 10.0, theme_mod.color(theme.colors.text_muted));
        }
    }

    renderer.Renderer.clearClipRect();

    // Footer: count + hint.
    const footer_y = panel_h - layout.status_height - 24;
    var count_buf: [64]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d} spec{s}", .{ specs.len, if (specs.len == 1) "" else "s" }) catch "specs";
    renderer.Renderer.drawText(count_text, panel_x + 16, footer_y, 10.0, theme_mod.color(theme.colors.text_muted));
    renderer.Renderer.drawText("Click to open · 'forge spec' CLI for full workflow", panel_x + 16, footer_y + 12, 10.0, theme_mod.color(theme.colors.text_muted));
}

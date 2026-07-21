const std = @import("std");
const renderer = @import("forge-renderer");
const mcp_capability = @import("forge-ai").mcp_capability;
const Workbench = @import("../../../workbench.zig").Workbench;

const layout = @import("../../core/layout.zig");
const scroll_region = @import("../../core/scroll_region.zig");
const scrollbar = @import("../../core/scrollbar.zig");
const shared = @import("shared.zig");
const theme_loader = @import("../../../theme_loader.zig");
const commands = @import("../../../workbench/commands.zig");

const ui_text_style = renderer.TextStyle.prose;
const ui_strong_style = renderer.TextStyle.prose_semibold;

const panel_top: f32 = layout.header_height + layout.activity_bar_height;
const header_h: f32 = 42;
const inset: f32 = 14;
const card_gap: f32 = 10;
const action_h: f32 = 28;
const status_card_h: f32 = 96;
const timeline_card_h: f32 = 142;
const section_h: f32 = 32;
const tool_row_h: f32 = 58;

pub const Hit = union(enum) {
    open_settings,
    open_mcp_config,
    toggle_mcp,
    refresh_mcp,
};

fn viewportHeight(h: f32) f32 {
    return @max(0, h - panel_top - layout.status_height - header_h);
}

fn contentHeight(wb: *const Workbench) f32 {
    const tool_count = if (wb.ai_mcp_registry) |reg| reg.tools.len else 0;
    const tool_h = if (tool_count == 0) 48.0 else @as(f32, @floatFromInt(tool_count)) * tool_row_h;
    return toolsTopOffset() + tool_h + card_gap;
}

fn toolsTopOffset() f32 {
    return card_gap + status_card_h + card_gap + action_h + 8 + action_h + card_gap + timeline_card_h + card_gap + 4 + section_h;
}

pub fn maxScrollY(wb: *const Workbench, h: f32) f32 {
    return scroll_region.region(contentHeight(wb), viewportHeight(h)).maxScrollY();
}

pub fn clampScrollY(wb: *const Workbench, scroll_y: f32, h: f32) f32 {
    return scroll_region.region(contentHeight(wb), viewportHeight(h)).clamp(scroll_y);
}

fn actionRects(start_x: f32, w: f32, h: f32, scroll_y: f32) struct {
    open_settings: struct { x: f32, y: f32, w: f32, h: f32 },
    open_mcp_config: struct { x: f32, y: f32, w: f32, h: f32 },
    toggle_mcp: struct { x: f32, y: f32, w: f32, h: f32 },
    refresh_mcp: struct { x: f32, y: f32, w: f32, h: f32 },
} {
    _ = h;
    const content_x = start_x + inset;
    const content_w = w - inset * 2;
    const action_w = (content_w - 8) / 2;
    var y = panel_top + header_h + card_gap - scroll_y;
    y += status_card_h + card_gap;
    const row1 = y;
    y += action_h + 8;
    const row2 = y;
    return .{
        .open_settings = .{ .x = content_x, .y = row1, .w = action_w, .h = action_h },
        .open_mcp_config = .{ .x = content_x + action_w + 8, .y = row1, .w = action_w, .h = action_h },
        .toggle_mcp = .{ .x = content_x, .y = row2, .w = action_w, .h = action_h },
        .refresh_mcp = .{ .x = content_x + action_w + 8, .y = row2, .w = action_w, .h = action_h },
    };
}

fn inRect(px: f32, py: f32, r: anytype) bool {
    return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h;
}

pub fn hitTest(start_x: f32, w: f32, h: f32, scroll_y: f32, px: f32, py: f32) ?Hit {
    if (px < start_x or px > start_x + w or py < panel_top or py > h - layout.status_height) return null;
    const rects = actionRects(start_x, w, h, scroll_y);
    if (inRect(px, py, rects.open_settings)) return .open_settings;
    if (inRect(px, py, rects.open_mcp_config)) return .open_mcp_config;
    if (inRect(px, py, rects.toggle_mcp)) return .toggle_mcp;
    if (inRect(px, py, rects.refresh_mcp)) return .refresh_mcp;
    return null;
}

pub fn commandForHit(hit: Hit) commands.Command {
    return switch (hit) {
        .open_settings => .open_settings_modal,
        .open_mcp_config => .ai_open_mcp_config,
        .toggle_mcp => .ai_toggle_mcp,
        .refresh_mcp => .ai_refresh_mcp,
    };
}

fn drawUiText(text: []const u8, x: f32, y: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.drawTextWithStyle(text, x, @round(y), size, c, ui_text_style);
}

fn drawStrongText(text: []const u8, x: f32, y: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.drawTextWithStyle(text, x, @round(y), size, c, ui_strong_style);
}

fn drawClippedText(text: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, color: renderer.Color, strong: bool) void {
    renderer.Renderer.pushClipRect(x, y - 2, @max(0, w), h);
    if (strong) {
        drawStrongText(text, x, y, size, color);
    } else {
        drawUiText(text, x, y, size, color);
    }
    renderer.Renderer.popClipRect();
}

fn drawAction(label: []const u8, x: f32, y: f32, w: f32, active: bool, theme: anytype) void {
    const bg = if (active)
        shared.color(theme.colors.accent_soft)
    else
        renderer.Color{ .r = 0.18, .g = 0.19, .b = 0.22, .a = 1.0 };
    const fg = if (active)
        renderer.Color{ .r = 0.92, .g = 0.94, .b = 0.98, .a = 1.0 }
    else
        renderer.Color{ .r = 0.72, .g = 0.73, .b = 0.77, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(x, y, w, action_h, 5, bg);
    drawClippedText(label, x + 10, y + 7, w - 20, action_h - 8, 11.0, fg, active);
}

fn drawStatusCard(wb: *Workbench, x: f32, y: f32, w: f32) void {
    const theme = &wb.theme;
    renderer.Renderer.drawRoundedRect(x, y, w, status_card_h, 6, .{ .r = 0.13, .g = 0.14, .b = 0.16, .a = 1.0 });
    renderer.Renderer.drawRoundedRect(x, y, w, 1.0, 0, theme_loader.toColor(theme.colors.border));

    const enabled_text = if (wb.agent_ui.mcp_enabled) "MCP tools enabled" else "MCP tools disabled";
    const enabled_color = if (wb.agent_ui.mcp_enabled)
        theme_loader.toColor(theme.colors.diff_add)
    else
        theme_loader.toColor(theme.colors.text_muted);
    drawStrongText(enabled_text, x + 12, y + 11, 12.0, enabled_color);

    const status = wb.ai_mcp_status orelse "Registry not checked";
    drawClippedText(status, x + 12, y + 33, w - 24, 18, 10.5, theme_loader.toColor(theme.colors.text_muted), false);

    var status_buf: [96]u8 = undefined;
    var provider_buf: [96]u8 = undefined;
    const snap = wb.agent_ui.session.snapshot(&status_buf, &provider_buf);
    var agent_buf: [192]u8 = undefined;
    const agent_text = std.fmt.bufPrint(
        &agent_buf,
        "Agent {s} · {d}/{d} context · {d} runs",
        .{ @tagName(snap.phase), snap.context_used_bytes, snap.context_max_bytes, snap.run_count },
    ) catch "Agent timeline unavailable";
    drawClippedText(agent_text, x + 12, y + 51, w - 24, 18, 10.5, theme_loader.toColor(theme.colors.text_muted), false);

    const registry_text = if (wb.ai_mcp_registry) |reg| blk: {
        var buf: [64]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, "{d} tools registered", .{reg.tools.len}) catch "Registry loaded";
    } else "Registry not loaded";
    drawClippedText(registry_text, x + 12, y + 69, w - 24, 18, 10.5, theme_loader.toColor(theme.colors.text_muted), false);
}

fn drawTimelineDot(x: f32, y: f32, active: bool, theme: anytype) void {
    const c = if (active) theme_loader.toColor(theme.colors.accent) else theme_loader.toColor(theme.colors.text_muted);
    renderer.Renderer.drawRoundedRect(x, y, 7, 7, 4, c);
}

fn drawTimelineCard(wb: *Workbench, x: f32, y: f32, w: f32) void {
    const theme = &wb.theme;
    renderer.Renderer.drawRoundedRect(x, y, w, timeline_card_h, 6, .{ .r = 0.12, .g = 0.13, .b = 0.15, .a = 1.0 });
    renderer.Renderer.drawRoundedRect(x, y, w, 1.0, 0, theme_loader.toColor(theme.colors.border));

    var status_buf: [128]u8 = undefined;
    var provider_buf: [96]u8 = undefined;
    const snap = wb.agent_ui.session.snapshot(&status_buf, &provider_buf);
    drawStrongText("AI RUN TIMELINE", x + 12, y + 10, 11.0, theme_loader.toColor(theme.colors.text_muted));

    var phase_buf: [192]u8 = undefined;
    const phase_text = std.fmt.bufPrint(
        &phase_buf,
        "{s} · {s}",
        .{ @tagName(snap.phase), if (snap.status_line.len > 0) snap.status_line else "idle" },
    ) catch @tagName(snap.phase);
    drawTimelineDot(x + 14, y + 34, snap.worker_running, theme);
    drawClippedText(phase_text, x + 28, y + 29, w - 40, 18, 10.5, theme_loader.toColor(theme.colors.text_primary), false);

    var metrics_buf: [192]u8 = undefined;
    const metrics_text = std.fmt.bufPrint(
        &metrics_buf,
        "{d} context entries · {d} stream bytes · {d} thinking bytes",
        .{ snap.context_entry_count, snap.stream_len, snap.thinking_len },
    ) catch "Run metrics unavailable";
    drawTimelineDot(x + 14, y + 54, snap.context_entry_count > 0, theme);
    drawClippedText(metrics_text, x + 28, y + 49, w - 40, 18, 10.5, theme_loader.toColor(theme.colors.text_muted), false);

    const approval_text = if (snap.approval_pending)
        "Waiting for tool approval"
    else if (snap.show_review)
        "Proposal review ready"
    else if (snap.validation_failed)
        "Validation failed"
    else
        "No approval pending";
    drawTimelineDot(x + 14, y + 74, snap.approval_pending or snap.show_review, theme);
    drawClippedText(approval_text, x + 28, y + 69, w - 40, 18, 10.5, theme_loader.toColor(theme.colors.text_muted), false);

    wb.agent_ui.session.lock();
    defer wb.agent_ui.session.unlock();
    const steps = wb.agent_ui.session.agent_steps.items;
    const start = if (steps.len > 3) steps.len - 3 else 0;
    var line_y = y + 94;
    var i = start;
    while (i < steps.len) : (i += 1) {
        const step = steps[i];
        if (step.parent_index != null and step.summary.len == 0) continue;
        const active = step.running;
        drawTimelineDot(x + 14, line_y + 5, active, theme);
        var step_buf: [192]u8 = undefined;
        const label = if (step.summary.len > 0) step.summary else step.kind;
        const step_text = std.fmt.bufPrint(&step_buf, "{s}: {s}", .{ step.kind, label }) catch label;
        drawClippedText(step_text, x + 28, line_y, w - 40, 16, 10.0, theme_loader.toColor(theme.colors.text_muted), false);
        line_y += 16;
    }
}

fn drawRiskPill(label: []const u8, x: f32, y: f32, color: renderer.Color) void {
    const pill_w = renderer.Renderer.measureTextWithStyle(label, 9.5, ui_strong_style) + 12;
    renderer.Renderer.drawRoundedRect(x, y, pill_w, 18, 9, .{ .r = color.r, .g = color.g, .b = color.b, .a = 0.18 });
    drawStrongText(label, x + 6, y + 4, 9.5, color);
}

fn drawToolRow(server_name: []const u8, tool_name: []const u8, annotations_json: ?[]const u8, x: f32, y: f32, w: f32, theme: anytype) void {
    const policy = mcp_capability.inferPolicy(annotations_json);
    renderer.Renderer.drawRoundedRect(x + 6, y, w - 12, tool_row_h - 7, 5, shared.color(theme.colors.selection));

    const risk_color = switch (policy.risk) {
        .low => theme_loader.toColor(theme.colors.diff_add),
        .medium => renderer.Color{ .r = 0.86, .g = 0.67, .b = 0.34, .a = 1.0 },
        .high => theme_loader.toColor(theme.colors.diff_remove),
    };
    const risk_label = switch (policy.risk) {
        .low => "Low",
        .medium => "Medium",
        .high => "High",
    };
    const cap_label = switch (policy.capability) {
        .read_only => "Read-only",
        .mutate => "Mutate",
        .unknown => "Unknown",
    };

    var title_buf: [192]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s}/{s}", .{ server_name, tool_name }) catch tool_name;
    drawClippedText(title, x + 16, y + 8, w - 32, 18, 12.0, theme_loader.toColor(theme.colors.text_primary), true);
    drawClippedText(cap_label, x + 16, y + 30, w - 112, 16, 10.5, theme_loader.toColor(theme.colors.text_muted), false);
    drawRiskPill(risk_label, x + w - 82, y + 28, risk_color);
}

pub fn drawAiPanel(wb: *Workbench, start_x: f32, w: f32, h: f32) void {
    const theme = &wb.theme;
    const panel_h = h - panel_top - layout.status_height;
    renderer.Renderer.setClipRect(start_x, panel_top, w, panel_h);

    const icon_c = renderer.Color{ .r = 0.64, .g = 0.65, .b = 0.68, .a = 1.0 };
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, start_x + 8, panel_top + 12, 16, 16, icon_c);
    drawStrongText("AI & MCP", start_x + 28, panel_top + 13, 11.5, theme_loader.toColor(theme.colors.text_primary));
    renderer.Renderer.drawSvg(renderer.icons.sync, start_x + w - 56, panel_top + 11, 16, 16, icon_c);
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, start_x + w - 30, panel_top + 11, 16, 16, icon_c);
    renderer.Renderer.drawRect(start_x, panel_top + header_h, w, 1, theme_loader.toColor(theme.colors.border));

    wb.ai_mcp_scroll_y = clampScrollY(wb, wb.ai_mcp_scroll_y, h);
    var cy = panel_top + header_h + card_gap - wb.ai_mcp_scroll_y;
    const content_x = start_x + inset;
    const content_w = w - inset * 2;

    renderer.Renderer.setClipRect(start_x, panel_top + header_h, w, viewportHeight(h));
    drawStatusCard(wb, content_x, cy, content_w);
    cy += status_card_h + card_gap;

    const action_w = (content_w - 8) / 2;
    drawAction("Open settings", content_x, cy, action_w, false, theme);
    drawAction("Open MCP config", content_x + action_w + 8, cy, action_w, false, theme);
    cy += action_h + 8;
    drawAction(if (wb.agent_ui.mcp_enabled) "Disable MCP" else "Enable MCP", content_x, cy, action_w, wb.agent_ui.mcp_enabled, theme);
    drawAction("Refresh registry", content_x + action_w + 8, cy, action_w, false, theme);
    cy += action_h + card_gap;

    drawTimelineCard(wb, content_x, cy, content_w);
    cy += timeline_card_h + card_gap + 4;

    if (wb.ai_mcp_registry) |reg| {
        renderer.Renderer.drawSvg(renderer.icons.chevron_down, start_x + 8, cy + 4, 16, 16, icon_c);
        drawStrongText("MCP AUDIT LOG", start_x + 28, cy + 6, 11.0, theme_loader.toColor(theme.colors.text_muted));
        cy += section_h;

        if (reg.tools.len == 0) {
            drawUiText("No MCP tools registered.", content_x, cy + 8, 11.5, theme_loader.toColor(theme.colors.text_muted));
        } else {
            const row_scroll = @max(0, wb.ai_mcp_scroll_y - toolsTopOffset());
            const range = scroll_region.region(@as(f32, @floatFromInt(reg.tools.len)) * tool_row_h, viewportHeight(h)).visibleRange(row_scroll, tool_row_h, reg.tools.len);
            cy += @as(f32, @floatFromInt(range.first)) * tool_row_h;
            var i = range.first;
            while (i < range.last) : (i += 1) {
                const tool = reg.tools[i];
                if (cy + tool_row_h >= panel_top + header_h and cy < h - layout.status_height) {
                    drawToolRow(tool.server_name, tool.tool_name, tool.annotations_json, start_x, cy, w, theme);
                }
                cy += tool_row_h;
            }
        }
    } else {
        drawUiText("MCP Registry not loaded.", content_x, cy + 8, 11.5, theme_loader.toColor(theme.colors.text_muted));
        drawUiText("Refresh registry or open .mcp.json to configure tools.", content_x, cy + 28, 10.5, theme_loader.toColor(theme.colors.text_muted));
    }

    renderer.Renderer.clearClipRect();
    const region = scroll_region.region(contentHeight(wb), viewportHeight(h));
    if (region.maxScrollY() > 0) {
        const show = scrollbar.hovered(stateMouseX(), stateMouseY(), start_x, panel_top + header_h, w, region.viewport_h);
        scrollbar.drawVertical(
            start_x + w - scrollbar.track_w - 2,
            panel_top + header_h,
            region.viewport_h,
            wb.ai_mcp_scroll_y,
            region.maxScrollY(),
            region.content_h,
            region.viewport_h,
            show,
        );
    }
}

fn stateMouseX() f32 {
    return @import("../../core/state.zig").last_mouse_x;
}

fn stateMouseY() f32 {
    return @import("../../core/state.zig").last_mouse_y;
}

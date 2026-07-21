const std = @import("std");
const renderer = @import("forge-renderer");
const mcp_capability = @import("forge-ai").mcp_capability;
const Workbench = @import("../../../workbench.zig").Workbench;

const layout = @import("../../core/layout.zig");
const shared = @import("shared.zig");
const theme_loader = @import("../../../theme_loader.zig");

const ui_text_style = renderer.TextStyle.prose;
const ui_strong_style = renderer.TextStyle.prose_semibold;

const panel_top: f32 = layout.header_height + layout.activity_bar_height;
const header_h: f32 = 42;
const inset: f32 = 14;
const card_gap: f32 = 10;
const action_h: f32 = 28;
const status_card_h: f32 = 74;
const section_h: f32 = 32;
const tool_row_h: f32 = 58;

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

    const registry_text = if (wb.ai_mcp_registry) |reg| blk: {
        var buf: [64]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, "{d} tools registered", .{reg.tools.len}) catch "Registry loaded";
    } else "Registry not loaded";
    drawClippedText(registry_text, x + 12, y + 51, w - 24, 18, 10.5, theme_loader.toColor(theme.colors.text_muted), false);
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

    var cy = panel_top + header_h + card_gap;
    const content_x = start_x + inset;
    const content_w = w - inset * 2;

    drawStatusCard(wb, content_x, cy, content_w);
    cy += status_card_h + card_gap;

    const action_w = (content_w - 8) / 2;
    drawAction("Open settings", content_x, cy, action_w, false, theme);
    drawAction("Open MCP config", content_x + action_w + 8, cy, action_w, false, theme);
    cy += action_h + 8;
    drawAction(if (wb.agent_ui.mcp_enabled) "Disable MCP" else "Enable MCP", content_x, cy, action_w, wb.agent_ui.mcp_enabled, theme);
    drawAction("Refresh registry", content_x + action_w + 8, cy, action_w, false, theme);
    cy += action_h + card_gap + 4;

    renderer.Renderer.setClipRect(start_x, cy, w, h - cy - layout.status_height);
    if (wb.ai_mcp_registry) |reg| {
        renderer.Renderer.drawSvg(renderer.icons.chevron_down, start_x + 8, cy + 4, 16, 16, icon_c);
        drawStrongText("MCP AUDIT LOG", start_x + 28, cy + 6, 11.0, theme_loader.toColor(theme.colors.text_muted));
        cy += section_h;

        if (reg.tools.len == 0) {
            drawUiText("No MCP tools registered.", content_x, cy + 8, 11.5, theme_loader.toColor(theme.colors.text_muted));
        } else {
            for (reg.tools) |tool| {
                if (cy + tool_row_h >= panel_top and cy < h - layout.status_height) {
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
}

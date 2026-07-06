const std = @import("std");
const renderer = @import("forge-renderer");
const workspace = @import("forge-workspace");
const layout = @import("layout.zig");
const tabs_ui = @import("tabs.zig");
const scrollbar = @import("scrollbar.zig");
const state = @import("state.zig");

fn color(rgba: workspace.Rgba) renderer.Color {
    return .{ .r = rgba.r, .g = rgba.g, .b = rgba.b, .a = rgba.a };
}

pub const row_h: f32 = 28;
pub const action_h: f32 = 36;
pub const status_line_h: f32 = 16;
pub const h_pad: f32 = 32;
pub const content_inset: f32 = 24;
pub const max_content_w: f32 = 720;
pub const tab_label = "AI Settings";

pub const Hit = union(enum) {
    toggle_mcp,
    open_forge_toml,
    open_mcp_json,
    refresh_mcp,
    close_tab,
};

pub fn contentTop() f32 {
    return tabs_ui.tab_bar_top + tabs_ui.tab_bar_height;
}

pub fn viewportHeight(editor_h: f32) f32 {
    return @max(0, editor_h - tabs_ui.tab_bar_height);
}

pub fn contentHeight(status_line_count: usize) f32 {
    return 56 + 20 + 3 * row_h + 24 + 3 * action_h + 32 + 20 +
        @as(f32, @floatFromInt(status_line_count)) * status_line_h + 40;
}

pub fn maxScrollY(editor_h: f32, status_line_count: usize) f32 {
    return @max(0, contentHeight(status_line_count) - viewportHeight(editor_h));
}

pub fn clampScrollY(scroll_y: f32, editor_h: f32, status_line_count: usize) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(editor_h, status_line_count));
}

pub fn tabLayout(editor_x: f32) struct { x: f32, w: f32, close_x: f32, close_y: f32 } {
    const w = tabs_ui.tabWidth(tab_label.len);
    const x = editor_x + tabs_ui.tab_padding_start;
    return .{
        .x = x,
        .w = w,
        .close_x = x + w - tabs_ui.close_button_width + 2,
        .close_y = tabs_ui.tab_y + 10,
    };
}

pub fn hitCloseTab(editor_x: f32, px: f32, py: f32) bool {
    const tab = tabLayout(editor_x);
    return px >= tab.close_x and px < tab.close_x + 16 and py >= tab.close_y and py < tab.close_y + 16;
}

fn countStatusLines(status: ?[]const u8) usize {
    const text = status orelse return 1;
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

pub fn hitTest(
    scroll_y: f32,
    click_y: f32,
) ?Hit {
    if (click_y < contentTop()) return null;

    const local_y = click_y - contentTop() + scroll_y - content_inset;
    if (local_y < 56 + 20) return null;

    var cy: f32 = 56 + 20;
    cy += row_h; // provider
    cy += row_h; // model
    if (local_y >= cy and local_y < cy + row_h) return .toggle_mcp;
    cy += row_h + 24;

    if (local_y >= cy and local_y < cy + action_h) return .open_forge_toml;
    cy += action_h;
    if (local_y >= cy and local_y < cy + action_h) return .open_mcp_json;
    cy += action_h;
    if (local_y >= cy and local_y < cy + action_h) return .refresh_mcp;
    return null;
}

pub fn hitTestPoint(
    editor_x: f32,
    scroll_y: f32,
    px: f32,
    py: f32,
) ?Hit {
    if (py >= tabs_ui.tab_bar_top and py < contentTop() and hitCloseTab(editor_x, px, py)) {
        return .close_tab;
    }
    return hitTest(scroll_y, py);
}

pub fn drawTab(
    editor_x: f32,
    editor_w: f32,
    accent: renderer.Color,
    editor_bg: renderer.Color,
    border: renderer.Color,
    text_primary: renderer.Color,
    ui_size: f32,
) void {
    const tab = tabLayout(editor_x);
    renderer.Renderer.drawRect(editor_x, tabs_ui.tab_bar_top, editor_w, tabs_ui.tab_bar_height, editor_bg);
    renderer.Renderer.drawRect(editor_x, tabs_ui.tab_bar_top + tabs_ui.tab_bar_height - 1, editor_w, 1, border);

    renderer.Renderer.drawRect(tab.x, tabs_ui.tab_y, tab.w, tabs_ui.tab_height + 1, editor_bg);
    renderer.Renderer.drawRect(tab.x, tabs_ui.tab_y, tab.w, 1, border);
    renderer.Renderer.drawRect(tab.x, tabs_ui.tab_y, 1, tabs_ui.tab_height, border);
    renderer.Renderer.drawRect(tab.x + tab.w - 1, tabs_ui.tab_y, 1, tabs_ui.tab_height, border);
    renderer.Renderer.drawRect(tab.x, tabs_ui.tab_y, tab.w, 2, accent);

    var label_buf: [32:0]u8 = undefined;
    @memcpy(label_buf[0..tab_label.len], tab_label);
    label_buf[tab_label.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&label_buf), tab.x + 12, tabs_ui.tab_y + 12, ui_size, text_primary);
    renderer.Renderer.drawText("×", tab.close_x + 4, tab.close_y, ui_size + 2, text_primary);
}

pub fn draw(
    wb: *@import("../workbench.zig").Workbench,
    editor_x: f32,
    editor_w: f32,
    editor_h: f32,
) void {
    const theme = &wb.theme;
    const accent = color(theme.colors.accent_soft);
    const editor_bg = color(theme.colors.editor_bg);
    const border = color(theme.colors.border);
    const text_primary = color(theme.colors.text_primary);

    drawTab(editor_x, editor_w, accent, editor_bg, border, text_primary, theme.ui_font_size);

    const top = contentTop();
    const content_h = editor_h - tabs_ui.tab_bar_height;
    renderer.Renderer.setClipRect(editor_x, top, editor_w, content_h);
    renderer.Renderer.drawRect(editor_x, top, editor_w, content_h, editor_bg);

    const content_w = @min(max_content_w, editor_w - h_pad * 2);
    const panel_x = editor_x + h_pad;
    var y = top + content_inset - wb.ai_settings_scroll_y;

    if (y + 28 >= top and y < top + content_h) {
        renderer.Renderer.drawText("AI Settings", panel_x, y, 20.0, text_primary);
    }
    y += 28;
    if (y + 18 >= top and y < top + content_h) {
        renderer.Renderer.drawText(
            "Provider, model, and MCP tools (Cursor-compatible config)",
            panel_x,
            y,
            12.0,
            .{ .r = 0.55, .g = 0.58, .b = 0.65, .a = 1.0 },
        );
    }
    y += 32;

    var row_buf: [256:0]u8 = undefined;
    const provider_line = std.fmt.bufPrint(&row_buf, "Provider: {s}", .{wb.ai_provider}) catch "Provider: ?";
    if (y + row_h >= top and y < top + content_h) {
        renderer.Renderer.drawText(provider_line, panel_x, y + 6, 13.0, text_primary);
    }
    y += row_h;

    const model_label = wb.ai_model orelse "default";
    const model_line = std.fmt.bufPrint(&row_buf, "Model: {s}", .{model_label}) catch "Model: ?";
    if (y + row_h >= top and y < top + content_h) {
        renderer.Renderer.drawText(model_line, panel_x, y + 6, 13.0, text_primary);
    }
    y += row_h;

    const mcp_state = if (wb.ai_mcp_enabled) "enabled" else "disabled";
    const mcp_line = std.fmt.bufPrint(&row_buf, "MCP tools: {s}", .{mcp_state}) catch "MCP tools";
    if (y + row_h >= top and y < top + content_h) {
        renderer.Renderer.drawRoundedRect(panel_x, y, content_w, row_h, 6, accent);
        renderer.Renderer.drawText(mcp_line, panel_x + 12, y + 7, 13.0, .{ .r = 0.95, .g = 0.96, .b = 0.98, .a = 1.0 });
        renderer.Renderer.drawText("click to toggle", panel_x + content_w - 110, y + 8, 11.0, .{ .r = 0.75, .g = 0.78, .b = 0.85, .a = 0.9 });
    }
    y += row_h + 24;

    const actions = [_]struct { label: []const u8 }{
        .{ .label = "Open forge.toml" },
        .{ .label = "Open MCP config (.mcp.json)" },
        .{ .label = "Refresh MCP status" },
    };
    for (actions) |action| {
        if (y + action_h >= top and y < top + content_h) {
            renderer.Renderer.drawRoundedRect(panel_x, y, content_w, action_h - 4, 6, .{ .r = 0.18, .g = 0.2, .b = 0.26, .a = 1.0 });
            renderer.Renderer.drawText(action.label, panel_x + 14, y + 10, 13.0, .{ .r = 0.88, .g = 0.9, .b = 0.95, .a = 1.0 });
        }
        y += action_h;
    }

    y += 16;
    if (y >= top and y < top + content_h) {
        renderer.Renderer.drawText("MCP status", panel_x, y, 11.0, .{ .r = 0.55, .g = 0.58, .b = 0.65, .a = 1.0 });
    }
    y += 20;

    if (wb.ai_mcp_status) |status| {
        var line_iter = std.mem.splitScalar(u8, status, '\n');
        while (line_iter.next()) |line| {
            if (y + status_line_h >= top and y < top + content_h) {
                var line_buf: [512:0]u8 = undefined;
                const n = @min(line.len, line_buf.len - 1);
                @memcpy(line_buf[0..n], line[0..n]);
                line_buf[n] = 0;
                renderer.Renderer.drawText(@ptrCast(&line_buf), panel_x + 8, y, 12.0, .{ .r = 0.72, .g = 0.76, .b = 0.84, .a = 1.0 });
            }
            y += status_line_h;
        }
    } else if (y >= top and y < top + content_h) {
        renderer.Renderer.drawText("Loading MCP status...", panel_x + 8, y, 12.0, .{ .r = 0.55, .g = 0.58, .b = 0.65, .a = 1.0 });
    }

    renderer.Renderer.clearClipRect();

    const status_lines = countStatusLines(wb.ai_mcp_status);
    const scroll_max = maxScrollY(editor_h, status_lines);
    if (scroll_max > 0) {
        const viewport = viewportHeight(editor_h);
        const show = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, editor_x + editor_w - scrollbar.track_w - 4, top, scrollbar.track_w, viewport);
        scrollbar.drawVertical(
            editor_x + editor_w - scrollbar.track_w - 4,
            top,
            viewport,
            wb.ai_settings_scroll_y,
            scroll_max,
            contentHeight(status_lines),
            viewport,
            show,
        );
    }
}

pub fn drawSidebarHint(panel_x: f32, panel_w: f32, panel_y: f32, panel_h: f32) void {
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, panel_h);
    renderer.Renderer.drawText("AI Settings", panel_x + 16, panel_y + 16, 12.0, .{ .r = 0.75, .g = 0.78, .b = 0.85, .a = 1.0 });
    renderer.Renderer.drawText("Shown in the editor panel →", panel_x + 16, panel_y + 36, 11.0, .{ .r = 0.5, .g = 0.54, .b = 0.6, .a = 1.0 });
    renderer.Renderer.clearClipRect();
}

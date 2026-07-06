const std = @import("std");
const renderer = @import("forge-renderer");
const layout = @import("layout.zig");

pub const Action = enum {
    toggle_sidebar,
    nav_back,
    nav_forward,
    toggle_bottom_panel,
    toggle_agent,
    open_settings,
    toggle_agent_window,
};

pub const Button = struct {
    action: Action,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    enabled: bool,
    active: bool,

    pub fn contains(self: Button, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub fn actionLabel(action: Action, state: ToolbarState) []const u8 {
    return switch (action) {
        .toggle_sidebar => if (state.sidebar_visible) "Hide Primary Sidebar" else "Show Primary Sidebar",
        .nav_back => "Go Back",
        .nav_forward => "Go Forward",
        .toggle_bottom_panel => if (state.bottom_panel_visible) "Hide Panel" else "Show Panel",
        .toggle_agent => if (state.agent_panel_visible) "Focus Agent" else "Show Agent",
        .open_settings => "AI Settings",
        .toggle_agent_window => if (state.shell_mode == .agent_window) "IDE Layout" else "Agent Window",
    };
}

pub fn actionTooltip(action: Action, state: ToolbarState, buf: []u8) []const u8 {
    const label = actionLabel(action, state);
    const shortcut: ?[]const u8 = switch (action) {
        .toggle_sidebar => " ⌘B",
        .toggle_bottom_panel => " ⌘J",
        .toggle_agent => " ⌘L",
        else => null,
    };
    if (shortcut) |suffix| {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ label, suffix }) catch label;
    }
    return label;
}

pub const ToolbarState = struct {
    shell_mode: layout.ShellMode,
    sidebar_visible: bool,
    bottom_panel_visible: bool,
    agent_panel_visible: bool,
    can_go_back: bool,
    can_go_forward: bool,
};

const btn_w: f32 = 28;
const btn_h: f32 = 22;
const btn_gap: f32 = 2;
const pad_y: f32 = 4;

pub fn layoutButtons(window_w: f32, state: ToolbarState, out: *[7]Button) usize {
    var count: usize = 0;
    var x = layout.headerLeftInset();

    const left_actions = [_]struct { action: Action, enabled: bool, active: bool }{
        .{ .action = .toggle_sidebar, .enabled = state.shell_mode == .ide, .active = state.sidebar_visible },
        .{ .action = .nav_back, .enabled = state.can_go_back, .active = false },
        .{ .action = .nav_forward, .enabled = state.can_go_forward, .active = false },
    };
    for (left_actions) |item| {
        out[count] = .{ .action = item.action, .x = x, .y = pad_y, .w = btn_w, .h = btn_h, .enabled = item.enabled, .active = item.active };
        count += 1;
        x += btn_w + btn_gap;
    }

    const right_actions = [_]struct { action: Action, enabled: bool, active: bool }{
        .{ .action = .toggle_bottom_panel, .enabled = state.shell_mode == .ide, .active = state.bottom_panel_visible },
        .{ .action = .toggle_agent, .enabled = state.shell_mode == .ide, .active = state.agent_panel_visible },
        .{ .action = .open_settings, .enabled = true, .active = false },
        .{ .action = .toggle_agent_window, .enabled = true, .active = state.shell_mode == .agent_window },
    };

    var rx = window_w - layout.headerRightInset();
    for (right_actions) |item| {
        rx -= btn_w;
        out[count] = .{ .action = item.action, .x = rx, .y = pad_y, .w = btn_w, .h = btn_h, .enabled = item.enabled, .active = item.active };
        count += 1;
        rx -= btn_gap;
    }

    return count;
}

fn hoverButton(window_w: f32, state: ToolbarState, px: f32, py: f32) ?Button {
    if (py < 0 or py >= layout.header_height) return null;
    var buttons: [7]Button = undefined;
    const count = layoutButtons(window_w, state, &buttons);
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        if (buttons[i].contains(px, py)) return buttons[i];
    }
    return null;
}

pub fn hoverAction(window_w: f32, state: ToolbarState, px: f32, py: f32) ?Action {
    const btn = hoverButton(window_w, state, px, py) orelse return null;
    return btn.action;
}

pub fn hitTest(window_w: f32, state: ToolbarState, px: f32, py: f32) ?Action {
    const btn = hoverButton(window_w, state, px, py) orelse return null;
    if (!btn.enabled) return null;
    return btn.action;
}

fn color(enabled: bool, active: bool, hover: bool) renderer.Color {
    if (!enabled) return .{ .r = 0.35, .g = 0.35, .b = 0.38, .a = 1.0 };
    if (active or hover) return .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 };
    return .{ .r = 0.72, .g = 0.74, .b = 0.78, .a = 1.0 };
}

fn drawIcon(action: Action, btn: Button, hover: bool) void {
    const c = color(btn.enabled, btn.active, hover);
    const svg = switch (action) {
        .toggle_sidebar => renderer.icons.file_directory,
        .nav_back => renderer.icons.chevron_down,
        .nav_forward => renderer.icons.chevron_right,
        .toggle_bottom_panel => renderer.icons.search,
        .toggle_agent => renderer.icons.sparkle,
        .open_settings => renderer.icons.gear,
        .toggle_agent_window => renderer.icons.repo,
    };
    renderer.Renderer.drawSvg(svg, btn.x + (btn.w - 16) / 2, btn.y + (btn.h - 16) / 2, 16, 16, c);
}

pub fn draw(window_w: f32, state: ToolbarState, hover_action: ?Action, header_bg: renderer.Color) void {
    renderer.Renderer.drawRect(0, 0, window_w, layout.header_height, header_bg);
    renderer.Renderer.drawRect(0, layout.header_height - 1, window_w, 1, .{ .r = 0.1, .g = 0.11, .b = 0.13, .a = 1.0 });

    var buttons: [7]Button = undefined;
    const count = layoutButtons(window_w, state, &buttons);
    for (buttons[0..count]) |btn| {
        if (!btn.enabled) continue;
        const hover = hover_action == btn.action;
        if (btn.active or hover) {
            renderer.Renderer.drawRoundedRect(btn.x, btn.y, btn.w, btn.h, 4, .{ .r = 0.28, .g = 0.32, .b = 0.38, .a = 1.0 });
        }
        drawIcon(btn.action, btn, hover);
    }
}

fn drawTooltip(window_w: f32, btn: Button, label: []const u8) void {
    const font_size: f32 = 11;
    const text_w = renderer.Renderer.measureText(label, font_size);
    const h_pad: f32 = 8;
    const v_pad: f32 = 4;
    const tip_w = text_w + h_pad * 2;
    const tip_h = font_size + v_pad * 2;
    var tip_x = btn.x + (btn.w - tip_w) * 0.5;
    tip_x = std.math.clamp(tip_x, 4, @max(4, window_w - tip_w - 4));
    const tip_y = btn.y + btn.h + 6;
    renderer.Renderer.drawRoundedRect(tip_x, tip_y, tip_w, tip_h, 4, .{ .r = 0.12, .g = 0.14, .b = 0.18, .a = 0.96 });
    renderer.Renderer.drawText(label, tip_x + h_pad, tip_y + v_pad, font_size, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
}

pub fn drawHoverTooltip(window_w: f32, state: ToolbarState, hover_action: ?Action) void {
    const action = hover_action orelse return;
    var buttons: [7]Button = undefined;
    const count = layoutButtons(window_w, state, &buttons);
    var tip_buf: [128]u8 = undefined;
    for (buttons[0..count]) |btn| {
        if (btn.action != action) continue;
        const tip = actionTooltip(action, state, &tip_buf);
        drawTooltip(window_w, btn, tip);
        return;
    }
}

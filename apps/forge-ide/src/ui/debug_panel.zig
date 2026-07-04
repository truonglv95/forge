const std = @import("std");
const layout = @import("layout.zig");

pub const list_top: f32 = 96;
pub const row_h: f32 = 28;
pub const launch_row_h: f32 = 32;
pub const control_row_h: f32 = 24;
pub const controls_block_h: f32 = control_row_h + 10;

pub const LaunchConfig = struct {
    id: []const u8,
    label: []const u8,
    task: []const u8,
};

pub const default_launches = [_]LaunchConfig{
    .{ .id = "debug_current", .label = "Debug: current file (lldb)", .task = "debug_current" },
    .{ .id = "test", .label = "zig build test", .task = "test" },
    .{ .id = "check", .label = "./scripts/check.sh", .task = "check" },
    .{ .id = "build", .label = "zig build", .task = "build" },
};

pub const ControlButton = enum {
    continue_exec,
    step_over,
    step_into,
    step_out,
    stop,
};

pub const controls = [_]struct { id: ControlButton, label: []const u8 }{
    .{ .id = .continue_exec, .label = "F5" },
    .{ .id = .step_over, .label = "F10" },
    .{ .id = .step_into, .label = "F11" },
    .{ .id = .step_out, .label = "S-F11" },
    .{ .id = .stop, .label = "Stop" },
};

pub fn contentHeight(breakpoint_count: usize, debug_active: bool) f32 {
    var h: f32 = 120 + @as(f32, @floatFromInt(default_launches.len)) * launch_row_h + 24 +
        @as(f32, @floatFromInt(breakpoint_count)) * row_h + 40;
    if (debug_active) h += controls_block_h;
    return h;
}

pub fn viewportHeight(window_h: f32) f32 {
    return @max(0, window_h - layout.status_height - list_top);
}

pub fn maxScrollY(breakpoint_count: usize, window_h: f32, debug_active: bool) f32 {
    return @max(0, contentHeight(breakpoint_count, debug_active) - viewportHeight(window_h));
}

pub fn clampScrollY(scroll_y: f32, breakpoint_count: usize, window_h: f32, debug_active: bool) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(breakpoint_count, window_h, debug_active));
}

pub const Hit = union(enum) {
    run_launch: usize,
    toggle_breakpoint,
    clear_breakpoints,
    debug_control: ControlButton,
};

pub fn hitTest(
    panel_x: f32,
    panel_w: f32,
    click_x: f32,
    click_y: f32,
    scroll_y: f32,
    breakpoint_count: usize,
    debug_active: bool,
) ?Hit {
    if (click_x < panel_x or click_x >= panel_x + panel_w) return null;
    const local_y = click_y - list_top + scroll_y;
    if (local_y < 0) return null;

    if (local_y >= 0 and local_y < 22) return .toggle_breakpoint;
    if (local_y >= 22 and local_y < 44) return .clear_breakpoints;

    var y: f32 = 56;
    if (debug_active) {
        if (local_y >= y and local_y < y + control_row_h) {
            const btn_w = (panel_w - 24) / @as(f32, @floatFromInt(controls.len));
            const rel_x = click_x - panel_x - 12;
            if (rel_x >= 0) {
                const index = @as(usize, @intFromFloat(rel_x / btn_w));
                if (index < controls.len) return .{ .debug_control = controls[index].id };
            }
        }
        y += controls_block_h;
    }

    if (local_y >= y and local_y < y + 14) return null;
    y += 18;
    for (default_launches, 0..) |_, index| {
        if (local_y >= y and local_y < y + launch_row_h) return .{ .run_launch = index };
        y += launch_row_h;
    }

    y += 40;
    _ = breakpoint_count;
    return null;
}

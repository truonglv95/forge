const std = @import("std");
const builtin = @import("builtin");

pub const activity_bar_height: f32 = 35;
pub const header_height: f32 = 30;
pub const status_height: f32 = 22;
pub const task_panel_height: f32 = 216;

/// Space reserved for macOS close/minimize/zoom buttons in the custom header.
pub const header_traffic_light_inset: f32 = if (builtin.os.tag == .macos) 78 else 0;
pub const header_edge_inset: f32 = 8;

pub fn headerLeftInset() f32 {
    return header_traffic_light_inset + header_edge_inset;
}

pub fn headerRightInset() f32 {
    return header_edge_inset;
}

pub const ShellMode = enum { ide, agent_window };

pub const Geometry = struct {
    shell_mode: ShellMode,
    window_w: f32,
    window_h: f32,
    content_h: f32,
    explorer_x: f32,
    explorer_w: f32,
    editor_x: f32,
    editor_w: f32,
    editor_h: f32,
    agent_x: f32,
    agent_w: f32,
    explorer_splitter_x: f32,
    agent_splitter_x: f32,
    task_panel_y: f32,
    task_panel_h: f32,
};

pub fn compute(
    shell_mode: ShellMode,
    window_w: f32,
    window_h: f32,
    explorer_panel_width: f32,
    agent_panel_width: f32,
    bottom_panel_height: f32,
    sidebar_visible: bool,
    agent_panel_visible: bool,
    bottom_panel_visible: bool,
) Geometry {
    const content_h = window_h - header_height - status_height;

    return switch (shell_mode) {
        .ide => blk: {
            const explorer_x: f32 = 0;
            const explorer_w = if (sidebar_visible) explorer_panel_width else 0;
            const editor_x = explorer_x + explorer_w;
            const agent_w = if (agent_panel_visible) agent_panel_width else 0;
            const agent_x = window_w - agent_w;
            const editor_w = @max(120.0, agent_x - editor_x);
            const panel_h = if (bottom_panel_visible)
                std.math.clamp(bottom_panel_height, 80.0, @max(80.0, content_h - 80.0))
            else
                0;
            const editor_h = content_h - panel_h;
            break :blk .{
                .shell_mode = shell_mode,
                .window_w = window_w,
                .window_h = window_h,
                .content_h = content_h,
                .explorer_x = explorer_x,
                .explorer_w = explorer_w,
                .editor_x = editor_x,
                .editor_w = editor_w,
                .editor_h = editor_h,
                .agent_x = agent_x,
                .agent_w = agent_w,
                .explorer_splitter_x = editor_x,
                .agent_splitter_x = agent_x,
                .task_panel_y = header_height + editor_h,
                .task_panel_h = panel_h,
            };
        },
        .agent_window => blk: {
            const agent_x: f32 = 0;
            const agent_w = window_w;
            break :blk .{
                .shell_mode = shell_mode,
                .window_w = window_w,
                .window_h = window_h,
                .content_h = content_h,
                .explorer_x = 0,
                .explorer_w = 0,
                .editor_x = 0,
                .editor_w = 0,
                .editor_h = 0,
                .agent_x = agent_x,
                .agent_w = agent_w,
                .explorer_splitter_x = 0,
                .agent_splitter_x = 0,
                .task_panel_y = header_height + content_h,
                .task_panel_h = 0,
            };
        },
    };
}

test "ide layout orders explorer, editor, agent left to right" {
    const geo = compute(.ide, 1200, 800, 250, 400, task_panel_height, true, true, true);
    try std.testing.expect(geo.explorer_x < geo.editor_x);
    try std.testing.expect(geo.editor_x + geo.editor_w <= geo.agent_x + 1);
    try std.testing.expect(geo.agent_x + geo.agent_w == 1200);
}

test "agent window uses full width for agent panel" {
    const geo = compute(.agent_window, 1200, 800, 250, 400, task_panel_height, true, true, true);
    try std.testing.expectEqual(@as(f32, 0), geo.agent_x);
    try std.testing.expectEqual(@as(f32, 1200), geo.agent_w);
}

test "ide visual smoke matrix keeps panels non-overlapping" {
    const windows = [_]struct { w: f32, h: f32 }{
        .{ .w = 860, .h = 520 },
        .{ .w = 1180, .h = 720 },
        .{ .w = 1540, .h = 940 },
        .{ .w = 2048, .h = 1152 },
    };
    const sidebars = [_]f32{ 180, 260, 420 };
    const agents = [_]f32{ 240, 420, 760 };
    const bottoms = [_]f32{ 0, 160, 320 };

    for (windows) |win| {
        for (sidebars) |sidebar_w| {
            for (agents) |agent_w| {
                for (bottoms) |bottom_h| {
                    const bottom_visible = bottom_h > 0;
                    const geo = compute(.ide, win.w, win.h, sidebar_w, agent_w, bottom_h, true, true, bottom_visible);
                    try std.testing.expect(geo.content_h == win.h - header_height - status_height);
                    try std.testing.expect(geo.explorer_x == 0);
                    try std.testing.expect(geo.explorer_w >= 0);
                    try std.testing.expect(geo.editor_x >= geo.explorer_x + geo.explorer_w);
                    try std.testing.expect(geo.editor_w >= 120);
                    try std.testing.expect(geo.editor_x + geo.editor_w <= geo.agent_x + 1);
                    try std.testing.expect(geo.agent_x + geo.agent_w == win.w);
                    try std.testing.expect(geo.task_panel_y + geo.task_panel_h <= win.h - status_height + 1);
                    try std.testing.expect(geo.editor_h + geo.task_panel_h <= geo.content_h + 1);
                    if (bottom_visible) {
                        try std.testing.expect(geo.task_panel_h >= 80);
                    } else {
                        try std.testing.expectEqual(@as(f32, 0), geo.task_panel_h);
                    }
                }
            }
        }
    }
}

test "agent visual smoke keeps full-width shell clear of status bar" {
    const sizes = [_]struct { w: f32, h: f32 }{
        .{ .w = 360, .h = 520 },
        .{ .w = 900, .h = 760 },
        .{ .w = 1440, .h = 1000 },
    };
    for (sizes) |size| {
        const geo = compute(.agent_window, size.w, size.h, 250, 400, task_panel_height, true, true, true);
        try std.testing.expectEqual(@as(f32, 0), geo.agent_x);
        try std.testing.expectEqual(size.w, geo.agent_w);
        try std.testing.expect(geo.task_panel_y <= size.h - status_height + 1);
        try std.testing.expectEqual(@as(f32, 0), geo.task_panel_h);
    }
}

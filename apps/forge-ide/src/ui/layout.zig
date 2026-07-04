const std = @import("std");

pub const activity_bar_width: f32 = 50;
pub const header_height: f32 = 30;
pub const status_height: f32 = 22;
pub const task_panel_height: f32 = 216;

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
) Geometry {
    const content_h = window_h - header_height - status_height;

    return switch (shell_mode) {
        .ide => blk: {
            const explorer_x = activity_bar_width;
            const explorer_w = explorer_panel_width;
            const editor_x = explorer_x + explorer_w;
            const agent_w = agent_panel_width;
            const agent_x = window_w - agent_w;
            const editor_w = @max(120.0, agent_x - editor_x);
            const panel_h = std.math.clamp(bottom_panel_height, 80.0, @max(80.0, content_h - 80.0));
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
            const agent_x = activity_bar_width;
            const agent_w = window_w - activity_bar_width;
            break :blk .{
                .shell_mode = shell_mode,
                .window_w = window_w,
                .window_h = window_h,
                .content_h = content_h,
                .explorer_x = activity_bar_width,
                .explorer_w = 0,
                .editor_x = activity_bar_width,
                .editor_w = 0,
                .editor_h = 0,
                .agent_x = agent_x,
                .agent_w = agent_w,
                .explorer_splitter_x = activity_bar_width,
                .agent_splitter_x = activity_bar_width,
                .task_panel_y = header_height + content_h,
                .task_panel_h = 0,
            };
        },
    };
}

test "ide layout orders explorer, editor, agent left to right" {
    const geo = compute(.ide, 1200, 800, 250, 400, task_panel_height);
    try std.testing.expect(geo.explorer_x < geo.editor_x);
    try std.testing.expect(geo.editor_x + geo.editor_w <= geo.agent_x + 1);
    try std.testing.expect(geo.agent_x + geo.agent_w == 1200);
}

test "agent window uses full width for agent panel" {
    const geo = compute(.agent_window, 1200, 800, 250, 400, task_panel_height);
    try std.testing.expectEqual(@as(f32, 50), geo.agent_x);
    try std.testing.expectEqual(@as(f32, 1150), geo.agent_w);
}

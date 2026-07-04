const std = @import("std");

pub const run_list_top: f32 = 82.0;
pub const run_row_h: f32 = 14.0;
pub const max_visible_runs: usize = 4;

pub fn hitTestRun(agent_x: f32, inner_pad: f32, y: f32, run_count: usize) ?usize {
    const inner_x = agent_x + inner_pad;
    if (y < run_list_top or y >= run_list_top + @as(f32, @floatFromInt(@min(run_count, max_visible_runs))) * run_row_h) {
        return null;
    }
    _ = inner_x;
    const row = @as(usize, @intFromFloat((y - run_list_top) / run_row_h));
    if (row >= run_count or row >= max_visible_runs) return null;
    return row;
}

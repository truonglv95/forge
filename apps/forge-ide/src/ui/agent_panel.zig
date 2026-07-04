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

pub const ButtonRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: ButtonRect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub const ReviewActions = struct {
    apply: ButtonRect,
    reject: ButtonRect,
};

pub fn reviewActions(agent_x: f32, _: f32, window_h: f32) ReviewActions {
    const pad: f32 = 20;
    const inner_x = agent_x + pad;
    const y = window_h - 145;
    return .{
        .apply = .{ .x = inner_x, .y = y, .w = 88, .h = 28 },
        .reject = .{ .x = inner_x + 96, .y = y, .w = 88, .h = 28 },
    };
}

pub fn hitReviewAction(agent_x: f32, agent_w: f32, window_h: f32, x: f32, y: f32) ?enum { apply, reject } {
    const actions = reviewActions(agent_x, agent_w, window_h);
    if (actions.apply.contains(x, y)) return .apply;
    if (actions.reject.contains(x, y)) return .reject;
    return null;
}

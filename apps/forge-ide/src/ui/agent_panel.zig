const std = @import("std");
const editor = @import("forge-editor");
const renderer = @import("forge-renderer");
const context_inspector = @import("context_inspector.zig");
const agent_composer = @import("agent_composer.zig");
const agent_session = @import("../agent/session.zig");

pub const chat_content_top: f32 = 68.0;

pub const apply_banner_h: f32 = 34;

pub const ApplyBanner = struct {
    keep: ButtonRect,
    undo: ButtonRect,
};

pub fn applyBannerLayout(agent_x: f32, y: f32) ApplyBanner {
    const inner_x = agent_x + 20;
    return .{
        .keep = .{ .x = inner_x, .y = y, .w = 72, .h = 24 },
        .undo = .{ .x = inner_x + 80, .y = y, .w = 72, .h = 24 },
    };
}

pub fn hitApplyBanner(agent_x: f32, y: f32, px: f32, py: f32) ?enum { keep, undo } {
    const banner = applyBannerLayout(agent_x, y);
    if (banner.keep.contains(px, py)) return .keep;
    if (banner.undo.contains(px, py)) return .undo;
    return null;
}

pub fn drawApplyBanner(agent_x: f32, agent_w: f32, y: f32) void {
    const banner = applyBannerLayout(agent_x, y);
    renderer.Renderer.drawRoundedRect(agent_x + 10, y - 4, agent_w - 20, apply_banner_h, 8, .{ .r = 0.14, .g = 0.24, .b = 0.18, .a = 1.0 });
    renderer.Renderer.drawText("Applied — keep changes?", agent_x + 20, y + 2, 11.0, .{ .r = 0.75, .g = 0.95, .b = 0.8, .a = 1.0 });
    renderer.Renderer.drawRoundedRect(banner.keep.x, banner.keep.y, banner.keep.w, banner.keep.h, 5, .{ .r = 0.2, .g = 0.5, .b = 0.35, .a = 1.0 });
    renderer.Renderer.drawText("Keep", banner.keep.x + 18, banner.keep.y + 5, 11.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
    renderer.Renderer.drawRoundedRect(banner.undo.x, banner.undo.y, banner.undo.w, banner.undo.h, 5, .{ .r = 0.45, .g = 0.22, .b = 0.22, .a = 1.0 });
    renderer.Renderer.drawText("Undo", banner.undo.x + 18, banner.undo.y + 5, 11.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
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
    rollback: ButtonRect,
    approve_spec: ButtonRect,
};

pub fn agentPromptTop(window_h: f32, attachment_count: usize, agent_w: f32, prompt: *const editor.Buffer) f32 {
    return agent_composer.composerTop(window_h, attachment_count, agent_w, prompt);
}

pub fn hitPromptInput(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    attachment_count: usize,
    prompt: *const editor.Buffer,
    x: f32,
    y: f32,
) bool {
    return agent_composer.hitPromptInput(agent_x, agent_w, window_h, attachment_count, prompt, x, y);
}

pub fn reviewContentHeight(agent: *agent_session.Session) f32 {
    agent.lock();
    defer agent.unlock();
    var h: f32 = 16 + 14 + 6;
    h += @as(f32, @floatFromInt(agent.context_lines.items.len)) * 11.0;
    h += 14 + 6;
    h += agent.review.totalContentHeight();
    if (agent.summary != null) h += 18;
    return h;
}

pub fn reviewHunksScreenTop(
    chat_scroll_y: f32,
    review_scroll_y: f32,
    agent: *agent_session.Session,
    has_summary: bool,
) f32 {
    var y = chat_content_top + 8.0 - chat_scroll_y + 16.0;
    if (has_summary) y += 18.0;
    y -= review_scroll_y;
    y += 14.0;
    agent.lock();
    y += @as(f32, @floatFromInt(agent.context_lines.items.len)) * 11.0;
    agent.unlock();
    y += 6.0 + 14.0;
    return y;
}

pub fn hitTestSteps(wb: *@import("../workbench.zig").Workbench, agent_x: f32, agent_w: f32, x: f32, y: f32) ?usize {
    const pad: f32 = 20;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;

    var content_y: f32 = chat_content_top + 8.0 - wb.chat_scroll_y;

    if (x < inner_x or x > inner_x + content_w) return null;

    const chat_bubble = @import("chat_bubble.zig");
    const tool_step_card = @import("tool_step_card.zig");

    const state = @import("state.zig");
    if (state.chat_history) |history| {
        for (history.items) |msg| {
            if (!chatHasVisibleContent(msg.content)) continue;
            const drawn = if (msg.role == .user)
                chat_bubble.bubbleHeight(msg.content, content_w, false) + chat_bubble.bubble_gap
            else
                chat_bubble.plainMessageHeight(msg.content, content_w);
            content_y += drawn;
        }
    }

    wb.agent.lock();
    defer wb.agent.unlock();

    var step_i: usize = 0;
    while (step_i < wb.agent.agent_steps.items.len) : (step_i += 1) {
        if (tool_step_card.hitTestStep(
            wb.agent.agent_steps.items,
            step_i,
            content_y,
            x,
            y,
            inner_x,
            content_w,
        )) |index| return index;
        content_y += tool_step_card.stepHeight(wb.agent.agent_steps.items, step_i, content_w);
    }
    return null;
}

pub fn hitReviewHunk(
    agent: *agent_session.Session,
    chat_scroll_y: f32,
    review_scroll_y: f32,
    has_summary: bool,
    x: f32,
    y: f32,
    agent_x: f32,
    inner_pad: f32,
) ?usize {
    const inner_x = agent_x + inner_pad;
    if (x < inner_x) return null;
    const hunks_top = reviewHunksScreenTop(chat_scroll_y, review_scroll_y, agent, has_summary);
    agent.lock();
    defer agent.unlock();
    return agent.review.hitTestHunk(y, hunks_top, 0);
}

pub fn chatHasVisibleContent(content: []const u8) bool {
    return std.mem.trim(u8, &std.ascii.whitespace, content).len > 0;
}

pub fn reviewActions(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    attachment_count: usize,
    prompt: *const editor.Buffer,
    show_rollback: bool,
    show_approve_spec: bool,
) ReviewActions {
    const composer_top = agent_composer.composerTop(window_h, attachment_count, agent_w, prompt);
    const y = composer_top - 36;
    const inner_x = agent_x + 20;
    var x = inner_x;
    const apply: ButtonRect = .{ .x = x, .y = y, .w = 88, .h = 28 };
    x += 96;
    const reject: ButtonRect = .{ .x = x, .y = y, .w = 88, .h = 28 };
    x += 96;
    const rollback: ButtonRect = if (show_rollback) .{ .x = x, .y = y, .w = 96, .h = 28 } else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (show_rollback) x += 104;
    const approve_spec: ButtonRect = if (show_approve_spec) .{ .x = x, .y = y, .w = 110, .h = 28 } else .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return .{ .apply = apply, .reject = reject, .rollback = rollback, .approve_spec = approve_spec };
}

pub fn hitReviewAction(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    attachment_count: usize,
    prompt: *const editor.Buffer,
    show_rollback: bool,
    show_approve_spec: bool,
    x: f32,
    y: f32,
) ?enum { apply, reject, rollback, approve_spec } {
    const actions = reviewActions(agent_x, agent_w, window_h, attachment_count, prompt, show_rollback, show_approve_spec);
    if (actions.apply.w > 0 and actions.apply.contains(x, y)) return .apply;
    if (actions.reject.w > 0 and actions.reject.contains(x, y)) return .reject;
    if (actions.rollback.w > 0 and actions.rollback.contains(x, y)) return .rollback;
    if (actions.approve_spec.w > 0 and actions.approve_spec.contains(x, y)) return .approve_spec;
    return null;
}

pub fn composerLayout(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    attachment_count: usize,
    prompt: *const editor.Buffer,
) agent_composer.Layout {
    return agent_composer.computeLayout(agent_x, agent_w, window_h, attachment_count, prompt);
}

pub fn bottomReserved(attachment_count: usize, agent_w: f32, prompt: *const editor.Buffer) f32 {
    const visual_lines = agent_composer.visualLineCount(prompt, agent_w);
    return agent_composer.composerHeight(attachment_count, visual_lines) + context_inspector.composer_pad + context_inspector.strip_gap;
}

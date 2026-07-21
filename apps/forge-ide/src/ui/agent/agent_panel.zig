const std = @import("std");
const editor = @import("forge-editor");
const renderer = @import("forge-renderer");
const context_inspector = @import("context_inspector.zig");
const agent_composer = @import("agent_composer.zig");
const agent_session = @import("../../agent/session.zig");
const metrics = @import("metrics.zig");

pub const chat_content_top: f32 = metrics.panel.chat_content_top;

pub const apply_banner_h: f32 = metrics.panel.apply_banner_h;
pub const apply_banner_validation_line_h: f32 = metrics.panel.apply_banner_validation_line_h;
pub const apply_banner_validation_pad: f32 = metrics.panel.apply_banner_validation_pad;

pub fn applyBannerHeight(validation_failed: bool, validation_count: usize) f32 {
    if (!validation_failed or validation_count == 0) return apply_banner_h;
    return apply_banner_h + apply_banner_validation_pad * 2.0 + @as(f32, @floatFromInt(validation_count)) * apply_banner_validation_line_h;
}

const word_wrap = @import("../editor/word_wrap.zig");

pub fn resumeBannerHeight(agent_w: f32, intent: []const u8, state: []const u8) f32 {
    var detail_buf: [4096]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "{s} · {s}", .{ intent, state }) catch intent;

    var lines: usize = 0;
    var start: usize = 0;
    const max_w = agent_w - metrics.chat.outer_pad * 2.0;
    while (start < detail.len) {
        const end = word_wrap.breakAt(detail, start, max_w, 10.0);
        lines += 1;
        if (end >= detail.len) break;
        start = end;
        while (start < detail.len and detail[start] == ' ') start += 1;
    }
    const text_h = @as(f32, @floatFromInt(lines)) * metrics.panel.resume_detail_line_h;
    return 16.0 + text_h + 8.0 + 24.0 + 8.0;
}

pub const ResumeBanner = struct {
    primary: ButtonRect,
    dismiss: ButtonRect,
};

pub const ApplyBanner = struct {
    primary: ButtonRect,
    undo: ButtonRect,
};

pub fn applyBannerLayout(agent_x: f32, y: f32, validation_failed: bool, validation_count: usize) ApplyBanner {
    const inner_x = agent_x + metrics.chat.outer_pad;
    const button_y = if (validation_failed and validation_count > 0)
        y + apply_banner_h - 26 + apply_banner_validation_pad + @as(f32, @floatFromInt(@min(validation_count, 4))) * apply_banner_validation_line_h
    else
        y + 24;
    return .{
        .primary = .{ .x = inner_x, .y = button_y, .w = 72, .h = 24 },
        .undo = .{ .x = inner_x + 80, .y = button_y, .w = 88, .h = 24 },
    };
}

pub fn hitApplyBanner(agent_x: f32, y: f32, px: f32, py: f32, validation_failed: bool, validation_count: usize) ?enum { primary, undo } {
    const banner = applyBannerLayout(agent_x, y, validation_failed, validation_count);
    if (banner.primary.contains(px, py)) return .primary;
    if (banner.undo.contains(px, py)) return .undo;
    return null;
}

pub fn drawApplyBanner(
    agent_x: f32,
    agent_w: f32,
    y: f32,
    validation_failed: bool,
    validation_results: []const agent_session.ValidationResult,
) void {
    const banner = applyBannerLayout(agent_x, y, validation_failed, validation_results.len);
    const bg = if (validation_failed)
        renderer.Color{ .r = 0.28, .g = 0.14, .b = 0.14, .a = 1.0 }
    else
        renderer.Color{ .r = 0.14, .g = 0.2, .b = 0.28, .a = 1.0 };

    const banner_h = applyBannerHeight(validation_failed, validation_results.len);
    renderer.Renderer.drawRoundedRect(agent_x + metrics.panel.banner_surface_inset, y - 4, agent_w - metrics.panel.banner_surface_inset * 2.0, banner_h, 8, bg);

    const title = if (validation_failed) "Apply failed" else "Plan applied successfully";
    const title_color = if (validation_failed)
        renderer.Color{ .r = 1.0, .g = 0.7, .b = 0.7, .a = 1.0 }
    else
        renderer.Color{ .r = 0.8, .g = 0.9, .b = 1.0, .a = 1.0 };
    renderer.Renderer.drawText(title, agent_x + metrics.chat.outer_pad, y + 2, 11.0, title_color);

    if (validation_failed) {
        var line_y = y + 18;
        const show_count = @min(validation_results.len, 4);
        var i: usize = 0;
        while (i < show_count) : (i += 1) {
            const result = validation_results[i];
            var line_buf: [192:0]u8 = undefined;
            const status = if (result.skipped) "skip" else if (result.exit_code == 0) "ok" else "fail";
            const clipped_task = result.task[0..@min(result.task.len, 80)];
            const line = std.fmt.bufPrint(&line_buf, "{s} · {s}", .{ status, clipped_task }) catch continue;
            line_buf[line.len] = 0;
            const line_color = if (std.mem.eql(u8, status, "fail"))
                renderer.Color{ .r = 0.95, .g = 0.55, .b = 0.5, .a = 1.0 }
            else
                renderer.Color{ .r = 0.7, .g = 0.75, .b = 0.8, .a = 1.0 };
            renderer.Renderer.drawText(@ptrCast(&line_buf), agent_x + metrics.chat.outer_pad, line_y, 9.5, line_color);
            line_y += apply_banner_validation_line_h;
        }
    }

    const keep_bg = if (validation_failed)
        renderer.Color{ .r = 0.35, .g = 0.35, .b = 0.4, .a = 1.0 }
    else
        renderer.Color{ .r = 0.2, .g = 0.5, .b = 0.35, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(banner.primary.x, banner.primary.y, banner.primary.w, banner.primary.h, 5, keep_bg);
    renderer.Renderer.drawText("Keep", banner.primary.x + 18, banner.primary.y + 5, 11.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
    const undo_label = if (validation_failed) "Rollback" else "Undo";
    renderer.Renderer.drawRoundedRect(banner.undo.x, banner.undo.y, banner.undo.w, banner.undo.h, 5, .{ .r = 0.45, .g = 0.22, .b = 0.22, .a = 1.0 });
    const undo_x = banner.undo.x + if (validation_failed) @as(f32, 12) else @as(f32, 18);
    renderer.Renderer.drawText(undo_label, undo_x, banner.undo.y + 5, 11.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
}

pub fn resumeBannerLayout(agent_x: f32, y: f32, h: f32) ResumeBanner {
    const inner_x = agent_x + metrics.chat.outer_pad;
    const btn_y = y - 4 + h - 32;
    return .{
        .primary = .{ .x = inner_x, .y = btn_y, .w = 96, .h = 24 },
        .dismiss = .{ .x = inner_x + 104, .y = btn_y, .w = 72, .h = 24 },
    };
}

pub fn hitResumeBanner(agent_x: f32, agent_w: f32, y: f32, px: f32, py: f32, intent: []const u8, state: []const u8) ?enum { primary, dismiss } {
    const h = resumeBannerHeight(agent_w, intent, state);
    const banner = resumeBannerLayout(agent_x, y, h);
    if (banner.primary.contains(px, py)) return .primary;
    if (banner.dismiss.contains(px, py)) return .dismiss;
    return null;
}

pub fn drawResumeBanner(
    agent_x: f32,
    agent_w: f32,
    y: f32,
    kind: agent_session.ResumeOfferKind,
    intent: []const u8,
    state: []const u8,
) void {
    const h = resumeBannerHeight(agent_w, intent, state);
    const banner = resumeBannerLayout(agent_x, y, h);
    const is_proposal = kind == .review_proposal;
    const bg = if (is_proposal)
        renderer.Color{ .r = 0.16, .g = 0.24, .b = 0.18, .a = 1.0 }
    else
        renderer.Color{ .r = 0.14, .g = 0.2, .b = 0.28, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(agent_x + metrics.panel.banner_surface_inset, y - 4, agent_w - metrics.panel.banner_surface_inset * 2.0, h, 8, bg);
    const title = if (is_proposal) "Proposal ready for review" else "Interrupted agent run";
    const title_color = if (is_proposal)
        renderer.Color{ .r = 0.75, .g = 0.95, .b = 0.8, .a = 1.0 }
    else
        renderer.Color{ .r = 0.8, .g = 0.9, .b = 1.0, .a = 1.0 };
    renderer.Renderer.drawText(title, agent_x + metrics.chat.outer_pad, y + 2, 11.0, title_color);

    var detail_buf: [4096]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "{s} · {s}", .{ intent, state }) catch intent;

    var text_y = y + 16;
    var start: usize = 0;
    const max_w = agent_w - metrics.chat.outer_pad * 2.0;
    while (start < detail.len) {
        const end = word_wrap.breakAt(detail, start, max_w, 10.0);
        const part = detail[start..end];
        if (part.len > 0) {
            var part_buf: [1024:0]u8 = undefined;
            const part_len = @min(part.len, part_buf.len - 1);
            @memcpy(part_buf[0..part_len], part[0..part_len]);
            part_buf[part_len] = 0;
            renderer.Renderer.drawText(@ptrCast(&part_buf), agent_x + metrics.chat.outer_pad, text_y, 10.0, .{ .r = 0.68, .g = 0.74, .b = 0.82, .a = 1.0 });
        }
        if (end >= detail.len) break;
        text_y += metrics.panel.resume_detail_line_h;
        start = end;
        while (start < detail.len and detail[start] == ' ') start += 1;
    }
    const primary_bg = if (is_proposal)
        renderer.Color{ .r = 0.2, .g = 0.5, .b = 0.35, .a = 1.0 }
    else
        renderer.Color{ .r = 0.2, .g = 0.45, .b = 0.62, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(banner.primary.x, banner.primary.y, banner.primary.w, banner.primary.h, 5, primary_bg);
    const primary_label = if (is_proposal) "Review" else "Continue";
    const primary_x = banner.primary.x + if (is_proposal) @as(f32, 22) else @as(f32, 16);
    renderer.Renderer.drawText(primary_label, primary_x, banner.primary.y + 5, 11.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
    renderer.Renderer.drawRoundedRect(banner.dismiss.x, banner.dismiss.y, banner.dismiss.w, banner.dismiss.h, 5, .{ .r = 0.35, .g = 0.35, .b = 0.4, .a = 1.0 });
    renderer.Renderer.drawText("Dismiss", banner.dismiss.x + 10, banner.dismiss.y + 5, 11.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
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
    var y = chat_content_top + metrics.panel.chat_top_gap - chat_scroll_y + 16.0;
    if (has_summary) y += 18.0;
    y -= review_scroll_y;
    y += 14.0;
    agent.lock();
    y += @as(f32, @floatFromInt(agent.context_lines.items.len)) * 11.0;
    agent.unlock();
    y += 6.0 + 14.0;
    return y;
}

pub fn hitTestSteps(wb: *@import("../../workbench.zig").Workbench, agent_x: f32, agent_w: f32, x: f32, y: f32) ?usize {
    const pad: f32 = metrics.chat.outer_pad;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;

    var content_y: f32 = chat_content_top + metrics.panel.chat_top_gap - wb.chat_scroll_y;

    if (x < inner_x or x > inner_x + content_w) return null;

    const chat_bubble = @import("chat_bubble.zig");
    const tool_step_card = @import("tool_step_card.zig");

    const state = @import("../core/state.zig");
    if (state.chat_history) |history| {
        for (history.items) |msg| {
            if (msg.role != .tool and !chatHasVisibleContent(msg.content)) continue;
            const drawn = switch (msg.role) {
                .user => chat_bubble.bubbleHeight(msg.content, content_w, false) + chat_bubble.bubble_gap,
                .agent => chat_bubble.agentMessageHeight(msg.content, content_w),
                .tool => tool_step_card.card_h + tool_step_card.card_gap + metrics.tool_step.history_tool_gap,
            };
            content_y += drawn;
        }
    }

    wb.agent_ui.session.lock();
    defer wb.agent_ui.session.unlock();
    const mode = wb.agent_ui.session.mode;

    var step_i: usize = 0;
    while (step_i < wb.agent_ui.session.agent_steps.items.len) : (step_i += 1) {
        if (tool_step_card.hitTestStep(
            wb.agent_ui.session.agent_steps.items,
            step_i,
            content_y,
            x,
            y,
            inner_x,
            content_w,
        )) |index| return index;
        content_y += tool_step_card.stepHeight(wb.agent_ui.session.agent_steps.items, step_i, content_w, mode);
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
    const y = composer_top - metrics.panel.review_action_offset;
    const inner_x = agent_x + metrics.chat.outer_pad;
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

pub const ApprovalActions = struct { approve: ButtonRect, reject: ButtonRect, approve_always: ButtonRect };

pub fn approvalOverlayTop(window_h: f32, attachment_count: usize, agent_w: f32, prompt: *const editor.Buffer) f32 {
    return agent_composer.composerTop(window_h, attachment_count, agent_w, prompt) - metrics.panel.approval_overlay_offset;
}

pub fn drawApprovalOverlay(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    attachment_count: usize,
    prompt: *const editor.Buffer,
    tool: []const u8,
    risk: []const u8,
    args: []const u8,
    is_review: bool,
) void {
    const pad: f32 = metrics.chat.outer_pad;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;
    const y = approvalOverlayTop(window_h, attachment_count, agent_w, prompt);
    const title = if (is_review) "EDIT REVIEW REQUIRED" else "TOOL APPROVAL REQUIRED";
    renderer.Renderer.drawRoundedRect(inner_x, y, content_w, metrics.panel.approval_overlay_h, 8, .{ .r = 0.28, .g = 0.2, .b = 0.08, .a = 1.0 });
    renderer.Renderer.drawText(title, inner_x + 10, y + 8, 11.0, .{ .r = 1.0, .g = 0.78, .b = 0.35, .a = 1.0 });
    var approval_buf: [384:0]u8 = undefined;
    const approval_line = std.fmt.bufPrint(&approval_buf, "{s} · risk: {s}", .{ tool, risk }) catch "Tool details unavailable";
    approval_buf[approval_line.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&approval_buf), inner_x + 10, y + 27, 11.0, .{ .r = 0.95, .g = 0.9, .b = 0.78, .a = 1.0 });
    var args_buf: [384:0]u8 = undefined;
    const clipped_args = args[0..@min(args.len, 360)];
    const args_line = std.fmt.bufPrint(&args_buf, "Args: {s}", .{clipped_args}) catch "Args unavailable";
    args_buf[args_line.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&args_buf), inner_x + 10, y + 46, 9.5, .{ .r = 0.78, .g = 0.75, .b = 0.68, .a = 1.0 });
}

pub fn approvalActions(agent_x: f32, agent_w: f32, window_h: f32, attachment_count: usize, prompt: *const editor.Buffer) ApprovalActions {
    const y = agent_composer.composerTop(window_h, attachment_count, agent_w, prompt) - metrics.panel.approval_action_offset;
    const x = agent_x + metrics.chat.outer_pad;
    return .{
        .approve = .{ .x = x, .y = y, .w = 108, .h = 28 },
        .reject = .{ .x = x + 116, .y = y, .w = 108, .h = 28 },
        .approve_always = .{ .x = x + 232, .y = y, .w = 120, .h = 28 },
    };
}

pub fn hitApprovalAction(agent_x: f32, agent_w: f32, window_h: f32, attachment_count: usize, prompt: *const editor.Buffer, x: f32, y: f32) ?enum { approve, reject, approve_always } {
    const actions = approvalActions(agent_x, agent_w, window_h, attachment_count, prompt);
    if (actions.approve.contains(x, y)) return .approve;
    if (actions.reject.contains(x, y)) return .reject;
    if (actions.approve_always.contains(x, y)) return .approve_always;
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
    return agent_composer.composerHeight(attachment_count, visual_lines) + agent_composer.composer_pad;
}

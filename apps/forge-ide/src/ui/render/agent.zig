const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../core/state.zig");
const layout = @import("../core/layout.zig");
const context_inspector = @import("../agent/context_inspector.zig");
const chat_bubble = @import("../agent/chat_bubble.zig");
const tool_step_card = @import("../agent/tool_step_card.zig");
const agent_composer = @import("../agent/agent_composer.zig");
const scrollbar = @import("../core/scrollbar.zig");
const agent_panel = @import("../agent/agent_panel.zig");
const agent_scope_picker_mod = @import("../../agent/scope_picker.zig");
const ai = @import("forge-ai");
const render_theme = @import("theme.zig");

const Workbench = @import("../../workbench.zig").Workbench;

pub fn drawAgentPanel(wb: *Workbench, agent_x: f32, agent_w: f32, h: f32) void {
    const pad: f32 = 20;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;
    renderer.Renderer.setClipRect(agent_x, layout.header_height, agent_w, h - layout.header_height - layout.status_height);
    defer renderer.Renderer.clearClipRect();

    var status_copy: [320]u8 = undefined;
    var provider_copy: [128]u8 = undefined;
    const snap = wb.agent.snapshot(&status_copy, &provider_copy);
    if (snap.worker_running) wb.clampChatScroll(h);

    const chat_tab_x = agent_x;
    const chat_tab_w = 120;
    const chat_tab_y = layout.header_height; // 30
    const chat_tab_h = 35; // Match editor tab_height
    const subtle_border = render_theme.color(wb.theme.colors.border);

    // Fill the tab bar background for the agent header
    renderer.Renderer.drawRect(agent_x, chat_tab_y, agent_w, chat_tab_h, render_theme.color(wb.theme.colors.tab_bar_bg));

    // Draw bottom border for the whole header
    renderer.Renderer.drawRect(agent_x, chat_tab_y + chat_tab_h, agent_w, 1, subtle_border);

    // Draw active tab shape for "Chat"
    renderer.Renderer.drawRect(chat_tab_x, chat_tab_y, chat_tab_w, chat_tab_h + 1, render_theme.color(wb.theme.colors.editor_bg)); // +1 to cover bottom border
    renderer.Renderer.drawRect(chat_tab_x, chat_tab_y, chat_tab_w, 1, subtle_border); // top
    renderer.Renderer.drawRect(chat_tab_x, chat_tab_y, 1, chat_tab_h, subtle_border); // left
    renderer.Renderer.drawRect(chat_tab_x + chat_tab_w - 1, chat_tab_y, 1, chat_tab_h, subtle_border); // right

    var mode_buf: [64:0]u8 = undefined;
    const mode_label = std.fmt.bufPrint(&mode_buf, "Chat", .{}) catch "Chat";
    mode_buf[mode_label.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&mode_buf), chat_tab_x + 16, 44, 13.0, .{ .r = 0.82, .g = 0.84, .b = 0.9, .a = 1.0 });

    const mx = state.last_mouse_x;
    const my = state.last_mouse_y;

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    var rx = inner_x + content_w - 20;

    if (mx >= rx and mx < rx + 16 and my >= 32 and my < 52) {
        renderer.Renderer.drawRoundedRect(rx - 2, 32, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, rx - 8, 27, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= 32 and my < 52) {
        renderer.Renderer.drawRoundedRect(rx - 2, 32, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.sync, rx - 8, 27, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= 32 and my < 52) {
        renderer.Renderer.drawRoundedRect(rx - 2, 32, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.plus, rx - 8, 27, 16, 16, icon_c);

    const composer_layout = agent_composer.computeLayout(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer);
    wb.clampPromptScroll(agent_w);
    const visible_entries = context_inspector.effectiveEntryCount(&wb.agent, snap.context_entry_count);
    wb.agent.lock();
    const ctx_selected = wb.agent.context_selected_index;
    const ctx_scroll = wb.agent.context_inspector_scroll_y;
    const ctx_has_detail = ctx_selected != null and snap.context_inspector_expanded;
    wb.agent.unlock();
    const strip_top = context_inspector.stripTop(h, snap.context_inspector_expanded, visible_entries, snap.attachment_count, agent_w, &wb.prompt_buffer, ctx_has_detail, snap.has_routing_preview);
    const chat_bottom = strip_top - 4;

    const chat_top = agent_panel.chat_content_top + 8.0;
    var content_y: f32 = chat_top - wb.chat_scroll_y;

    if (snap.post_apply_visible) {
        wb.agent.lock();
        const validation_results = wb.agent.validation_results.items;
        const banner_h = agent_panel.applyBannerHeight(snap.validation_failed, validation_results.len);
        agent_panel.drawApplyBanner(agent_x, agent_w, content_y, snap.validation_failed, validation_results);
        wb.agent.unlock();
        content_y += banner_h + 4;
    }

    if (snap.resume_offer_visible) {
        const intent = snap.resume_intent orelse "previous run";
        const resume_state = snap.resume_state orelse "interrupted";
        agent_panel.drawResumeBanner(agent_x, agent_w, content_y, snap.resume_offer_kind, intent, resume_state);
        content_y += agent_panel.resume_banner_h + 4;
    }

    if (snap.approval_pending) {
        const title = if (snap.approval_kind == .review) "EDIT REVIEW REQUIRED" else "TOOL APPROVAL REQUIRED";
        renderer.Renderer.drawRoundedRect(inner_x, content_y, content_w, 72, 8, .{ .r = 0.28, .g = 0.2, .b = 0.08, .a = 1.0 });
        renderer.Renderer.drawText(title, inner_x + 10, content_y + 8, 11.0, .{ .r = 1.0, .g = 0.78, .b = 0.35, .a = 1.0 });
        wb.agent.lock();
        var approval_buf: [384:0]u8 = undefined;
        const approval_line = std.fmt.bufPrint(&approval_buf, "{s} · risk: {s}", .{
            wb.agent.approval_tool orelse "unknown tool",
            wb.agent.approval_risk orelse "unknown",
        }) catch "Tool details unavailable";
        approval_buf[approval_line.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&approval_buf), inner_x + 10, content_y + 27, 11.0, .{ .r = 0.95, .g = 0.9, .b = 0.78, .a = 1.0 });
        var args_buf: [384:0]u8 = undefined;
        const args_src = wb.agent.approval_args orelse "{}";
        const clipped_args = args_src[0..@min(args_src.len, 360)];
        const args_line = std.fmt.bufPrint(&args_buf, "Args: {s}", .{clipped_args}) catch "Args unavailable";
        args_buf[args_line.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&args_buf), inner_x + 10, content_y + 46, 9.5, .{ .r = 0.78, .g = 0.75, .b = 0.68, .a = 1.0 });
        wb.agent.unlock();
        content_y += 80;
    }

    if (snap.show_review and wb.proposal_review_open) {
        renderer.Renderer.drawRoundedRect(agent_x + 10, content_y, agent_w - 20, 48, 8, .{ .r = 0.14, .g = 0.2, .b = 0.28, .a = 1.0 });
        renderer.Renderer.drawText("Proposal review open in editor panel", inner_x, content_y + 10, 12.0, .{ .r = 0.8, .g = 0.9, .b = 1.0, .a = 1.0 });
        renderer.Renderer.drawText("Toggle hunks and apply from the editor view", inner_x, content_y + 26, 10.0, .{ .r = 0.6, .g = 0.68, .b = 0.78, .a = 1.0 });
        content_y += 56;
    } else if (snap.show_review) {
        renderer.Renderer.drawText("REVIEW", inner_x, content_y, 11.0, .{ .r = 1.0, .g = 0.7, .b = 0.4, .a = 1.0 });
        content_y += 16.0;
        if (snap.summary) |summary| {
            var summary_buf: [384:0]u8 = undefined;
            const clipped = if (summary.len > 383) summary[0..383] else summary;
            @memcpy(summary_buf[0..clipped.len], clipped);
            summary_buf[clipped.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&summary_buf), inner_x, content_y, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            content_y += 18.0;
        }

        var review_y = content_y - wb.agent.review_scroll_y;
        renderer.Renderer.drawText("CONTEXT", inner_x, review_y, 10.0, .{ .r = 0.55, .g = 0.75, .b = 1.0, .a = 1.0 });
        review_y += 14.0;
        wb.agent.lock();
        for (wb.agent.context_lines.items) |line| {
            if (review_y > chat_bottom) break;
            var ctx_buf: [512:0]u8 = undefined;
            const clipped = if (line.len > 511) line[0..511] else line;
            @memcpy(ctx_buf[0..clipped.len], clipped);
            ctx_buf[clipped.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&ctx_buf), inner_x + 6, review_y, 9.5, .{ .r = 0.7, .g = 0.78, .b = 0.9, .a = 1.0 });
            review_y += 11.0;
        }
        review_y += 6.0;
        renderer.Renderer.drawText("CHANGES (click to toggle)", inner_x, review_y, 10.0, .{ .r = 0.55, .g = 0.75, .b = 1.0, .a = 1.0 });
        review_y += 14.0;
        for (wb.agent.review.hunks) |hunk| {
            if (review_y > chat_bottom) break;
            const block_h = @import("../../agent/review_store.zig").Store.hunkBlockHeight(hunk);
            const accepted = hunk.accepted;
            const header_bg = if (accepted)
                renderer.Color{ .r = 0.14, .g = 0.22, .b = 0.16, .a = 1.0 }
            else
                renderer.Color{ .r = 0.18, .g = 0.14, .b = 0.14, .a = 1.0 };
            renderer.Renderer.drawRoundedRect(inner_x, review_y - 2, content_w - 8, block_h + 4, 4, header_bg);
            var header_buf: [384:0]u8 = undefined;
            const marker = if (accepted) "[x] " else "[ ] ";
            const header = std.fmt.bufPrint(&header_buf, "{s}{s}", .{ marker, hunk.label }) catch hunk.label;
            header_buf[header.len] = 0;
            const header_color = if (accepted)
                renderer.Color{ .r = 0.75, .g = 0.95, .b = 0.75, .a = 1.0 }
            else
                renderer.Color{ .r = 0.65, .g = 0.55, .b = 0.55, .a = 1.0 };
            renderer.Renderer.drawText(@ptrCast(&header_buf), inner_x + 6, review_y, 10.0, header_color);
            var line_y = review_y + 14.0;
            for (hunk.diff_lines) |line| {
                if (line_y > chat_bottom) break;
                var line_buf: [512:0]u8 = undefined;
                const clipped = if (line.len > 511) line[0..511] else line;
                @memcpy(line_buf[0..clipped.len], clipped);
                line_buf[clipped.len] = 0;
                var color = renderer.Color{ .r = 0.75, .g = 0.75, .b = 0.75, .a = if (accepted) 1.0 else 0.45 };
                if (line.len > 0 and line[0] == '+') color = .{ .r = 0.5, .g = 0.9, .b = 0.5, .a = if (accepted) 1.0 else 0.45 };
                if (line.len > 0 and line[0] == '-') color = .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = if (accepted) 1.0 else 0.45 };
                if (line.len > 3 and std.mem.startsWith(u8, line, "---")) color = .{ .r = 0.95, .g = 0.85, .b = 0.45, .a = if (accepted) 1.0 else 0.45 };
                if (line.len > 3 and std.mem.startsWith(u8, line, "+++")) color = .{ .r = 0.55, .g = 0.85, .b = 0.95, .a = if (accepted) 1.0 else 0.45 };
                renderer.Renderer.drawText(@ptrCast(&line_buf), inner_x + 10, line_y, 9.5, color);
                line_y += 12.0;
            }
            review_y += block_h + 6.0;
        }
        wb.agent.unlock();
    } else {
        const user_style = chat_bubble.BubbleStyle{
            .bg = .{ .r = 0.2, .g = 0.2, .b = 0.25, .a = 1.0 },
            .fg = .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 },
        };
        for (state.chat_history.?.items) |msg| {
            if (!agent_panel.chatHasVisibleContent(msg.content)) continue;
            const msg_h = chat_bubble.historyMessageHeight(msg.role == .user, msg.content, content_w);
            if (content_y + msg_h > chat_bottom and content_y > chat_top) break;
            const drawn = if (msg.role == .user)
                chat_bubble.drawBubble(wb.allocator, agent_x, inner_x, content_w, content_y, null, msg.content, user_style)
            else
                chat_bubble.drawPlainMessage(wb.allocator, inner_x, content_w, content_y, msg.content, chat_bubble.agent_text_style);
            content_y += drawn;
        }

        if (snap.worker_running) {
            wb.agent.lock();
            defer wb.agent.unlock();

            var step_i: usize = 0;
            while (step_i < wb.agent.agent_steps.items.len) : (step_i += 1) {
                if (content_y > chat_bottom) break;
                const drawn = tool_step_card.drawStep(
                    agent_x,
                    inner_x,
                    content_w,
                    content_y,
                    wb.agent.agent_steps.items,
                    step_i,
                    wb.allocator,
                    state.time,
                    snap.mode,
                );
                if (drawn > 0) content_y += drawn;
            }

            const thinking_src = wb.agent.thinking_text.items;
            const stream_src = wb.agent.stream_text.items;

            if (thinking_src.len > 0) {
                content_y += chat_bubble.drawThinkingLine(inner_x, content_y, thinking_src);
            } else if (stream_src.len == 0) {
                var has_running_step = false;
                for (wb.agent.agent_steps.items) |step| {
                    if (step.running and step.parent_index == null) {
                        has_running_step = true;
                        break;
                    }
                }
                if (!has_running_step) {
                    var live_buf: [256:0]u8 = undefined;
                    const live_text = if (snap.status_line.len > 0)
                        std.fmt.bufPrint(&live_buf, "{s}", .{snap.status_line}) catch "Working..."
                    else
                        std.fmt.bufPrint(&live_buf, "Working...", .{}) catch "Working...";
                    live_buf[live_text.len] = 0;
                    content_y += chat_bubble.drawStatusLine(inner_x, content_y, live_buf[0..live_text.len :0]);
                }
            }

            if (stream_src.len > 0) {
                content_y += chat_bubble.drawPlainMessage(
                    wb.allocator,
                    inner_x,
                    content_w,
                    content_y,
                    stream_src,
                    chat_bubble.agent_text_style,
                );
            }
        }
    }

    if (snap.approval_pending) {
        const actions = agent_panel.approvalActions(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer);
        renderer.Renderer.drawRoundedRect(actions.approve.x, actions.approve.y, actions.approve.w, actions.approve.h, 6, .{ .r = 0.2, .g = 0.55, .b = 0.35, .a = 1.0 });
        renderer.Renderer.drawText("Approve once", actions.approve.x + 10, actions.approve.y + 6, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
        renderer.Renderer.drawRoundedRect(actions.reject.x, actions.reject.y, actions.reject.w, actions.reject.h, 6, .{ .r = 0.5, .g = 0.2, .b = 0.2, .a = 1.0 });
        renderer.Renderer.drawText("Reject", actions.reject.x + 30, actions.reject.y + 6, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    } else if (snap.show_review and !wb.proposal_review_open) {
        wb.agent.lock();
        const review_content = agent_panel.reviewContentHeight(&wb.agent);
        wb.agent.unlock();
        const review_top = chat_top;
        const review_viewport = @max(0, chat_bottom - review_top);
        const review_max = @max(0, review_content - review_viewport);
        const show_review_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, agent_x, review_top, agent_w, review_viewport);
        scrollbar.drawVertical(
            agent_x + agent_w - scrollbar.track_w - 4,
            review_top,
            review_viewport,
            wb.agent.review_scroll_y,
            review_max,
            review_content,
            review_viewport,
            show_review_scroll,
        );
    } else {
        var chat_lines: usize = 0;
        for (state.chat_history.?.items) |msg| {
            if (!agent_panel.chatHasVisibleContent(msg.content)) continue;
            chat_lines += chat_bubble.visualLineCount(msg.content, content_w) + 1;
            if (msg.role == .user) chat_lines += 1;
        }
        if (snap.worker_running) {
            wb.agent.lock();
            chat_lines += chat_bubble.estimateLiveLines(
                wb.agent.thinking_text.items,
                wb.agent.stream_text.items,
                true,
                content_w,
            );
            const steps_h = tool_step_card.totalStepsHeight(wb.agent.agent_steps.items, content_w, snap.mode);
            chat_lines += @as(usize, @intFromFloat(std.math.ceil(steps_h / chat_bubble.line_h)));
            wb.agent.unlock();
        }
        const chat_top_scroll = chat_top;
        const chat_viewport = @max(0, chat_bottom - chat_top_scroll);
        const chat_content = @as(f32, @floatFromInt(@max(1, chat_lines))) * chat_bubble.line_h;
        const chat_max = @max(0, chat_content - chat_viewport);
        const show_chat_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, agent_x, chat_top_scroll, agent_w, chat_viewport);
        scrollbar.drawVertical(
            agent_x + agent_w - scrollbar.track_w - 4,
            chat_top_scroll,
            chat_viewport,
            wb.chat_scroll_y,
            chat_max,
            chat_content,
            chat_viewport,
            show_chat_scroll,
        );
    }

    context_inspector.draw(
        &wb.agent,
        agent_x,
        agent_w,
        h,
        snap.context_used_bytes,
        snap.context_max_bytes,
        snap.context_entry_count,
        snap.context_inspector_expanded,
        snap.attachment_count,
        &wb.prompt_buffer,
        ctx_scroll,
        ctx_selected,
    );

    const show_prompt_cursor = @mod(state.time, 1.0) < 0.5 and wb.focused_panel == .agent and !snap.show_review and !snap.worker_running;
    agent_composer.draw(
        &wb.agent,
        composer_layout,
        wb.ai_model,
        &wb.prompt_buffer,
        wb.prompt_scroll_y,
        show_prompt_cursor,
        snap.worker_running,
        snap.show_review,
    );

    if (snap.show_review and !wb.proposal_review_open) {
        wb.agent.lock();
        const show_rollback = wb.agent.last_checkpoint_id != null;
        const show_approve_spec = wb.agent.spec_pending;
        const accepted = wb.agent.review.acceptedCount();
        const total = wb.agent.review.hunks.len;
        wb.agent.unlock();
        const agent_actions = agent_panel.reviewActions(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer, show_rollback, show_approve_spec);
        renderer.Renderer.drawRoundedRect(agent_actions.apply.x, agent_actions.apply.y, agent_actions.apply.w, agent_actions.apply.h, 6, .{ .r = 0.2, .g = 0.55, .b = 0.35, .a = 1.0 });
        var apply_buf: [32:0]u8 = undefined;
        const apply_label = std.fmt.bufPrint(&apply_buf, "Apply ({d}/{d})", .{ accepted, total }) catch "Apply";
        apply_buf[apply_label.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&apply_buf), agent_actions.apply.x + 8, agent_actions.apply.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(agent_actions.reject.x, agent_actions.reject.y, agent_actions.reject.w, agent_actions.reject.h, 6, .{ .r = 0.45, .g = 0.2, .b = 0.2, .a = 1.0 });
        renderer.Renderer.drawText("Reject all", agent_actions.reject.x + 10, agent_actions.reject.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        if (agent_actions.rollback.w > 0) {
            renderer.Renderer.drawRoundedRect(agent_actions.rollback.x, agent_actions.rollback.y, agent_actions.rollback.w, agent_actions.rollback.h, 6, .{ .r = 0.35, .g = 0.35, .b = 0.45, .a = 1.0 });
            renderer.Renderer.drawText("Rollback", agent_actions.rollback.x + 12, agent_actions.rollback.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        }
        if (agent_actions.approve_spec.w > 0) {
            renderer.Renderer.drawRoundedRect(agent_actions.approve_spec.x, agent_actions.approve_spec.y, agent_actions.approve_spec.w, agent_actions.approve_spec.h, 6, .{ .r = 0.2, .g = 0.4, .b = 0.7, .a = 1.0 });
            renderer.Renderer.drawText("Approve spec", agent_actions.approve_spec.x + 8, agent_actions.approve_spec.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        }
        const hint_y = agent_actions.apply.y - 14;
        renderer.Renderer.drawText("Click hunks to accept/reject — Apply selected", inner_x, hint_y, 10.0, .{ .r = 0.65, .g = 0.65, .b = 0.65, .a = 1.0 });
    } else if (snap.spec_pending) {
        const agent_actions = agent_panel.reviewActions(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer, snap.last_checkpoint_id != null, true);
        if (agent_actions.approve_spec.w > 0) {
            renderer.Renderer.drawRoundedRect(agent_actions.approve_spec.x, agent_actions.approve_spec.y, agent_actions.approve_spec.w, agent_actions.approve_spec.h, 6, .{ .r = 0.2, .g = 0.4, .b = 0.7, .a = 1.0 });
            renderer.Renderer.drawText("Approve spec", agent_actions.approve_spec.x + 8, agent_actions.approve_spec.y + 6, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        }
    }
}

pub fn drawScopePicker(wb: *Workbench, agent_x: f32, agent_w: f32, h: f32) void {
    const pad: f32 = 10;
    renderer.Renderer.drawRect(agent_x, layout.header_height, agent_w, h - layout.header_height - layout.status_height, .{ .r = 0, .g = 0, .b = 0, .a = 0.45 });
    const box_x = agent_x + pad;
    const box_y: f32 = 120;
    const box_w = agent_w - pad * 2;
    const box_h: f32 = 280;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 8, .{ .r = 0.14, .g = 0.16, .b = 0.2, .a = 1.0 });
    renderer.Renderer.drawText("Add file to scope", box_x + 12, box_y + 10, 13.0, .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 });

    wb.agent.lock();
    var query_buf: [320:0]u8 = undefined;
    @memcpy(query_buf[0..wb.agent.scope_query_len], wb.agent.scope_query[0..wb.agent.scope_query_len]);
    query_buf[wb.agent.scope_query_len] = 0;
    const selected = wb.agent.scope_picker_selected;
    wb.agent.unlock();

    renderer.Renderer.drawRoundedRect(box_x + 10, box_y + 32, box_w - 20, 24, 4, .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 });
    renderer.Renderer.drawText(@ptrCast(&query_buf), box_x + 16, box_y + 38, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    var row_y = box_y + 64;
    const max_rows: usize = 12;
    const pinned_count = agent_scope_picker_mod.pinnedVisibleCount(query_buf[0..wb.agent.scope_query_len]);
    var visible_rows: usize = @min(wb.scope_picker_filtered.items.len, max_rows);
    if (pinned_count > 0 and visible_rows + pinned_count <= max_rows) {
        visible_rows += pinned_count;
    } else if (pinned_count > 0) {
        visible_rows = max_rows;
    }

    var draw_index: usize = 0;
    while (draw_index < pinned_count and draw_index < visible_rows) : (draw_index += 1) {
        if (draw_index == selected) {
            renderer.Renderer.drawRoundedRect(box_x + 8, row_y - 2, box_w - 16, 18, 3, .{ .r = 0.22, .g = 0.35, .b = 0.55, .a = 1.0 });
        }
        const label = agent_scope_picker_mod.pinnedLabelAt(query_buf[0..wb.agent.scope_query_len], draw_index) orelse "@pinned";
        var line_buf: [384:0]u8 = undefined;
        @memcpy(line_buf[0..label.len], label);
        line_buf[label.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&line_buf), box_x + 14, row_y, 11.0, .{ .r = 0.75, .g = 0.95, .b = 1.0, .a = 1.0 });
        row_y += 20;
    }

    while (draw_index < visible_rows) : (draw_index += 1) {
        const list_index = draw_index - pinned_count;
        if (list_index >= wb.scope_picker_filtered.items.len) break;
        const path_index = wb.scope_picker_filtered.items[list_index];
        const path = wb.scope_picker_paths.items[path_index];
        if (draw_index == selected) {
            renderer.Renderer.drawRoundedRect(box_x + 8, row_y - 2, box_w - 16, 18, 3, .{ .r = 0.22, .g = 0.35, .b = 0.55, .a = 1.0 });
        }
        var line_buf: [384:0]u8 = undefined;
        var label_buf: [384]u8 = undefined;
        const label = ai.scope_resolver.displayLabel(path, &label_buf);
        const n = @min(label.len, line_buf.len - 1);
        @memcpy(line_buf[0..n], label[0..n]);
        line_buf[n] = 0;
        renderer.Renderer.drawText(@ptrCast(&line_buf), box_x + 14, row_y, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        row_y += 20;
    }
}

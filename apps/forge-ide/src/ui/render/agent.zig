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
const tokens = @import("../tokens.zig");
const agent_scope_picker_mod = @import("../../agent/scope_picker.zig");
const ai = @import("forge-ai");
const diff_line_style = @import("../diff_line_style.zig");

const Workbench = @import("../../workbench.zig").Workbench;
const chat_layout = @import("../../workbench/chat_layout.zig");
const chat_message_lines = @import("../agent/chat_message_lines.zig");

const chat_composer_gap: f32 = tokens.space.lg;

fn phaseShowsLive(phase: anytype) bool {
    return switch (phase) {
        .building_context, .sending, .streaming, .parsing, .waiting_approval => true,
        else => false,
    };
}

pub fn drawAgentPanel(wb: *Workbench, agent_x: f32, agent_w: f32, h: f32) void {
    wb.rendered_code_blocks.clearRetainingCapacity();
    const pad: f32 = tokens.space.xxl;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;
    renderer.Renderer.pushClipRect(agent_x, layout.header_height, agent_w, h - layout.header_height - layout.status_height);
    defer renderer.Renderer.popClipRect();

    var status_copy: [320]u8 = undefined;
    var provider_copy: [128]u8 = undefined;
    const snap = wb.agent.snapshot(&status_copy, &provider_copy);
    chat_layout.ensure(wb, h);
    if (wb.chat_scroll_to_end_on_ready) {
        wb.chat_scroll_to_end_on_ready = false;
        wb.chat_scroll_y = wb.chat_layout.max_scroll;
    } else if (wb.chat_scroll_y > wb.chat_layout.max_scroll) {
        wb.chat_scroll_y = wb.chat_layout.max_scroll;
    }

    const chat_tab_y = layout.header_height;
    renderer.Renderer.drawRect(agent_x, chat_tab_y, agent_w, h - layout.header_height - layout.status_height, tokens.color.surface);
    renderer.Renderer.drawText("Forge Coding", agent_x + tokens.space.xl, chat_tab_y + 18, 13.0, tokens.color.text_secondary);

    const mx = state.last_mouse_x;
    const my = state.last_mouse_y;

    const icon_c = tokens.color.text_muted;
    const hover_c = tokens.color.surface_raised;
    var rx = agent_x + agent_w - 34;

    const icon_y = chat_tab_y + 17;
    const hover_y = chat_tab_y + 14;

    if (mx >= rx and mx < rx + 16 and my >= hover_y and my < hover_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, hover_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.x, rx, icon_y, 16, 16, icon_c);
    rx -= 30;

    if (mx >= rx and mx < rx + 16 and my >= hover_y and my < hover_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, hover_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, rx, icon_y, 16, 16, icon_c);

    const composer_layout = agent_composer.computeLayout(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer);
    wb.clampPromptScroll(agent_w);
    const chat_bottom = composer_layout.composer_top - chat_composer_gap;

    const chat_top = agent_panel.chat_content_top + 8.0;
    const chat_viewport_h = @max(0, chat_bottom - chat_top);
    var content_y: f32 = chat_top - wb.chat_scroll_y;

    {
        renderer.Renderer.pushClipRect(agent_x, chat_top, agent_w, chat_viewport_h);
        defer renderer.Renderer.popClipRect();

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
            content_y += agent_panel.resumeBannerHeight(agent_w, intent, resume_state) + 4;
        }

        const user_style = chat_bubble.BubbleStyle{
            .bg = .{ .r = 0.24, .g = 0.24, .b = 0.25, .a = 1.0 },
            .fg = tokens.color.text_primary,
        };
        const history_prefix = content_y - (chat_top - wb.chat_scroll_y);
        const history_count = wb.chat_history.items.len;
        const start_i = chat_layout.firstVisibleIndex(&wb.chat_layout, wb.chat_scroll_y, history_prefix);
        const base_y = chat_top - wb.chat_scroll_y + history_prefix;
        const end_i = chat_layout.lastVisibleIndex(&wb.chat_layout, wb.chat_scroll_y, history_prefix, chat_viewport_h);
        var msg_i = start_i;
        while (msg_i < history_count and msg_i < end_i) : (msg_i += 1) {
            const msg = wb.chat_history.items[msg_i];
            if (msg.role != .tool and !agent_panel.chatHasVisibleContent(msg.content)) continue;
            if (msg_i >= wb.chat_layout.message_heights.items.len) break;
            const msg_h = wb.chat_layout.message_heights.items[msg_i];
            if (msg_h <= 0) continue;
            const msg_y = base_y + chat_layout.historyYOffset(&wb.chat_layout, msg_i);
            if (msg_y + msg_h < chat_top) continue;
            if (msg_y > chat_bottom) break;
            const line_cache = if (msg_i < wb.chat_layout.message_lines.items.len)
                &wb.chat_layout.message_lines.items[msg_i]
            else
                @as(?*const chat_message_lines.Entry, null);
            switch (msg.role) {
                .user => _ = chat_bubble.drawBubbleWithCache(wb.allocator, agent_x, inner_x, content_w, msg_y, null, msg.content, user_style, line_cache, wb, msg_i),
                .agent => _ = chat_bubble.drawAgentMessageWithCache(wb.allocator, inner_x, content_w, msg_y, msg.content, chat_bubble.agent_text_style, line_cache, wb, msg_i),
                .tool => {
                    var step = chat_layout.toolStepFromMessage(msg);
                    _ = tool_step_card.drawStep(
                        agent_x,
                        inner_x,
                        content_w,
                        msg_y,
                        step[0..],
                        0,
                        wb.allocator,
                        state.time,
                        snap.mode,
                        wb,
                        msg_i,
                    );
                },
            }
        }
        content_y = base_y + wb.chat_layout.history_content_h;

        const live_active = snap.worker_running or phaseShowsLive(snap.phase);
        if (live_active) {
            wb.agent.lock();
            defer wb.agent.unlock();

            const thinking_src = wb.agent.thinking_text.items;
            const stream_src = wb.agent.stream_text.items;

            if (stream_src.len == 0) {
                const thinking_label = if (thinking_src.len > 0) thinking_src else snap.status_line;
                content_y += chat_bubble.drawThinkingLine(inner_x, content_y, thinking_label, state.time);
            } else {
                content_y += chat_bubble.drawAgentMessageWithCache(
                    wb.allocator,
                    inner_x,
                    content_w,
                    content_y,
                    stream_src,
                    chat_bubble.agent_text_style,
                    &wb.chat_layout.stream_entry,
                    wb,
                    wb.chat_history.items.len,
                );
            }
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

            var review_y = content_y;
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
                    const default_fg = renderer.Color{ .r = 0.75, .g = 0.75, .b = 0.75, .a = if (accepted) 1.0 else 0.45 };
                    diff_line_style.drawLine(line, inner_x + 6, line_y, content_w - 16, 12.0, 9.5, accepted, default_fg);
                    line_y += 12.0;
                }
                review_y += block_h + 6.0;
            }
            wb.agent.unlock();
            content_y = review_y;
        }
    }

    if (snap.approval_pending) {
        wb.agent.lock();
        const tool = wb.agent.approval_tool orelse "unknown tool";
        const risk = wb.agent.approval_risk orelse "unknown";
        const args = wb.agent.approval_args orelse "{}";
        const is_review = snap.approval_kind == .review;
        wb.agent.unlock();
        agent_panel.drawApprovalOverlay(
            agent_x,
            agent_w,
            h,
            snap.attachment_count,
            &wb.prompt_buffer,
            tool,
            risk,
            args,
            is_review,
        );
    }

    if (snap.approval_pending) {
        const actions = agent_panel.approvalActions(agent_x, agent_w, h, snap.attachment_count, &wb.prompt_buffer);
        renderer.Renderer.drawRoundedRect(actions.approve.x, actions.approve.y, actions.approve.w, actions.approve.h, 6, .{ .r = 0.2, .g = 0.55, .b = 0.35, .a = 1.0 });
        renderer.Renderer.drawText("Approve once", actions.approve.x + 10, actions.approve.y + 6, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
        renderer.Renderer.drawRoundedRect(actions.reject.x, actions.reject.y, actions.reject.w, actions.reject.h, 6, .{ .r = 0.5, .g = 0.2, .b = 0.2, .a = 1.0 });
        renderer.Renderer.drawText("Reject", actions.reject.x + 30, actions.reject.y + 6, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
        renderer.Renderer.drawRoundedRect(actions.approve_always.x, actions.approve_always.y, actions.approve_always.w, actions.approve_always.h, 6, .{ .r = 0.2, .g = 0.35, .b = 0.55, .a = 1.0 });
        renderer.Renderer.drawText("Always Approve", actions.approve_always.x + 10, actions.approve_always.y + 6, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    } else {
        const chat_top_scroll = chat_top;
        const chat_viewport = @max(0, chat_bottom - chat_top_scroll);
        const chat_content = wb.chat_layout.content_h;
        const chat_max = wb.chat_layout.max_scroll;
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

    const show_prompt_cursor = @mod(state.time, 1.0) < 0.5 and wb.focused_panel == .agent and !snap.show_review and !snap.worker_running;
    agent_composer.draw(
        &wb.agent,
        composer_layout,
        wb.ai_model,
        wb.ai_provider,
        wb.ai_models,
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

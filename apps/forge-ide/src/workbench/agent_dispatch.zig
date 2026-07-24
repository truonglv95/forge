const std = @import("std");
const workspace = @import("forge-workspace");
const agent_workflow = @import("../agent/workflow.zig");
const commands_mod = @import("commands.zig");
const agent_ops = @import("agent_ops.zig");
const agent_prompt_ops = @import("agent_prompt_ops.zig");

const Command = commands_mod.Command;

pub fn dispatch(wb: anytype, command: Command) !void {
    switch (command) {
        .agent_set_mode => |mode| {
            wb.agent_ui.session.lock();
            wb.agent_ui.session.mode = mode;
            wb.agent_ui.session.mode_menu_open = false;
            wb.agent_ui.session.unlock();
            const label = switch (mode) {
                .ask => "Ask mode",
                .plan => "Plan mode",
                .agent => "Agent mode",
            };
            try wb.setStatus(label);
        },
        .agent_submit => try agent_prompt_ops.submitAgentPrompt(wb),
        .agent_edit_selection => try agent_prompt_ops.editSelectedCodeWithAgent(wb),
        .agent_cancel => {
            agent_workflow.cancel(&agent_ops.agentHost(wb));
            try wb.setStatus("Cancelling agent...");
        },
        .agent_apply => {
            const tx_id = try agent_workflow.applyCurrentProposal(&agent_ops.agentHost(wb));
            agent_ops.closeProposalReview(wb);
            var buf: [64]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Applied transaction {d}", .{tx_id});
            try wb.setStatus(msg);
            try agent_ops.appendChat(wb, .agent, "Changes applied to workspace.");
        },
        .agent_rollback => {
            try agent_workflow.rollbackLastCheckpoint(&agent_ops.agentHost(wb));
            agent_ops.closeProposalReview(wb);
            try agent_ops.appendChat(wb, .agent, "Rolled back to pre-apply checkpoint.");
            try wb.setStatus("Checkpoint restored");
        },
        .agent_dismiss_apply => {
            wb.agent_ui.session.dismissPostApplyBanner();
            try wb.setStatus("Changes kept");
        },
        .agent_approve_spec => {
            try agent_workflow.approveSpecAndGenerate(&agent_ops.agentHost(wb));
            try wb.setStatus("Spec approved - generating proposal...");
        },
        .agent_approve_tool => {
            wb.agent_ui.session.resolveToolApproval(true);
            try wb.setStatus("Tool approved - continuing agent...");
        },
        .agent_approve_always_tool => {
            wb.agent_ui.session.lock();
            wb.agent_ui.session.always_approve_tools = true;
            wb.agent_ui.session.unlock();
            wb.agent_ui.session.resolveToolApproval(true);
            try wb.setStatus("Always approve enabled - continuing agent...");
        },
        .agent_reject_tool => {
            wb.agent_ui.session.resolveToolApproval(false);
            try wb.setStatus("Tool rejected");
        },
        .agent_continue_session => {
            wb.agent_ui.session.lock();
            const kind = wb.agent_ui.session.resume_offer_kind;
            const session_id = if (wb.agent_ui.session.resume_session_id) |id| try wb.allocator.dupe(u8, id) else null;
            wb.agent_ui.session.unlock();
            if (session_id) |id| {
                defer wb.allocator.free(id);
                switch (kind) {
                    .continue_run => agent_workflow.spawnResumeSession(&agent_ops.agentHost(wb), id) catch |err| {
                        try wb.setStatus(agent_workflow.agentFailureMessage(err));
                    },
                    .review_proposal => {
                        agent_workflow.openStoredProposal(&agent_ops.agentHost(wb), id) catch |err| {
                            try wb.setStatus(agent_workflow.agentFailureMessage(err));
                            return;
                        };
                        agent_ops.openProposalReview(wb);
                    },
                }
            }
        },
        .agent_dismiss_resume => {
            agent_workflow.dismissResumeOffer(&agent_ops.agentHost(wb));
            try wb.setStatus("Resume offer dismissed");
        },
        .agent_reject => {
            agent_workflow.rejectCurrentProposal(&agent_ops.agentHost(wb));
            agent_ops.closeProposalReview(wb);
            try agent_ops.appendChat(wb, .agent, "Proposal rejected.");
            try wb.setStatus("Proposal rejected");
        },
        .agent_show_review => try agent_ops.showAgentReview(wb),
        .agent_toggle_step => |index| {
            wb.agent_ui.session.lock();
            if (index < wb.agent_ui.session.agent_steps.items.len) {
                const step = &wb.agent_ui.session.agent_steps.items[index];
                step.expanded = !step.expanded;
                wb.agent_ui.session.agent_steps_revision += 1;
            }
            wb.agent_ui.session.unlock();
        },
        .agent_select_run => |index| {
            wb.agent_ui.session.lock();
            if (index < wb.agent_ui.session.run_history.items.len) {
                wb.agent_ui.session.selected_run_index = index;
                const entry = wb.agent_ui.session.run_history.items[index];
                if (wb.agent_ui.session.run_id) |old| wb.allocator.free(old);
                wb.agent_ui.session.run_id = wb.allocator.dupe(u8, entry.run_id) catch null;
                if (wb.agent_ui.session.proposal_rel) |old| wb.allocator.free(old);
                const sess_dir = workspace.global_store.getSessionDir(wb.allocator, wb.io, wb.workspace_root) catch null;
                if (sess_dir) |sd| {
                    defer wb.allocator.free(sd);
                    const proposal_abs = std.fmt.allocPrint(wb.allocator, "{s}/proposals/{s}.json", .{ sd, entry.run_id }) catch null;
                    wb.agent_ui.session.proposal_rel = proposal_abs;
                } else {
                    wb.agent_ui.session.proposal_rel = std.fmt.allocPrint(wb.allocator, ".forge/proposals/{s}.json", .{entry.run_id}) catch null;
                }
            }
            wb.agent_ui.session.unlock();
            if (wb.agent_ui.session.proposal_rel) |rel| {
                agent_workflow.loadProposalPreview(&agent_ops.agentHost(wb), rel) catch |err| {
                    wb.logBackgroundError("Load selected AI proposal", err);
                    return;
                };
                agent_ops.openProposalReview(wb);
            }
        },
        .agent_refresh_runs => try agent_workflow.refreshRunHistory(&agent_ops.agentHost(wb)),
        .agent_add_scope => |path| {
            try wb.agent_ui.session.addScopeFile(path);
            agent_ops.refreshAgentContextPreview(wb);
        },
        .agent_remove_scope => |path| {
            wb.agent_ui.session.removeScopeFile(path);
            agent_ops.refreshAgentContextPreview(wb);
        },
        .agent_clear_scope => {
            wb.agent_ui.session.clearScope();
            agent_ops.refreshAgentContextPreview(wb);
        },
        .agent_scope_picker_open => try agent_ops.openScopePicker(wb),
        .agent_scope_picker_close => wb.agent_ui.session.closeScopePicker(),
        .agent_scope_picker_select => try agent_ops.selectScopePickerEntry(wb),
        .agent_toggle_context_inspector => wb.agent_ui.session.toggleContextInspector(),
        .agent_toggle_mode_menu => wb.agent_ui.session.toggleModeMenu(),
        .agent_toggle_model_menu => wb.agent_ui.session.toggleModelMenu(),
        .agent_close_menus => wb.agent_ui.session.closeMenus(),
        .agent_set_model => |index| try agent_ops.setAgentModelIndex(wb, index),
        .agent_remove_attachment => |index| {
            wb.agent_ui.session.removeAttachment(index);
            agent_ops.refreshAgentContextPreview(wb);
            try wb.setStatus("Attachment removed");
        },
        .agent_copy_message => |index| {
            if (index < wb.agent_ui.chat_history.items.len) {
                const text = wb.agent_ui.chat_history.items[index].content;
                @import("forge-renderer").Renderer.setClipboardText(text);
                try wb.setStatus("Message copied to clipboard");
            }
        },
        .agent_open_message => |index| try agent_prompt_ops.openChatMessageAsMarkdown(wb, index),
        else => unreachable,
    }
}

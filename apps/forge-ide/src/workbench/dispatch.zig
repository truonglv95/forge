const std = @import("std");
const editor = @import("forge-editor");
const workspace = @import("forge-workspace");
const plugin = @import("forge-plugin");
const workspace_io = @import("../workspace_io.zig");
const explorer_ops = @import("../explorer/ops.zig");
const recovery_mod = @import("recovery.zig");
const agent_workflow = @import("../agent/workflow.zig");
const tasks_mod = @import("tasks.zig");
const commands_mod = @import("commands.zig");
const Command = commands_mod.Command;

pub fn dispatch(wb: anytype, command: Command) !void {
    switch (command) {
        .open_file => |path| try wb.openFile(path),
        .activate_tab => |index| try wb.activateTab(index),
        .close_tab => |index| try wb.closeTabAt(index),
        .close_active_tab => try wb.closeTabAt(wb.tabs.active),
        .close_all_tabs => {
            wb.tabs.closeAll();
            wb.tab_scroll_x = 0;
        },
        .reload_theme => try wb.reloadTheme(),
        .save_active => {
            const doc = wb.tabs.activeDoc() orelse return;
            if (doc.external_conflict) {
                try wb.openConflictDialog(doc.path);
                return;
            }
            try workspace_io.saveDocument(wb.io, wb.workspace_root, doc);
            try recovery_mod.snapshotDirtyDocs(wb.allocator, wb.io, wb.workspace_root, &wb.tabs);
            workspace.hooks.runOnSave(wb.allocator, wb.io, wb.workspace_root, doc.path, wb.workspace_path) catch {};
            try wb.events.publish(.{ .file_saved = doc.path });
            if (std.mem.eql(u8, doc.path, ".forge/settings.toml")) {
                try wb.reloadUserSettings();
            }
            try wb.setStatus("Saved");
        },
        .explorer_toggle => |path| {
            try wb.explorer.toggleExpand(path);
        },
        .explorer_select => |path| try wb.explorer.select(path),
        .explorer_create_file => |name| {
            const parent = wb.explorer.selectedOrRoot();
            const created = try explorer_ops.createFileAlloc(wb.allocator, wb.io, wb.workspace_root, parent, name);
            try wb.explorer.rebuild(wb.io, wb.workspace_root);
            try wb.explorer.select(created);
            const open_path = try wb.allocator.dupe(u8, created);
            wb.allocator.free(created);
            try dispatch(wb, .{ .open_file = open_path });
            wb.allocator.free(open_path);
            try wb.events.publish(.{ .explorer_refreshed = {} });
        },
        .explorer_create_folder => |name| {
            const parent = wb.explorer.selectedOrRoot();
            const created = try explorer_ops.createFolder(wb.allocator, wb.io, wb.workspace_root, parent, name);
            defer wb.allocator.free(created);
            try wb.explorer.rebuild(wb.io, wb.workspace_root);
            try wb.explorer.select(created);
            try wb.events.publish(.{ .explorer_refreshed = {} });
        },
        .explorer_rename => |payload| {
            const old_path = wb.explorer.selected_path orelse return;
            const new_path = try explorer_ops.renameEntry(wb.allocator, wb.io, wb.workspace_root, old_path, payload.new_name);
            defer wb.allocator.free(new_path);
            try wb.updateTabPath(old_path, new_path);
            if (wb.explorer.selected_path) |sel| wb.allocator.free(sel);
            wb.explorer.selected_path = try wb.allocator.dupe(u8, new_path);
            wb.renaming = false;
            try wb.explorer.rebuild(wb.io, wb.workspace_root);
            try wb.events.publish(.{ .explorer_refreshed = {} });
        },
        .explorer_begin_rename => {
            const path = wb.explorer.selected_path orelse return;
            wb.renaming = true;
            try wb.rename_buffer.loadFromSlice(std.fs.path.basename(path));
        },
        .explorer_delete_selected => {
            const path = wb.explorer.selected_path orelse return;
            const kind = wb.explorerKind(path) orelse return;
            try explorer_ops.deleteEntry(wb.io, wb.workspace_root, path, kind);
            if (wb.explorer.selected_path) |sel| wb.allocator.free(sel);
            wb.explorer.selected_path = null;
            try wb.explorer.rebuild(wb.io, wb.workspace_root);
            try wb.events.publish(.{ .explorer_refreshed = {} });
        },
        .run_extension_command => |command_id| try wb.extension_host.executeCommand(command_id),
        .reload_extensions => try wb.reloadExtensions(),
        .set_sidebar_view => |view| {
            if (view == .ai) {
                try wb.openAiSettings();
                return;
            }
            wb.sidebar_view = view;
            wb.focused_panel = switch (view) {
                .explorer => .explorer,
                .search => .search,
                .git => .git,
                .run => .run,
                .extensions => .extensions,
                .ai => .ai_settings,
            };
            if (view == .git) try wb.refreshGitStatus();
        },
        .extension_toggle => |index| {
            if (index >= wb.extension_host.extensions.items.len) return;
            const ext = &wb.extension_host.extensions.items[index];
            if (ext.active) {
                try wb.extension_host.deactivateExtension(ext.id);
                try wb.setStatus("Extension deactivated");
            } else {
                try wb.extension_host.activateExtension(ext.id);
                try wb.setStatus("Extension activated");
            }
            wb.selected_extension_index = index;
        },
        .open_extensions_dir => |path| {
            const global_store = @import("forge-workspace").global_store;
            if (path.len == 0) {
                if (global_store.getExtensionsDir(wb.allocator)) |global_ext| {
                    defer wb.allocator.free(global_ext);
                    const readme_path = std.fmt.allocPrint(wb.allocator, "{s}/README.md", .{global_ext}) catch return;
                    try wb.dispatch(.{ .open_file = readme_path });
                } else |_| {}
            } else {
                const doc = try wb.tabs.openOrActivate(path);
                try workspace_io.loadDocument(wb.io, wb.workspace_root, doc);
            }
            wb.sidebar_view = .extensions;
            wb.focused_panel = .extensions;
            wb.syncTabScroll();
        },
        .set_extensions_panel_mode => |mode| {
            wb.extensions_panel_mode = mode;
            wb.extensions_scroll_y = 0;
            wb.extensions_detail_index = null;
        },
        .install_marketplace_extension => |extension_id| {
            const catalog = wb.marketplace_catalog orelse {
                try wb.setStatus("Marketplace catalog not loaded");
                return;
            };
            const entry = plugin.marketplace.findEntry(&catalog, extension_id) orelse {
                try wb.setStatus("Extension not found in catalog");
                return;
            };
            const installed = try plugin.marketplace.install(wb.allocator, wb.io, wb.workspace_root, entry);
            defer wb.allocator.free(installed);
            try wb.reloadExtensions();
            try wb.setStatus("Extension installed");
        },
        .apply_extension_theme => |qualified| {
            if (wb.active_extension_theme.len > 0) wb.allocator.free(wb.active_extension_theme);
            wb.active_extension_theme = try wb.allocator.dupe(u8, qualified);
            try wb.persistExtensionTheme(qualified);
            try wb.reloadTheme();
            try wb.setStatus("Extension theme applied");
        },
        .refresh_explorer => {
            try wb.explorer.rebuild(wb.io, wb.workspace_root);
            try wb.events.publish(.{ .explorer_refreshed = {} });
        },
        .run_task => |task_name| {
            wb.references.clear();
            if (wb.task_output.isRunning()) {
                try wb.setStatus("Task already running");
                return;
            }
            wb.task_output.clear();
            wb.task_output.setRunning(true);
            const Wb = @TypeOf(wb.*);
            try tasks_mod.spawn(
                wb.allocator,
                wb.io,
                task_name,
                wb.workspace_path,
                Wb.onTaskLine,
                Wb.onTaskFinished,
                wb,
            );
        },
        .check_external_conflicts => {
            for (wb.tabs.tabs.items) |*doc| {
                try doc.checkExternalConflict(wb.io, wb.workspace_root);
                if (doc.external_conflict and !doc.isDirty()) {
                    try workspace_io.loadDocument(wb.io, wb.workspace_root, doc);
                }
            }
            if (wb.tabs.activeDoc()) |doc| {
                if (doc.external_conflict) try wb.openConflictDialog(doc.path);
            }
            try wb.setStatus("Checked external changes");
        },
        .reload_active_from_disk => {
            const doc = wb.tabs.activeDoc() orelse return;
            try workspace_io.loadDocument(wb.io, wb.workspace_root, doc);
            try wb.closeConflictDialog();
            try wb.setStatus("Reloaded from disk");
        },
        .dismiss_external_conflict => {
            if (wb.tabs.activeDoc()) |doc| doc.external_conflict = false;
            try wb.closeConflictDialog();
            try wb.setStatus("Keeping local version");
        },
        .restore_recovery_snapshots => {
            try wb.restoreRecoverySnapshots();
            wb.recovery_count = 0;
            wb.focused_panel = wb.previous_focus;
            try wb.setStatus("Restored recovery snapshots");
        },
        .discard_recovery_snapshots => {
            try wb.discardRecoverySnapshots();
            wb.recovery_count = 0;
            wb.focused_panel = wb.previous_focus;
            try wb.setStatus("Discarded recovery snapshots");
        },
        .palette_open => {
            wb.previous_focus = wb.focused_panel;
            wb.focused_panel = .palette;
            try wb.palette.openPalette();
        },
        .palette_close => {
            wb.palette.close();
            wb.focused_panel = wb.previous_focus;
        },
        .workspace_symbol_picker_open => {
            wb.previous_focus = wb.focused_panel;
            wb.focused_panel = .palette; // Reuse palette focus for keys? Or create new? Let's use a new focus if needed, wait, let's reuse palette focus but we need to route it.
            // Wait, we need a separate focus for workspace_symbol_picker, or just check if it's open.
            // I'll add .workspace_symbol_picker to PanelFocus later if needed, but for now just use .editor and check if open?
            // Actually, we can just use a flag. Let's look at scope_picker.
            try wb.workspace_symbol_picker.openPicker();
        },
        .workspace_symbol_picker_close => {
            wb.workspace_symbol_picker.close();
        },
        .workspace_symbol_picker_select => {
            if (wb.workspace_symbol_picker.entries.items.len > 0) {
                const entry = wb.workspace_symbol_picker.entries.items[wb.workspace_symbol_picker.selected];
                wb.dispatch(.{ .open_file = entry.location.uri }) catch {};

                // Then goto line
                const line = entry.location.line;
                const character = entry.location.character;
                if (wb.tabs.activeDoc()) |doc| {
                    if (doc.buffer.lines.items.len > line) {
                        doc.buffer.cursor.row = line;
                        doc.buffer.cursor.col = character;
                        doc.buffer.selection_anchor = null;
                        wb.dispatch(.editor_scroll_to_cursor) catch {};
                    }
                }
            }
            wb.workspace_symbol_picker.close();
        },
        .agent_set_mode => |mode| {
            wb.agent.lock();
            wb.agent.mode = mode;
            wb.agent.mode_menu_open = false;
            wb.agent.unlock();
            const label = switch (mode) {
                .ask => "Ask mode",
                .plan => "Plan mode",
                .agent => "Agent mode",
            };
            try wb.setStatus(label);
        },
        .agent_submit => {
            const prompt_text = try wb.prompt_buffer.content();
            defer wb.prompt_buffer.allocator.free(prompt_text);
            const trimmed = std.mem.trim(u8, prompt_text, &std.ascii.whitespace);
            if (trimmed.len == 0) return;
            const owned_prompt = try wb.allocator.dupe(u8, trimmed);
            defer wb.allocator.free(owned_prompt);

            wb.prompt_buffer.deinit();
            wb.prompt_buffer = try editor.Buffer.init(wb.allocator);
            wb.prompt_scroll_y = 0;
            wb.focused_panel = .agent;

            try wb.appendChat(.user, owned_prompt);
            wb.chat_follow_stream = true;
            const active = wb.tabs.activeDoc();
            const active_path = if (active) |doc| doc.path else null;
            const scope = wb.agent.effectiveScope(active_path);
            agent_workflow.spawnGenerate(&wb.agentHost(), owned_prompt, scope, active_path) catch |err| {
                const msg = switch (err) {
                    error.AgentBusy => "Agent is already running",
                    else => "Agent failed to start",
                };
                try wb.setStatus(msg);
                return;
            };
            wb.chat_scroll_to_end_on_ready = true;
            try wb.setStatus("Agent: building context…");
        },
        .agent_edit_selection => {
            const doc = wb.tabs.activeDoc() orelse {
                try wb.setStatus("No active file");
                return;
            };
            const selection = doc.buffer.selectedText(wb.allocator) catch {
                try wb.setStatus("Failed to read selection");
                return;
            };
            defer wb.allocator.free(selection);
            if (selection.len == 0) {
                try wb.setStatus("Select code first (drag in editor)");
                return;
            }

            const prompt_text = wb.prompt_buffer.content() catch {
                try wb.setStatus("Failed to read prompt");
                return;
            };
            defer wb.prompt_buffer.allocator.free(prompt_text);
            const user_part = std.mem.trim(u8, prompt_text, &std.ascii.whitespace);

            const intent = if (user_part.len > 0)
                try std.fmt.allocPrint(wb.allocator, "Edit the selected code in {s}.\n\nRequest: {s}\n\nSelected code:\n```\n{s}\n```", .{ doc.path, user_part, selection })
            else
                try std.fmt.allocPrint(wb.allocator, "Edit the selected code in {s}.\n\n```\n{s}\n```\n\nImprove or fix as needed.", .{ doc.path, selection });
            defer wb.allocator.free(intent);

            wb.prompt_buffer.deinit();
            wb.prompt_buffer = try editor.Buffer.init(wb.allocator);
            wb.prompt_scroll_y = 0;
            wb.focused_panel = .agent;
            wb.agent.lock();
            wb.agent.mode = .agent;
            wb.agent.unlock();

            try wb.appendChat(.user, intent);
            wb.chat_follow_stream = true;

            const scope = try wb.allocator.alloc([]const u8, 1);
            defer wb.allocator.free(scope);
            scope[0] = try wb.allocator.dupe(u8, doc.path);
            defer wb.allocator.free(scope[0]);

            agent_workflow.spawnGenerate(&wb.agentHost(), intent, scope, doc.path) catch |err| {
                const msg = switch (err) {
                    error.AgentBusy => "Agent is already running",
                    else => "Agent failed to start",
                };
                try wb.setStatus(msg);
                return;
            };
            try wb.setStatus("Agent: editing selection…");
        },
        .agent_cancel => {
            agent_workflow.cancel(&wb.agentHost());
            try wb.setStatus("Cancelling agent...");
        },
        .agent_apply => {
            const tx_id = try agent_workflow.applyCurrentProposal(&wb.agentHost());
            wb.closeProposalReview();
            var buf: [64]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Applied transaction {d}", .{tx_id});
            try wb.setStatus(msg);
            try wb.appendChat(.agent, "Changes applied to workspace.");
        },
        .agent_rollback => {
            try agent_workflow.rollbackLastCheckpoint(&wb.agentHost());
            wb.closeProposalReview();
            try wb.appendChat(.agent, "Rolled back to pre-apply checkpoint.");
            try wb.setStatus("Checkpoint restored");
        },
        .agent_dismiss_apply => {
            wb.agent.dismissPostApplyBanner();
            try wb.setStatus("Changes kept");
        },
        .agent_approve_spec => {
            try agent_workflow.approveSpecAndGenerate(&wb.agentHost());
            try wb.setStatus("Spec approved — generating proposal...");
        },
        .agent_approve_tool => {
            wb.agent.resolveToolApproval(true);
            try wb.setStatus("Tool approved — continuing agent...");
        },
        .agent_approve_always_tool => {
            wb.agent.lock();
            wb.agent.always_approve_tools = true;
            wb.agent.unlock();
            wb.agent.resolveToolApproval(true);
            try wb.setStatus("Always approve enabled — continuing agent...");
        },
        .agent_reject_tool => {
            wb.agent.resolveToolApproval(false);
            try wb.setStatus("Tool rejected");
        },
        .agent_continue_session => {
            wb.agent.lock();
            const kind = wb.agent.resume_offer_kind;
            const session_id = if (wb.agent.resume_session_id) |id| try wb.allocator.dupe(u8, id) else null;
            wb.agent.unlock();
            if (session_id) |id| {
                defer wb.allocator.free(id);
                switch (kind) {
                    .continue_run => agent_workflow.spawnResumeSession(&wb.agentHost(), id) catch |err| {
                        try wb.setStatus(agent_workflow.agentFailureMessage(err));
                    },
                    .review_proposal => {
                        agent_workflow.openStoredProposal(&wb.agentHost(), id) catch |err| {
                            try wb.setStatus(agent_workflow.agentFailureMessage(err));
                            return;
                        };
                        wb.openProposalReview();
                    },
                }
            }
        },
        .agent_dismiss_resume => {
            agent_workflow.dismissResumeOffer(&wb.agentHost());
            try wb.setStatus("Resume offer dismissed");
        },
        .agent_reject => {
            agent_workflow.rejectCurrentProposal(&wb.agentHost());
            wb.closeProposalReview();
            try wb.appendChat(.agent, "Proposal rejected.");
            try wb.setStatus("Proposal rejected");
        },
        .agent_show_review => try wb.showAgentReview(),
        .agent_toggle_step => |index| {
            wb.agent.lock();
            if (index < wb.agent.agent_steps.items.len) {
                const step = &wb.agent.agent_steps.items[index];
                step.expanded = !step.expanded;
            }
            wb.agent.unlock();
        },
        .agent_select_run => |index| {
            wb.agent.lock();
            if (index < wb.agent.run_history.items.len) {
                wb.agent.selected_run_index = index;
                const entry = wb.agent.run_history.items[index];
                if (wb.agent.run_id) |old| wb.allocator.free(old);
                wb.agent.run_id = wb.allocator.dupe(u8, entry.run_id) catch null;
                if (wb.agent.proposal_rel) |old| wb.allocator.free(old);
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const proposal_rel = std.fmt.bufPrint(&path_buf, ".forge/proposals/{s}.json", .{entry.run_id}) catch "";
                wb.agent.proposal_rel = wb.allocator.dupe(u8, proposal_rel) catch null;
            }
            wb.agent.unlock();
            if (wb.agent.proposal_rel) |rel| {
                agent_workflow.loadProposalPreview(&wb.agentHost(), rel) catch {};
                wb.openProposalReview();
            }
        },
        .agent_refresh_runs => try agent_workflow.refreshRunHistory(&wb.agentHost()),
        .agent_add_scope => |path| {
            try wb.agent.addScopeFile(path);
            wb.refreshAgentContextPreview();
        },
        .agent_remove_scope => |path| {
            wb.agent.removeScopeFile(path);
            wb.refreshAgentContextPreview();
        },
        .agent_clear_scope => {
            wb.agent.clearScope();
            wb.refreshAgentContextPreview();
        },
        .agent_scope_picker_open => try wb.openScopePicker(),
        .agent_scope_picker_close => wb.agent.closeScopePicker(),
        .agent_scope_picker_select => try wb.selectScopePickerEntry(),
        .agent_toggle_context_inspector => wb.agent.toggleContextInspector(),
        .agent_toggle_mode_menu => wb.agent.toggleModeMenu(),
        .agent_toggle_model_menu => wb.agent.toggleModelMenu(),
        .agent_close_menus => wb.agent.closeMenus(),
        .agent_set_model => |index| try wb.setAgentModelIndex(index),
        .agent_remove_attachment => |index| {
            wb.agent.removeAttachment(index);
            wb.refreshAgentContextPreview();
            try wb.setStatus("Attachment removed");
        },
        .set_shell_mode => |mode| {
            wb.shell_mode = mode;
            if (mode == .agent_window) wb.focused_panel = .agent;
            try wb.setStatus(switch (mode) {
                .ide => "IDE mode",
                .agent_window => "Agent window",
            });
        },
        .toggle_shell_mode => {
            wb.shell_mode = if (wb.shell_mode == .ide) .agent_window else .ide;
            if (wb.shell_mode == .agent_window) wb.focused_panel = .agent;
            try wb.setStatus(switch (wb.shell_mode) {
                .ide => "IDE mode",
                .agent_window => "Agent window",
            });
        },
        .search_run => try wb.runSearch(),
        .git_refresh => try wb.refreshGitStatus(),
        .uninstall_extension => |extension_id| {
            try plugin.marketplace.uninstall(wb.allocator, wb.io, wb.workspace_root, extension_id);
            try wb.reloadExtensions();
            wb.extensions_detail_index = null;
            try wb.setStatus("Extension uninstalled");
        },
        .extensions_show_detail => |index| {
            wb.extensions_detail_index = index;
            wb.extensions_scroll_y = 0;
        },
        .extensions_back_from_detail => {
            wb.extensions_detail_index = null;
            wb.extensions_scroll_y = 0;
        },
        .set_bottom_panel_mode => |mode| {
            wb.bottom_panel_mode = mode;
            wb.task_scroll_y = 0;
            if (mode == .terminal) {
                wb.focused_panel = .terminal;
                wb.terminal_boot_pending = true;
            }
        },
        .terminal_submit => {
            try wb.refreshGitStatus();
            try wb.updateTerminalPrompt();
        },
        .terminal_new => {
            try wb.terminals.addSession();
            wb.bottom_panel_mode = .terminal;
            wb.focused_panel = .terminal;
            wb.terminal_boot_pending = true;
            try wb.setStatus("New terminal");
        },
        .terminal_close => {
            if (wb.terminals.closeActive()) {
                try wb.setStatus("Terminal closed");
            }
        },
        .terminal_next => {
            wb.terminals.next();
            wb.syncTerminalSize();
        },
        .terminal_prev => {
            wb.terminals.prev();
            wb.syncTerminalSize();
        },
        .terminal_activate => |index| {
            wb.terminals.activate(index);
            wb.syncTerminalSize();
        },
        .debug_toggle_breakpoint => try wb.toggleBreakpointAtCursor(),
        .debug_clear_breakpoints => {
            wb.breakpoints.clear();
            try wb.debug_console.log("Breakpoints cleared");
        },
        .rename_accept => try wb.acceptRenamePreview(),
        .rename_reject => wb.rejectRenamePreview(),
        .debug_run_launch => |index| try wb.runLaunchConfig(index),
        .debug_clear_console => wb.debug_console.clear(),
        .debug_continue => try wb.debugContinue(),
        .debug_step_over => try wb.debugStepOver(),
        .debug_step_into => try wb.debugStepInto(),
        .debug_step_out => try wb.debugStepOut(),
        .debug_stop => wb.debugStop(),
        .editor_completion => {
            if (wb.tabs.activeDoc()) |doc| wb.completions.requestForDocument(doc);
        },
        .editor_find => try wb.openEditorFind(false),
        .editor_replace => try wb.openEditorFind(true),
        .editor_goto_line => try wb.openGotoLine(),
        .editor_find_next => try wb.findNextMatch(),
        .editor_find_prev => try wb.findPrevMatch(),
        .editor_find_close => wb.closeEditorOverlay(),
        .editor_redo => {
            if (wb.activeBuffer()) |buf| try buf.redo();
        },
        .editor_undo => {
            if (wb.activeBuffer()) |buf| try buf.undo();
        },
        .editor_scroll_to_cursor => wb.scrollEditorToCursor(),
        .editor_go_to_definition => try wb.goToDefinition(),
        .editor_find_references => try wb.findReferences(),
        .editor_rename_symbol => try wb.openRenameSymbol(),
        .editor_format_document => try wb.formatDocument(),
        .editor_split_right => try wb.splitEditorRight(),
        .editor_close_split => try wb.closeEditorSplit(),
        .editor_accept_inline_edit => {
            if (wb.tabs.activeDoc()) |doc| {
                try doc.buffer.acceptInlineEdit();
            }
        },
        .editor_reject_inline_edit => {
            if (wb.tabs.activeDoc()) |doc| {
                try doc.buffer.rejectInlineEdit();
            }
        },
        .references_goto => |index| try wb.gotoReference(index),
        .problems_goto => |index| try wb.gotoProblem(index),
        .completion_accept => {
            if (wb.tabs.activeDoc()) |doc| try wb.completions.acceptSelected(doc);
        },
        .completion_dismiss => wb.completions.dismiss(),
        .save_session_state => try wb.persistSessionState(),
        .restore_session_state => try wb.restoreSessionTabs(),
        .settings_reload => try wb.reloadUserSettings(),
        .settings_toggle_word_wrap => try wb.toggleWordWrap(),
        .open_recent_workspace => |index| try wb.openRecentWorkspace(index),
        .problem_quick_fix => try wb.quickFixAtCursor(),
        .debug_stack_goto => |index| try wb.gotoDebugStackFrame(index),
        .debug_copy_variable => |index| try wb.copyDebugVariable(index),
        .ai_open_forge_toml => try wb.openForgeToml(),
        .ai_open_mcp_config => try wb.openMcpConfig(),
        .ai_toggle_mcp => try wb.toggleAiMcp(),
        .ai_refresh_mcp => try wb.refreshAiMcpStatus(),
        .toggle_sidebar => wb.sidebar_visible = !wb.sidebar_visible,
        .toggle_bottom_panel => wb.bottom_panel_visible = !wb.bottom_panel_visible,
        .toggle_agent_panel => wb.agent_panel_visible = !wb.agent_panel_visible,
        .chat_clear_history => try wb.clearChatHistory(),
        .close_proposal_review => wb.closeProposalReview(),
        .close_ai_settings => wb.closeAiSettings(),
        .nav_back => try wb.navBack(),
        .nav_forward => try wb.navForward(),
        .open_ai_settings => try wb.openAiSettings(),
        .focus_agent => {
            wb.agent_panel_visible = true;
            wb.focused_panel = .agent;
            wb.chat_scroll_to_end_on_ready = true;
            wb.chat_follow_stream = true;
            try wb.setStatus("Agent focused");
        },
        .ghost_completion_accept => {
            if (wb.ghost.accept()) |text| {
                defer wb.allocator.free(text);
                if (wb.tabs.activeDoc()) |doc| {
                    try doc.buffer.insertString(text);
                }
            }
        },
        .ghost_completion_dismiss => {
            wb.ghost.dismiss();
        },
        .ghost_completion_toggle => {
            wb.ghost.config.enabled = !wb.ghost.config.enabled;
            if (!wb.ghost.config.enabled) wb.ghost.dismiss();
            const msg = if (wb.ghost.config.enabled) "Ghost completion enabled" else "Ghost completion disabled";
            try wb.setStatus(msg);
        },
    }
}

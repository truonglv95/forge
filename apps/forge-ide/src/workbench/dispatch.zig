const std = @import("std");
const editor = @import("forge-editor");
const workspace = @import("forge-workspace");
const plugin = @import("forge-plugin");
const lsp = @import("forge-lsp");
const workspace_io = @import("../workspace_io.zig");
const explorer_ops = @import("../explorer/ops.zig");
const recovery_mod = @import("recovery.zig");
const conflict_resolver = @import("conflict_resolver.zig");
const agent_workflow = @import("../agent/workflow.zig");
const tasks_mod = @import("tasks.zig");
const commands_mod = @import("commands.zig");
const state = @import("../ui/core/state.zig");
const Workbench = @import("../workbench.zig").Workbench;
const mention_resolver_mod = @import("mention_resolver.zig");
const Command = commands_mod.Command;

pub fn dispatch(wb: anytype, command: Command) !void {
    switch (command) {
        .open_file => |path| try wb.openFile(path),
        .open_settings => {
            const home_settings = try workspace.global_store.joinHome(wb.allocator, "settings.toml");
            defer wb.allocator.free(home_settings);
            try wb.openFile(home_settings);
        },
        .activate_tab => |index| try wb.activateTab(index),
        .close_tab => |index| try wb.closeTabAt(index),
        .close_active_tab => try wb.closeTabAt(wb.editor.tabs.active),
        .close_all_tabs => {
            wb.editor.tabs.closeAll();
            wb.tab_scroll_x = 0;
        },
        .reload_theme => try wb.reloadTheme(),
        .save_active => {
            const doc = wb.editor.tabs.activeDoc() orelse return;
            if (doc.external_conflict) {
                try wb.openConflictDialog(doc.path);
                return;
            }
            // P1-2: Format on save (best-effort — don't block save on format failure).
            if (wb.user_settings.format_on_save) {
                @import("../workbench/editor_ops.zig").formatDocument(wb) catch {};
            }
            try workspace_io.saveDocument(wb.io, wb.workspace_root, doc);
            try recovery_mod.snapshotDirtyDocs(wb.allocator, wb.io, wb.workspace_root, &wb.editor.tabs);
            workspace.hooks.runOnSave(wb.allocator, wb.io, wb.workspace_root, doc.path, wb.workspace_path) catch {};
            try wb.events.publish(.{ .file_saved = doc.path });
            // Check if user edited the global settings file (absolute path ending in settings.toml)
            const home_settings_path = workspace.global_store.joinHome(wb.allocator, "settings.toml") catch null;
            defer if (home_settings_path) |p| wb.allocator.free(p);
            const is_settings = if (home_settings_path) |p| std.mem.eql(u8, doc.path, p) else std.mem.eql(u8, doc.path, ".forge/settings.toml");
            if (is_settings) {
                try wb.reloadUserSettings();
            }
            try wb.setStatus("Saved");
            // P1-4: Show toast notification on save.
            _ = wb.notifications.success("File saved") catch {};
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
        .reload_extensions => try @import("../workbench/extensions_ops.zig").reloadExtensions(wb),
        .set_sidebar_view => |view| {
            if (view == .run) {
                try @import("../workbench/agent_ops.zig").openSettingsModal(wb);
                return;
            }
            wb.sidebar_view = view;
            wb.focused_panel = switch (view) {
                .explorer => .explorer,
                .search => .search,
                .git => .git,
                .run => .run,
                .extensions => .extensions,
                .ai => .agent,
                .outline => .editor,
            };
            if (view == .git) try @import("../workbench/git_ops.zig").refreshGitStatus(wb);
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
                const doc = try wb.editor.tabs.openOrActivate(path);
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
            try @import("../workbench/extensions_ops.zig").reloadExtensions(wb);
            try wb.setStatus("Extension installed");
        },
        .apply_extension_theme => |qualified| {
            if (wb.active_extension_theme.len > 0) wb.allocator.free(wb.active_extension_theme);
            wb.active_extension_theme = try wb.allocator.dupe(u8, qualified);
            try @import("../workbench/extensions_ops.zig").persistExtensionTheme(wb, qualified);
            try wb.reloadTheme();
            try wb.setStatus("Extension theme applied");
        },
        .refresh_explorer => {
            try wb.explorer.rebuild(wb.io, wb.workspace_root);
            try wb.events.publish(.{ .explorer_refreshed = {} });
        },
        .run_task => |task_name| {
            wb.lsp.references.clear();
            const task_out = wb.getOutputChannel("tasks").?.output;
            if (task_out.isRunning()) {
                return;
            }

            task_out.clear();
            task_out.setRunning(true);
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
            for (wb.editor.tabs.tabs.items) |*doc| {
                try doc.checkExternalConflict(wb.io, wb.workspace_root);
                if (doc.external_conflict and !doc.isDirty()) {
                    try workspace_io.loadDocument(wb.io, wb.workspace_root, doc);
                }
            }
            if (wb.editor.tabs.activeDoc()) |doc| {
                if (doc.external_conflict) try wb.openConflictDialog(doc.path);
            }
            try wb.setStatus("Checked external changes");
        },
        .reload_active_from_disk => {
            const doc = wb.editor.tabs.activeDoc() orelse return;
            try workspace_io.loadDocument(wb.io, wb.workspace_root, doc);
            try wb.closeConflictDialog();
            try wb.setStatus("Reloaded from disk");
        },
        .dismiss_external_conflict => {
            if (wb.editor.tabs.activeDoc()) |doc| doc.external_conflict = false;
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
        .palette_git_switch_branch => {
            wb.previous_focus = wb.focused_panel;
            wb.focused_panel = .palette;
            try wb.git_branch_picker.openPicker(wb.workspace_path);
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
                if (wb.editor.tabs.activeDoc()) |doc| {
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
        .agent_submit => {
            const prompt_text = try wb.agent_ui.prompt_buffer.content();
            defer wb.agent_ui.prompt_buffer.allocator.free(prompt_text);
            const trimmed = std.mem.trim(u8, prompt_text, &std.ascii.whitespace);
            if (trimmed.len == 0) return;

            // P1.5-1: Resolve @mentions in the prompt and build a context
            // preamble that gets prepended to the user's intent.
            var resolved = mention_resolver_mod.resolveMentions(
                wb.allocator,
                wb.io,
                wb.workspace_root,
                trimmed,
            ) catch mention_resolver_mod.ResolvedList{ .items = &.{} };
            defer resolved.deinit(wb.allocator);

            const preamble = mention_resolver_mod.buildContextPreamble(wb.allocator, resolved.items) catch try wb.allocator.dupe(u8, "");
            defer wb.allocator.free(preamble);

            // Combine preamble + user prompt.
            const full_prompt = if (preamble.len > 0)
                std.fmt.allocPrint(wb.allocator, "{s}{s}", .{ preamble, trimmed }) catch try wb.allocator.dupe(u8, trimmed)
            else
                try wb.allocator.dupe(u8, trimmed);
            defer wb.allocator.free(full_prompt);

            // For the chat display, show the original (trimmed) prompt
            // without the preamble — users don't want to see the context
            // block in the chat bubble.
            const owned_prompt = try wb.allocator.dupe(u8, trimmed);
            defer wb.allocator.free(owned_prompt);

            wb.agent_ui.prompt_buffer.deinit();
            wb.agent_ui.prompt_buffer = try editor.Buffer.init(wb.allocator);
            wb.prompt_scroll_y = 0;
            wb.focused_panel = .agent;

            try @import("../workbench/agent_ops.zig").appendChat(wb, .user, owned_prompt);
            wb.chat_follow_stream = true;
            const active = wb.editor.tabs.activeDoc();
            const active_path = if (active) |doc| doc.path else null;

            // Collect file paths from resolved mentions to use as scope_files.
            // This supplements the agent's existing scope with files the user
            // explicitly mentioned via @file: tokens.
            var scope_files: std.ArrayList([]const u8) = .empty;
            defer scope_files.deinit(wb.allocator);
            for (resolved.items) |m| {
                if (m.kind == .file and m.ok) {
                    scope_files.append(wb.allocator, m.label) catch {};
                }
            }

            agent_workflow.spawnGenerate(&@import("../workbench/agent_ops.zig").agentHost(wb), full_prompt, scope_files.items, active_path) catch |err| {
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
            const doc = wb.editor.tabs.activeDoc() orelse {
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

            const prompt_text = wb.agent_ui.prompt_buffer.content() catch {
                try wb.setStatus("Failed to read prompt");
                return;
            };
            defer wb.agent_ui.prompt_buffer.allocator.free(prompt_text);
            const user_part = std.mem.trim(u8, prompt_text, &std.ascii.whitespace);

            const intent = if (user_part.len > 0)
                try std.fmt.allocPrint(wb.allocator, "Edit the selected code in {s}.\n\nRequest: {s}\n\nSelected code:\n```\n{s}\n```", .{ doc.path, user_part, selection })
            else
                try std.fmt.allocPrint(wb.allocator, "Edit the selected code in {s}.\n\n```\n{s}\n```\n\nImprove or fix as needed.", .{ doc.path, selection });
            defer wb.allocator.free(intent);

            wb.agent_ui.prompt_buffer.deinit();
            wb.agent_ui.prompt_buffer = try editor.Buffer.init(wb.allocator);
            wb.prompt_scroll_y = 0;
            wb.focused_panel = .agent;
            wb.agent_ui.session.lock();
            wb.agent_ui.session.mode = .agent;
            wb.agent_ui.session.unlock();

            try @import("../workbench/agent_ops.zig").appendChat(wb, .user, intent);
            wb.chat_follow_stream = true;

            const scope = try wb.allocator.alloc([]const u8, 1);
            defer wb.allocator.free(scope);
            scope[0] = try wb.allocator.dupe(u8, doc.path);
            defer wb.allocator.free(scope[0]);

            agent_workflow.spawnGenerate(&@import("../workbench/agent_ops.zig").agentHost(wb), intent, scope, doc.path) catch |err| {
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
            agent_workflow.cancel(&@import("../workbench/agent_ops.zig").agentHost(wb));
            try wb.setStatus("Cancelling agent...");
        },
        .agent_apply => {
            const tx_id = try agent_workflow.applyCurrentProposal(&@import("../workbench/agent_ops.zig").agentHost(wb));
            @import("../workbench/agent_ops.zig").closeProposalReview(wb);
            var buf: [64]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Applied transaction {d}", .{tx_id});
            try wb.setStatus(msg);
            try @import("../workbench/agent_ops.zig").appendChat(wb, .agent, "Changes applied to workspace.");
        },
        .agent_rollback => {
            try agent_workflow.rollbackLastCheckpoint(&@import("../workbench/agent_ops.zig").agentHost(wb));
            @import("../workbench/agent_ops.zig").closeProposalReview(wb);
            try @import("../workbench/agent_ops.zig").appendChat(wb, .agent, "Rolled back to pre-apply checkpoint.");
            try wb.setStatus("Checkpoint restored");
        },
        .agent_dismiss_apply => {
            wb.agent_ui.session.dismissPostApplyBanner();
            try wb.setStatus("Changes kept");
        },
        .agent_approve_spec => {
            try agent_workflow.approveSpecAndGenerate(&@import("../workbench/agent_ops.zig").agentHost(wb));
            try wb.setStatus("Spec approved — generating proposal...");
        },
        .agent_approve_tool => {
            wb.agent_ui.session.resolveToolApproval(true);
            try wb.setStatus("Tool approved — continuing agent...");
        },
        .agent_approve_always_tool => {
            wb.agent_ui.session.lock();
            wb.agent_ui.session.always_approve_tools = true;
            wb.agent_ui.session.unlock();
            wb.agent_ui.session.resolveToolApproval(true);
            try wb.setStatus("Always approve enabled — continuing agent...");
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
                    .continue_run => agent_workflow.spawnResumeSession(&@import("../workbench/agent_ops.zig").agentHost(wb), id) catch |err| {
                        try wb.setStatus(agent_workflow.agentFailureMessage(err));
                    },
                    .review_proposal => {
                        agent_workflow.openStoredProposal(&@import("../workbench/agent_ops.zig").agentHost(wb), id) catch |err| {
                            try wb.setStatus(agent_workflow.agentFailureMessage(err));
                            return;
                        };
                        @import("../workbench/agent_ops.zig").openProposalReview(wb);
                    },
                }
            }
        },
        .agent_dismiss_resume => {
            agent_workflow.dismissResumeOffer(&@import("../workbench/agent_ops.zig").agentHost(wb));
            try wb.setStatus("Resume offer dismissed");
        },
        .agent_reject => {
            agent_workflow.rejectCurrentProposal(&@import("../workbench/agent_ops.zig").agentHost(wb));
            @import("../workbench/agent_ops.zig").closeProposalReview(wb);
            try @import("../workbench/agent_ops.zig").appendChat(wb, .agent, "Proposal rejected.");
            try wb.setStatus("Proposal rejected");
        },
        .agent_show_review => try @import("../workbench/agent_ops.zig").showAgentReview(wb),
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
                // Build proposal abs path in session dir
                const sess_dir = workspace.global_store.getSessionDir(wb.allocator, wb.io, wb.workspace_root) catch null;
                if (sess_dir) |sd| {
                    defer wb.allocator.free(sd);
                    const proposal_abs = std.fmt.allocPrint(wb.allocator, "{s}/proposals/{s}.json", .{ sd, entry.run_id }) catch null;
                    wb.agent_ui.session.proposal_rel = proposal_abs;
                } else {
                    // Fallback: legacy relative path
                    wb.agent_ui.session.proposal_rel = std.fmt.allocPrint(wb.allocator, ".forge/proposals/{s}.json", .{entry.run_id}) catch null;
                }
            }
            wb.agent_ui.session.unlock();
            if (wb.agent_ui.session.proposal_rel) |rel| {
                agent_workflow.loadProposalPreview(&@import("../workbench/agent_ops.zig").agentHost(wb), rel) catch {};
                @import("../workbench/agent_ops.zig").openProposalReview(wb);
            }
        },
        .agent_refresh_runs => try agent_workflow.refreshRunHistory(&@import("../workbench/agent_ops.zig").agentHost(wb)),
        .agent_add_scope => |path| {
            try wb.agent_ui.session.addScopeFile(path);
            @import("../workbench/agent_ops.zig").refreshAgentContextPreview(wb);
        },
        .agent_remove_scope => |path| {
            wb.agent_ui.session.removeScopeFile(path);
            @import("../workbench/agent_ops.zig").refreshAgentContextPreview(wb);
        },
        .agent_clear_scope => {
            wb.agent_ui.session.clearScope();
            @import("../workbench/agent_ops.zig").refreshAgentContextPreview(wb);
        },
        .agent_scope_picker_open => try @import("../workbench/agent_ops.zig").openScopePicker(wb),
        .agent_scope_picker_close => wb.agent_ui.session.closeScopePicker(),
        .agent_scope_picker_select => try @import("../workbench/agent_ops.zig").selectScopePickerEntry(wb),
        .agent_toggle_context_inspector => wb.agent_ui.session.toggleContextInspector(),
        .agent_toggle_mode_menu => wb.agent_ui.session.toggleModeMenu(),
        .agent_toggle_model_menu => wb.agent_ui.session.toggleModelMenu(),
        .agent_close_menus => wb.agent_ui.session.closeMenus(),
        .agent_set_model => |index| try @import("../workbench/agent_ops.zig").setAgentModelIndex(wb, index),
        .agent_remove_attachment => |index| {
            wb.agent_ui.session.removeAttachment(index);
            @import("../workbench/agent_ops.zig").refreshAgentContextPreview(wb);
            try wb.setStatus("Attachment removed");
        },
        .agent_copy_message => |index| {
            if (index < wb.agent_ui.chat_history.items.len) {
                const text = wb.agent_ui.chat_history.items[index].content;
                @import("forge-renderer").Renderer.setClipboardText(text);
                try wb.setStatus("Message copied to clipboard");
            }
        },
        .agent_open_message => |index| {
            std.debug.print("agent_open_message triggered for index {d}\n", .{index});
            if (index < wb.agent_ui.chat_history.items.len) {
                const text = wb.agent_ui.chat_history.items[index].content;

                const filename = std.fmt.allocPrint(wb.allocator, "/tmp/forge_msg_{d}.md", .{index}) catch |err| {
                    std.debug.print("allocPrint failed: {}\n", .{err});
                    return;
                };
                defer wb.allocator.free(filename);

                std.debug.print("Trying to create file: {s}\n", .{filename});
                var file = std.Io.Dir.createFileAbsolute(wb.io, filename, .{ .truncate = true }) catch |err| {
                    std.debug.print("createFileAbsolute failed: {}\n", .{err});
                    return;
                };
                defer file.close(wb.io);
                file.writeStreamingAll(wb.io, text) catch |err| {
                    std.debug.print("writeStreamingAll failed: {}\n", .{err});
                    return;
                };

                std.debug.print("File created, opening it...\n", .{});
                wb.openFile(filename) catch |err| {
                    std.debug.print("openFile failed: {}\n", .{err});
                };
            }
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
        .search_run => try @import("../workbench/search_ops.zig").runSearch(wb),
        .git_refresh => try @import("../workbench/git_ops.zig").refreshGitStatus(wb),
        .git_pull => {
            @import("git_ops.zig").scheduleGitPull(wb);
        },
        .git_push => {
            @import("git_ops.zig").scheduleGitPush(wb);
        },
        .git_stage_all => {
            const process_spawn = @import("forge-util").process_spawn;
            _ = process_spawn.runWait(wb.allocator, &.{ "git", "add", "." }, .{ .cwd = wb.workspace_path }) catch {};
            try @import("../workbench/git_ops.zig").refreshGitStatus(wb);
        },
        .git_unstage_all => {
            const process_spawn = @import("forge-util").process_spawn;
            _ = process_spawn.runWait(wb.allocator, &.{ "git", "reset" }, .{ .cwd = wb.workspace_path }) catch {};
            try @import("../workbench/git_ops.zig").refreshGitStatus(wb);
        },
        .uninstall_extension => |extension_id| {
            try plugin.marketplace.uninstall(wb.allocator, wb.io, wb.workspace_root, extension_id);
            try @import("../workbench/extensions_ops.zig").reloadExtensions(wb);
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
            try @import("../workbench/git_ops.zig").refreshGitStatus(wb);
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
        .debug_toggle_breakpoint => try @import("../workbench/debug_ops.zig").toggleBreakpointAtCursor(wb),
        .debug_clear_breakpoints => {
            wb.debug.breakpoints.clear();
            try wb.debug.console.log("Breakpoints cleared");
        },
        .rename_accept => try @import("../workbench/editor_ops.zig").acceptRenamePreview(wb),
        .rename_reject => @import("../workbench/editor_ops.zig").rejectRenamePreview(wb),
        .debug_run_launch => |index| try @import("../workbench/debug_ops.zig").runLaunchConfig(wb, index),
        .debug_clear_console => wb.debug.console.clear(),
        .debug_continue => try @import("../workbench/debug_ops.zig").debugContinue(wb),
        .debug_step_over => try @import("../workbench/debug_ops.zig").debugStepOver(wb),
        .debug_step_into => try @import("../workbench/debug_ops.zig").debugStepInto(wb),
        .debug_step_out => try @import("../workbench/debug_ops.zig").debugStepOut(wb),
        .debug_stop => @import("../workbench/debug_ops.zig").debugStop(wb),
        .editor_completion => {
            if (wb.editor.tabs.activeDoc()) |doc| wb.lsp.completions.requestForDocument(doc);
        },
        .editor_find => try @import("../workbench/editor_ops.zig").openEditorFind(wb, false),
        .editor_replace => try @import("../workbench/editor_ops.zig").openEditorFind(wb, true),
        .editor_goto_line => try @import("../workbench/editor_ops.zig").openGotoLine(wb),
        .editor_find_next => try @import("../workbench/editor_ops.zig").findNextMatch(wb),
        .editor_find_prev => try @import("../workbench/editor_ops.zig").findPrevMatch(wb),
        .editor_find_close => @import("../workbench/editor_ops.zig").closeEditorOverlay(wb),
        .editor_redo => {
            if (wb.activeBuffer()) |buf| try buf.redo();
        },
        .editor_undo => {
            if (wb.activeBuffer()) |buf| try buf.undo();
        },
        .editor_scroll_to_cursor => @import("../workbench/editor_ops.zig").scrollEditorToCursor(wb),
        .editor_go_to_definition => try wb.goToDefinition(),
        .editor_find_references => try @import("../workbench/editor_ops.zig").findReferences(wb),
        .editor_rename_symbol => try @import("../workbench/editor_ops.zig").openRenameSymbol(wb),
        .editor_format_document => try @import("../workbench/editor_ops.zig").formatDocument(wb),
        .editor_split_right => try wb.splitEditorRight(),
        .editor_close_split => try wb.closeEditorSplit(),
        .editor_accept_inline_edit => {
            if (wb.editor.tabs.activeDoc()) |doc| {
                try doc.buffer.acceptInlineEdit();
            }
        },
        .editor_reject_inline_edit => {
            if (wb.editor.tabs.activeDoc()) |doc| {
                try doc.buffer.rejectInlineEdit();
            }
        },
        .references_goto => |index| try @import("../workbench/editor_ops.zig").gotoReference(wb, index),
        .problems_goto => |index| try @import("../workbench/editor_ops.zig").gotoProblem(wb, index),
        .completion_accept => {
            if (wb.editor.tabs.activeDoc()) |doc| try wb.lsp.completions.acceptSelected(doc);
        },
        .completion_dismiss => wb.lsp.completions.dismiss(),
        .save_session_state => try wb.persistSessionState(),
        .restore_session_state => try wb.restoreSessionTabs(),
        .settings_reload => try wb.reloadUserSettings(),
        .settings_toggle_word_wrap => try wb.toggleWordWrap(),
        .open_recent_workspace => |index| try wb.openRecentWorkspace(index),
        .problem_quick_fix => try wb.quickFixAtCursor(null, state.last_mouse_x, state.last_mouse_y),
        .debug_stack_goto => |index| try @import("../workbench/debug_ops.zig").gotoDebugStackFrame(wb, index),
        .debug_copy_variable => |index| try @import("../workbench/debug_ops.zig").copyDebugVariable(wb, index),
        .ai_open_settings_toml => try @import("../workbench/agent_ops.zig").openSettingsToml(wb),
        .ai_open_mcp_config => try @import("../workbench/agent_ops.zig").openMcpConfig(wb),
        .ai_toggle_mcp => try @import("../workbench/agent_ops.zig").toggleAiMcp(wb),
        .ai_refresh_mcp => try @import("../workbench/agent_ops.zig").refreshAiMcpStatus(wb),
        .ai_toggle_hyde => {
            wb.agent_ui.enable_hyde = !wb.agent_ui.enable_hyde;
            try @import("ai_config_io.zig").writeAiEnableHyde(wb.allocator, wb.io, wb.workspace_root, wb.agent_ui.enable_hyde);
        },
        .ai_edit_provider => {
            const current = wb.agent_ui.provider;
            const next = if (std.mem.eql(u8, current, "auto")) "openai" else if (std.mem.eql(u8, current, "openai")) "anthropic" else if (std.mem.eql(u8, current, "anthropic")) "gemini" else if (std.mem.eql(u8, current, "gemini")) "ollama" else if (std.mem.eql(u8, current, "ollama")) "openrouter" else "auto";
            wb.allocator.free(wb.agent_ui.provider);
            wb.agent_ui.provider = try wb.allocator.dupe(u8, next);
            try @import("ai_config_io.zig").writeAiProvider(wb.allocator, wb.io, wb.workspace_root, next);
        },
        .ai_edit_model => {
            // Since models are vast, we open settings.toml for free-form text input
            try @import("../workbench/agent_ops.zig").openSettingsToml(wb);
        },
        .ai_edit_embedding_provider => {
            const current = wb.agent_ui.embedding_provider orelse "auto";
            const next = if (std.mem.eql(u8, current, "auto")) "openai" else if (std.mem.eql(u8, current, "openai")) "gemini" else if (std.mem.eql(u8, current, "gemini")) "ollama" else "auto";
            if (wb.agent_ui.embedding_provider) |old| wb.allocator.free(old);
            wb.agent_ui.embedding_provider = try wb.allocator.dupe(u8, next);
            try @import("ai_config_io.zig").writeAiEmbeddingProvider(wb.allocator, wb.io, wb.workspace_root, next);
        },
        .ai_edit_embedding_model => {
            wb.settings_embedding_picker_open = !wb.settings_embedding_picker_open;
        },
        .ai_set_embedding_model => |index| {
            wb.settings_embedding_picker_open = false;
            if (index < wb.agent_ui.embedding_models.len) {
                const opt = wb.agent_ui.embedding_models[index];
                if (wb.agent_ui.embedding_model) |old| wb.allocator.free(old);
                wb.agent_ui.embedding_model = try wb.allocator.dupe(u8, opt.id);
                try @import("ai_config_io.zig").writeAiEmbeddingModel(wb.allocator, wb.io, wb.workspace_root, opt.id);

                if (wb.agent_ui.embedding_provider) |old| wb.allocator.free(old);
                wb.agent_ui.embedding_provider = try wb.allocator.dupe(u8, opt.provider);
                try @import("ai_config_io.zig").writeAiEmbeddingProvider(wb.allocator, wb.io, wb.workspace_root, opt.provider);
            }
        },
        .toggle_sidebar => wb.sidebar_visible = !wb.sidebar_visible,
        .toggle_bottom_panel => wb.bottom_panel_visible = !wb.bottom_panel_visible,
        .toggle_agent_panel => wb.agent_panel_visible = !wb.agent_panel_visible,
        .chat_clear_history => try wb.clearChatHistory(),
        .close_proposal_review => @import("../workbench/agent_ops.zig").closeProposalReview(wb),
        .close_settings_modal => @import("../workbench/agent_ops.zig").closeSettingsModal(wb),
        .open_settings_modal => try @import("../workbench/agent_ops.zig").openSettingsModal(wb),
        .nav_back => try wb.navBack(),
        .nav_forward => try wb.navForward(),
        .focus_agent => {
            wb.agent_panel_visible = true;
            wb.focused_panel = .agent;
            wb.chat_scroll_to_end_on_ready = true;
            wb.chat_follow_stream = true;
            try wb.setStatus("Agent focused");
        },
        .ghost_completion_accept => {
            if (wb.editor.ghost.accept()) |text| {
                defer wb.allocator.free(text);
                if (wb.editor.tabs.activeDoc()) |doc| {
                    try doc.buffer.insertString(text);
                }
            }
        },
        .ghost_completion_dismiss => {
            wb.editor.ghost.dismiss();
        },
        .ghost_completion_toggle => {
            wb.editor.ghost.config.enabled = !wb.editor.ghost.config.enabled;
            if (!wb.editor.ghost.config.enabled) wb.editor.ghost.dismiss();
            const msg = if (wb.editor.ghost.config.enabled) "Ghost completion enabled" else "Ghost completion disabled";
            try wb.setStatus(msg);
        },
        // P0-4: Multi-cursor
        .editor_add_cursor_next => {
            const doc = wb.editor.tabs.activeDoc() orelse return;
            const word = wordAtCursor(&doc.buffer) orelse {
                try wb.setStatus("No word at cursor to match");
                return;
            };
            const added = wb.editor.multi_cursor.addNextOccurrence(&doc.buffer, doc.buffer.cursor, word) catch false;
            if (!added) try wb.setStatus("No more occurrences");
        },
        .editor_add_cursor_all => {
            const doc = wb.editor.tabs.activeDoc() orelse return;
            const word = wordAtCursor(&doc.buffer) orelse {
                try wb.setStatus("No word at cursor to match");
                return;
            };
            _ = wb.editor.multi_cursor.addAllOccurrences(&doc.buffer, word) catch 0;
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{d} cursors", .{wb.editor.multi_cursor.count()}) catch "Multi-cursor active";
            try wb.setStatus(msg);
        },
        .editor_clear_cursors => {
            wb.editor.multi_cursor.clear();
            try wb.setStatus("Cursors cleared");
        },
        // P0-4: Code folding
        .editor_fold_toggle => {
            const doc = wb.editor.tabs.activeDoc() orelse return;
            if (wb.editor.fold_dirty) {
                wb.editor.fold_controller.computeRanges(&doc.buffer) catch {};
                wb.editor.fold_dirty = false;
            }
            const toggled = wb.editor.fold_controller.toggleAtLine(@intCast(doc.buffer.cursor.row));
            if (!toggled) try wb.setStatus("No fold at cursor");
        },
        .editor_fold_all => {
            const doc = wb.editor.tabs.activeDoc() orelse return;
            if (wb.editor.fold_dirty) {
                wb.editor.fold_controller.computeRanges(&doc.buffer) catch {};
                wb.editor.fold_dirty = false;
            }
            wb.editor.fold_controller.foldAll();
            try wb.setStatus("Folded all");
        },
        .editor_unfold_all => {
            wb.editor.fold_controller.unfoldAll();
            try wb.setStatus("Unfolded all");
        },
        // P0-5: Context menu
        .editor_open_context_menu => {
            // Open at cursor's screen position (approximated via click pos
            // stored by mouse handler). For keyboard invocation (Cmd+.
            // already maps to problem.quick_fix), use last mouse position.
            wb.context_menu.openEditor(state.last_mouse_x, state.last_mouse_y) catch {};
        },
        .editor_apply_quick_fix => |index| {
            // Index comes from clicking a context-menu quick-fix item.
            try wb.quickFixAtCursor(index, state.last_mouse_x, state.last_mouse_y);
        },
        .editor_show_quick_fixes => {
            // Open the context menu with available quick fixes.
            try wb.quickFixAtCursor(null, state.last_mouse_x, state.last_mouse_y);
        },
        // P0-2: Inline edit (Cmd+K)
        .inline_edit_open => {
            try openInlineEdit(wb);
        },
        .inline_edit_submit => {
            try submitInlineEdit(wb);
        },
        .inline_edit_accept => {
            if (wb.editor.tabs.activeDoc()) |doc| {
                try doc.buffer.acceptInlineEdit();
                wb.editor.inline_edit.close();
                try wb.setStatus("Inline edit applied");
            }
        },
        .inline_edit_reject => {
            if (wb.editor.tabs.activeDoc()) |doc| {
                try doc.buffer.rejectInlineEdit();
            }
            wb.editor.inline_edit.close();
            try wb.setStatus("Inline edit rejected");
        },
        .inline_edit_cancel => {
            wb.editor.inline_edit.close();
            try wb.setStatus("Inline edit cancelled");
        },
        // P0-3: @mentions (basic dispatch — most logic in input handler)
        .chat_mention_file => {
            wb.mention_picker.open();
            wb.mention_picker.setKind(.file);
        },
        .chat_mention_symbol => {
            wb.mention_picker.open();
            wb.mention_picker.setKind(.symbol);
        },
        .chat_mention_folder => {
            wb.mention_picker.open();
            wb.mention_picker.setKind(.folder);
        },
        .chat_mention_web => {
            wb.mention_picker.open();
            wb.mention_picker.setKind(.web);
            wb.mention_picker.setWebItem() catch {};
        },
        .chat_mention_select => |index| {
            if (index < wb.mention_picker.items.items.len) {
                wb.mention_picker.selected = index;
            }
        },
        .chat_mention_dismiss => {
            wb.mention_picker.close();
        },
        // P1.5-3: Watch expressions
        .debug_watch_add => |expr| {
            const trimmed = std.mem.trim(u8, expr, &std.ascii.whitespace);
            if (trimmed.len == 0) return;
            _ = wb.debug.watch_expressions.add(trimmed) catch {
                try wb.setStatus("Failed to add watch expression");
                return;
            };
            try wb.persistSessionState();
            try wb.refreshWatchExpressions();
            try wb.setStatus("Watch expression added");
        },
        .debug_watch_remove => |index| {
            wb.debug.watch_expressions.remove(index);
            try wb.persistSessionState();
            try wb.setStatus("Watch expression removed");
        },
        .debug_watch_clear => {
            wb.debug.watch_expressions.clear();
            try wb.persistSessionState();
            try wb.setStatus("Watch expressions cleared");
        },
        .debug_watch_refresh => {
            try wb.refreshWatchExpressions();
            try wb.setStatus("Watch expressions refreshed");
        },
        .select_output_channel => {
            if (wb.output_channels.count() > 0) {
                wb.output_channel_picker.openPicker() catch {};
                var it = wb.output_channels.iterator();
                while (it.next()) |entry| {
                    wb.output_channel_picker.addChannel(entry.value_ptr.*.id, entry.value_ptr.*.name) catch {};
                }
                wb.output_channel_picker.applyFilter() catch {};
                wb.previous_focus = wb.focused_panel;
                wb.focused_panel = .output_channels;
            }
        },
        .conflict_accept_current => |start_row| {
            if (wb.editor.tabs.activeDoc()) |doc| {
                conflict_resolver.findConflicts(wb.allocator, &doc.buffer, &wb.conflict_blocks_cache.blocks) catch {};
                for (wb.conflict_blocks_cache.blocks.items) |block| {
                    if (block.start_row == start_row) {
                        conflict_resolver.resolveCurrent(&doc.buffer, block) catch {};
                        break;
                    }
                }
            }
        },
        .conflict_accept_incoming => |start_row| {
            if (wb.editor.tabs.activeDoc()) |doc| {
                conflict_resolver.findConflicts(wb.allocator, &doc.buffer, &wb.conflict_blocks_cache.blocks) catch {};
                for (wb.conflict_blocks_cache.blocks.items) |block| {
                    if (block.start_row == start_row) {
                        conflict_resolver.resolveIncoming(&doc.buffer, block) catch {};
                        break;
                    }
                }
            }
        },
        .conflict_accept_both => |start_row| {
            if (wb.editor.tabs.activeDoc()) |doc| {
                conflict_resolver.findConflicts(wb.allocator, &doc.buffer, &wb.conflict_blocks_cache.blocks) catch {};
                for (wb.conflict_blocks_cache.blocks.items) |block| {
                    if (block.start_row == start_row) {
                        conflict_resolver.resolveBoth(&doc.buffer, block) catch {};
                        break;
                    }
                }
            }
        },
    }
}

// --- Helpers for P0-5 (context menu / quick fix) ---

fn wordAtCursor(buf: anytype) ?[]const u8 {
    const line = buf.lineAt(buf.cursor.row);
    if (line.len == 0) return null;
    var start = buf.cursor.col;
    var end = buf.cursor.col;
    if (start > 0) start -= 1;
    while (start > 0 and (std.ascii.isAlphanumeric(line[start - 1]) or line[start - 1] == '_')) : (start -= 1) {}
    while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) : (end += 1) {}
    if (start >= end) return null;
    return line[start..end];
}

// --- Helpers for P0-2 (inline edit) ---

fn openInlineEdit(wb: *Workbench) !void {
    const doc = wb.editor.tabs.activeDoc() orelse {
        try wb.setStatus("No active file");
        return;
    };
    const sel = doc.buffer.selectionOrdered();
    const has_selection = sel.start.row != sel.end.row or sel.start.col != sel.end.col;
    if (!has_selection) {
        try wb.setStatus("Select code first (drag in editor)");
        return;
    }
    const selected = doc.buffer.selectedText(wb.allocator) catch {
        try wb.setStatus("Failed to read selection");
        return;
    };
    defer wb.allocator.free(selected);
    try wb.editor.inline_edit.open(
        doc.path,
        sel.start.row,
        sel.start.col,
        sel.end.row,
        sel.end.col,
        selected,
    );
}

fn submitInlineEdit(wb: *Workbench) !void {
    if (!wb.editor.inline_edit.active) return;
    if (wb.editor.inline_edit.promptText().len == 0) {
        try wb.setStatus("Type an instruction first");
        return;
    }
    wb.editor.inline_edit.markPending();
    try wb.setStatus("Generating edit…");
    // Spawn a generate run with the inline-edit prompt as intent. The
    // agent will produce a proposal which the user can review/apply via
    // the existing proposal review UI (Tab accept / Esc reject).
    const intent = try wb.editor.inline_edit.buildAgentPrompt();
    defer wb.allocator.free(intent);
    const scope_files: []const []const u8 = &.{};
    const active_file = wb.editor.inline_edit.file_path;
    agent_workflow.spawnGenerate(&@import("../workbench/agent_ops.zig").agentHost(wb), intent, scope_files, active_file) catch |err| {
        std.log.warn("inline_edit agent run failed: {s}", .{@errorName(err)});
        wb.editor.inline_edit.close();
        try wb.setStatus("Inline edit failed");
    };
}

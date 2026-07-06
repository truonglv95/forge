const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../core/state.zig");
const layout = @import("../core/layout.zig");
const activity_bar = @import("../sidebar/activity_bar.zig");
const search_panel = @import("../sidebar/search_panel.zig");
const debug_panel = @import("../sidebar/debug_panel.zig");
const git_panel = @import("../sidebar/git_panel.zig");
const extensions_panel = @import("../sidebar/extensions_panel.zig");
const ai_settings_panel = @import("../agent/ai_settings_panel.zig");
const proposal_review_panel = @import("../editor/proposal_review_panel.zig");
const header_toolbar = @import("../chrome/header_toolbar.zig");
const plugin = @import("forge-plugin");
const explorer_scroll = @import("../sidebar/explorer_scroll.zig");
const tabs_ui = @import("../editor/tabs.zig");
const terminal_panel = @import("../panel/terminal_panel.zig");
const bottom_panel = @import("../panel/bottom_panel.zig");
const scroll_axis = @import("../core/scroll_axis.zig");
const shared = @import("shared.zig");
const editor_hit = @import("editor_hit.zig");
const keys_agent = @import("keys_agent.zig");

pub fn onMouseEvent(event: renderer.MouseEvent) void {
    const wb = state.wb orelse return;

    var w: f32 = 0;
    var h: f32 = 0;
    renderer.Renderer.getWindowSize(&w, &h);
    const geo = wb.layoutGeometry(w, h);

    const is_near_explorer_splitter = geo.shell_mode == .ide and wb.sidebar_visible and @abs(event.x - geo.explorer_splitter_x) < 5.0;
    const is_near_agent_splitter = geo.shell_mode == .ide and wb.agent_panel_visible and @abs(event.x - geo.agent_splitter_x) < 5.0;
    const is_near_bottom_splitter = geo.shell_mode == .ide and wb.bottom_panel_visible and geo.task_panel_h > 0 and
        event.x >= geo.editor_x and event.x < geo.agent_splitter_x and
        event.y >= geo.task_panel_y and event.y < geo.task_panel_y + 4.0;

    if (event.action == .move or event.action == .down or event.action == .drag) {
        state.last_mouse_x = event.x;
        state.last_mouse_y = event.y;
    }

    if (event.action == .move) {
        if (event.y < layout.header_height) {
            state.header_hover_action = header_toolbar.hoverAction(w, wb.headerToolbarState(), event.x, event.y);
        } else {
            state.header_hover_action = null;
        }

        if (is_near_agent_splitter or is_near_explorer_splitter) {
            renderer.Renderer.setCursor(2);
        } else if (is_near_bottom_splitter) {
            renderer.Renderer.setCursor(3);
        } else {
            renderer.Renderer.setCursor(0);
        }

        if (geo.shell_mode == .ide and wb.sidebar_view == .explorer and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= explorer_scroll.list_top and event.y < h - layout.status_height) {
            state.explorer_hover_row = explorer_scroll.rowAtPoint(wb.explorer_scroll_y, event.y);
        } else {
            state.explorer_hover_row = null;
        }

        if (geo.shell_mode == .ide and editor_hit.isEditorContentArea(geo, event.x, event.y)) {
            const pane = wb.paneAt(geo.editor_x, geo.editor_w, event.x);
            if (wb.docForPane(pane)) |doc| {
                const pane_x = wb.paneOriginX(geo.editor_x, geo.editor_w, pane);
                const pane_w = wb.paneWidth(geo.editor_w);
                const scroll_y = if (pane == .secondary) wb.split_scroll_y else wb.editor_scroll_y;
                const scroll_x = if (pane == .secondary) wb.split_scroll_x else wb.editor_scroll_x;
                if (editor_hit.editorPosAt(wb, &doc.buffer, pane_x, pane_w, scroll_y, scroll_x, event.x, event.y)) |pos| {
                    wb.requestEditorHover(doc.path, pos.row, pos.col, event.x, event.y);
                }
            }
        } else {
            wb.hover.clear();
        }
    } else if (event.action == .down) {
        if (wb.palette.open) return;
        if (event.y < layout.header_height) {
            if (header_toolbar.hitTest(w, wb.headerToolbarState(), event.x, event.y)) |action| {
                wb.handleHeaderAction(action) catch {};
            }
            return;
        }
        if (is_near_agent_splitter) {
            state.is_dragging_agent_splitter = true;
        } else if (is_near_explorer_splitter) {
            state.is_dragging_explorer_splitter = true;
        } else if (is_near_bottom_splitter) {
            state.is_dragging_bottom_panel_splitter = true;
        } else if (event.x < geo.explorer_w and event.y >= layout.header_height and event.y < layout.header_height + layout.activity_bar_height) {
            if (activity_bar.hitTest(event.x, event.y, geo.explorer_w)) |view| {
                wb.dispatch(.{ .set_sidebar_view = view }) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .extensions and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= extensions_panel.list_top) {
            wb.focused_panel = .extensions;
            const catalog_ptr: ?*const plugin.MarketplaceCatalog = if (wb.marketplace_catalog) |*catalog| catalog else null;
            if (extensions_panel.hitTest(
                &wb.extension_host,
                catalog_ptr,
                wb.extensions_panel_mode,
                geo.explorer_x,
                geo.explorer_w,
                event.x,
                event.y,
                wb.extensions_scroll_y,
                wb.extensionsFilterSlice(),
                wb.extensions_detail_index,
                shared.canUninstallExtensionIndex,
            )) |hit| {
                wb.handleExtensionsClick(hit) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .search and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= search_panel.list_top - 40) {
            wb.focused_panel = .search;
            if (search_panel.hitTest(
                if (wb.search_results) |results| results.matches else &.{},
                geo.explorer_x,
                geo.explorer_w,
                event.x,
                event.y,
                wb.search_scroll_y,
            )) |hit| {
                wb.handleSearchClick(hit) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .git and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= layout.header_height + layout.activity_bar_height) {
            wb.focused_panel = .git;
            if (git_panel.hitTest(
                if (wb.git_status) |status| status.entries else &.{},
                wb.git_staged_collapsed,
                wb.git_changes_collapsed,
                geo.explorer_x,
                geo.explorer_w,
                event.x,
                event.y,
                wb.git_scroll_y,
            )) |hit| {
                wb.handleGitClick(hit) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .run and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= debug_panel.list_top - 40) {
            wb.focused_panel = .run;
            if (debug_panel.hitTest(
                geo.explorer_x,
                geo.explorer_w,
                event.x,
                event.y,
                wb.run_scroll_y,
                wb.breakpoints.items.items.len,
                wb.debug_lldb.isActive(),
            )) |hit| {
                wb.handleDebugClick(hit) catch {};
            }
        } else if (geo.shell_mode == .ide and wb.sidebar_view == .explorer and event.x >= geo.explorer_x and event.x < geo.explorer_splitter_x and event.y >= explorer_scroll.list_top) {
            wb.focused_panel = .explorer;
            const float_row = (event.y - explorer_scroll.list_top + wb.explorer_scroll_y) / explorer_scroll.row_height;
            if (float_row >= 0) {
                const click_row: usize = @intFromFloat(float_row);
                wb.handleExplorerClick(click_row, event.x, geo.explorer_x) catch {};
            }
        } else if (geo.shell_mode == .ide and event.x >= geo.agent_x) {
            wb.focused_panel = .agent;
            const agent_panel = @import("../agent/agent_panel.zig");
            const context_inspector_mod = @import("../agent/context_inspector.zig");
            const agent_composer_mod = @import("../agent/agent_composer.zig");
            wb.agent.lock();
            const entry_count = wb.agent.context_entries.items.len;
            const expanded = wb.agent.context_inspector_expanded;
            const has_detail = wb.agent.context_selected_index != null and expanded;
            const attachment_count = wb.agent.attachments.items.len;
            const ctx_scroll = wb.agent.context_inspector_scroll_y;
            wb.agent.unlock();
            if (context_inspector_mod.hitToggle(geo.agent_x, geo.agent_w, h, entry_count, attachment_count, &wb.prompt_buffer, has_detail, event.x, event.y)) {
                wb.dispatch(.agent_toggle_context_inspector) catch {};
                return;
            }
            if (expanded) {
                if (context_inspector_mod.hitEntryRow(geo.agent_x, geo.agent_w, h, entry_count, attachment_count, &wb.prompt_buffer, ctx_scroll, event.x, event.y)) |row| {
                    wb.agent.lock();
                    if (wb.agent.context_selected_index) |sel| {
                        wb.agent.context_selected_index = if (sel == row) null else row;
                    } else {
                        wb.agent.context_selected_index = row;
                    }
                    wb.agent.unlock();
                    return;
                }
            }
            const composer_layout = agent_panel.composerLayout(geo.agent_x, geo.agent_w, h, attachment_count, &wb.prompt_buffer);
            if (agent_composer_mod.hitAttachmentRemove(&wb.agent, composer_layout, event.x, event.y)) |index| {
                wb.dispatch(.{ .agent_remove_attachment = index }) catch {};
                return;
            }
            const hit = agent_composer_mod.hitTest(&wb.agent, composer_layout, event.x, event.y);
            switch (hit) {
                .mode_menu => {
                    wb.dispatch(.agent_toggle_mode_menu) catch {};
                    return;
                },
                .model_menu => {
                    wb.dispatch(.agent_toggle_model_menu) catch {};
                    return;
                },
                .mode_item => {
                    if (agent_composer_mod.modeIndexAt(&wb.agent, composer_layout, event.x, event.y)) |index| {
                        wb.dispatch(.{ .agent_set_mode = agent_composer_mod.modes[index].mode }) catch {};
                    }
                    return;
                },
                .model_item => {
                    if (agent_composer_mod.modelIndexAt(&wb.agent, composer_layout, event.x, event.y)) |index| {
                        wb.dispatch(.{ .agent_set_model = index }) catch {};
                    }
                    return;
                },
                .scope => {
                    wb.dispatch(.agent_scope_picker_open) catch {};
                    return;
                },
                .send => {
                    keys_agent.submitAgentPrompt(wb);
                    return;
                },
                .input => {},
                else => {
                    wb.agent.closeMenus();
                },
            }
            if (agent_panel.hitPromptInput(geo.agent_x, geo.agent_w, h, attachment_count, &wb.prompt_buffer, event.x, event.y)) {
                return;
            }
            wb.agent.lock();
            const show_rollback = wb.agent.last_checkpoint_id != null;
            const show_approve_spec = wb.agent.spec_pending;
            const show_review = wb.agent.show_review;
            const approval_pending = wb.agent.approval_decision == .pending;
            wb.agent.unlock();

            if (approval_pending) {
                if (agent_panel.hitApprovalAction(geo.agent_x, geo.agent_w, h, attachment_count, &wb.prompt_buffer, event.x, event.y)) |action| {
                    switch (action) {
                        .approve => wb.dispatch(.agent_approve_tool) catch {},
                        .reject => wb.dispatch(.agent_reject_tool) catch {},
                    }
                    return;
                }
            }

            wb.agent.lock();
            const post_apply = wb.agent.post_apply_visible;
            const validation_failed = wb.agent.phase == .failed and post_apply;
            const validation_count = wb.agent.validation_results.items.len;
            const resume_offer = wb.agent.resume_offer_visible;
            wb.agent.unlock();
            if (post_apply) {
                const banner_y = agent_panel.chat_content_top + 8 - wb.chat_scroll_y;
                if (agent_panel.hitApplyBanner(geo.agent_x, banner_y, event.x, event.y, validation_failed, validation_count)) |action| {
                    switch (action) {
                        .keep => wb.dispatch(.agent_dismiss_apply) catch {},
                        .undo => wb.dispatch(.agent_rollback) catch {},
                    }
                    return;
                }
            }
            if (resume_offer) {
                var banner_y = agent_panel.chat_content_top + 8 - wb.chat_scroll_y;
                if (post_apply) {
                    banner_y += agent_panel.applyBannerHeight(validation_failed, validation_count) + 4;
                }
                if (agent_panel.hitResumeBanner(geo.agent_x, banner_y, event.x, event.y)) |action| {
                    switch (action) {
                        .primary => wb.dispatch(.agent_continue_session) catch {},
                        .dismiss => wb.dispatch(.agent_dismiss_resume) catch {},
                    }
                    return;
                }
            }

            if ((show_review and !wb.proposal_review_open) or show_approve_spec or show_rollback) {
                if (agent_panel.hitReviewAction(geo.agent_x, geo.agent_w, h, attachment_count, &wb.prompt_buffer, show_rollback, show_approve_spec, event.x, event.y)) |action| {
                    switch (action) {
                        .apply => wb.dispatch(.agent_apply) catch {},
                        .reject => wb.dispatch(.agent_reject) catch {},
                        .rollback => wb.dispatch(.agent_rollback) catch {},
                        .approve_spec => wb.dispatch(.agent_approve_spec) catch {},
                    }
                    return;
                }
            }
            wb.agent.lock();
            wb.agent.unlock();

            // Actually, we can add a toggleAgentStep method to workbench that iterates chat history and steps.
            if (agent_panel.hitTestSteps(wb, geo.agent_x, geo.agent_w, event.x, event.y)) |step_idx| {
                wb.dispatch(.{ .agent_toggle_step = step_idx }) catch {};
                return;
            }

            if (show_review and !wb.proposal_review_open) {
                wb.agent.lock();
                const has_summary = wb.agent.summary != null;
                const review_scroll = wb.agent.review_scroll_y;
                wb.agent.unlock();
                if (agent_panel.hitReviewHunk(
                    &wb.agent,
                    wb.chat_scroll_y,
                    review_scroll,
                    has_summary,
                    event.x,
                    event.y,
                    geo.agent_x,
                    20,
                )) |hunk_index| {
                    wb.agent.lock();
                    wb.agent.review.toggle(hunk_index);
                    wb.agent.unlock();
                    return;
                }
            }
        } else if (event.x >= geo.agent_x) {
            wb.focused_panel = .agent;
        } else if (geo.shell_mode == .ide and event.x >= geo.editor_x and event.x < geo.agent_splitter_x and event.y >= tabs_ui.tab_bar_top and event.y < tabs_ui.tab_bar_top + tabs_ui.tab_bar_height) {
            if (wb.proposal_review_open) {
                wb.focused_panel = .proposal_review;
                if (proposal_review_panel.hitCloseTab(geo.editor_x, event.x, event.y)) {
                    wb.dispatch(.close_proposal_review) catch {};
                }
            } else if (wb.ai_settings_open) {
                wb.focused_panel = .ai_settings;
                if (ai_settings_panel.hitCloseTab(geo.editor_x, event.x, event.y)) {
                    wb.dispatch(.close_ai_settings) catch {};
                }
            } else {
                wb.focused_panel = .editor;
                var tab_layouts: std.ArrayList(tabs_ui.TabLayout) = .empty;
                defer tab_layouts.deinit(state.gpa);
                tabs_ui.collectLayouts(wb, geo.editor_x, &tab_layouts) catch {};
                switch (tabs_ui.hitTest(tab_layouts.items, event.x, event.y)) {
                    .close => |index| wb.dispatch(.{ .close_tab = index }) catch {},
                    .activate => |index| wb.dispatch(.{ .activate_tab = index }) catch {},
                    .none => {},
                }
            }
        } else if (geo.shell_mode == .ide and editor_hit.isEditorContentArea(geo, event.x, event.y)) {
            if (wb.proposal_review_open) {
                wb.focused_panel = .proposal_review;
                wb.agent.lock();
                const hunks = wb.agent.review.hunks;
                wb.agent.unlock();
                if (proposal_review_panel.hitTest(
                    wb.allocator,
                    geo.editor_x,
                    geo.editor_h,
                    wb.proposal_review_scroll_y,
                    hunks,
                    wb.proposal_review_file_index,
                    event.x,
                    event.y,
                ) catch null) |hit| {
                    wb.handleProposalReviewClick(hit) catch {};
                }
                return;
            }
            if (wb.ai_settings_open) {
                wb.focused_panel = .ai_settings;
                if (ai_settings_panel.hitTestPoint(
                    geo.editor_x,
                    wb.ai_settings_scroll_y,
                    event.x,
                    event.y,
                )) |hit| {
                    wb.handleAiSettingsClick(hit) catch {};
                }
                return;
            }
            wb.focused_panel = .editor;
            const pane = wb.paneAt(geo.editor_x, geo.editor_w, event.x);
            wb.editor_pane_focus = pane;
            if (wb.docForPane(pane)) |doc| {
                const pane_x = wb.paneOriginX(geo.editor_x, geo.editor_w, pane);
                const pane_w = wb.paneWidth(geo.editor_w);
                const scroll_y = if (pane == .secondary) wb.split_scroll_y else wb.editor_scroll_y;
                const scroll_x = if (pane == .secondary) wb.split_scroll_x else wb.editor_scroll_x;
                if (editor_hit.editorPosAt(wb, &doc.buffer, pane_x, pane_w, scroll_y, scroll_x, event.x, event.y)) |pos| {
                    doc.buffer.beginSelection(pos.row, pos.col);
                    state.is_dragging_editor_selection = true;
                    wb.scrollEditorToCursor();
                    if (event.modifiers & shared.cmd_mask != 0) {
                        wb.goToDefinition() catch {};
                        state.is_dragging_editor_selection = false;
                        return;
                    }
                }
            }
        } else if (geo.shell_mode == .ide and event.y >= geo.task_panel_y) {
            if (bottom_panel.hitTab(geo.editor_x, geo.task_panel_y, event.x, event.y)) |mode| {
                wb.dispatch(.{ .set_bottom_panel_mode = mode }) catch {};
            } else if (wb.bottom_panel_mode == .terminal and bottom_panel.inContentArea(geo.task_panel_y, event.y)) {
                wb.focused_panel = .terminal;
                if (terminal_panel.hitSessionTab(geo.editor_x, geo.editor_w, geo.task_panel_y, event.x, event.y, wb.terminals.sessions.items.len)) |hit| {
                    switch (hit) {
                        .new => wb.dispatch(.terminal_new) catch {},
                        .activate => |index| wb.dispatch(.{ .terminal_activate = index }) catch {},
                    }
                    return;
                }
                const terminal = wb.activeTerminal();
                terminal.lock();
                defer terminal.unlock();
                if (terminal_panel.hitTest(
                    geo.editor_x,
                    geo.task_panel_y,
                    geo.task_panel_h,
                    event.x,
                    event.y,
                    wb.task_scroll_y,
                    terminal.lines.items,
                )) |pos| {
                    wb.focused_panel = .terminal;
                    wb.terminal_selection = .{ .anchor = pos, .cursor = pos };
                    state.is_dragging_terminal_selection = true;
                } else {
                    wb.focused_panel = .terminal;
                    wb.terminal_selection = null;
                }
            } else if (bottom_panel.inContentArea(geo.task_panel_y, event.y)) {
                if (wb.bottom_panel_mode == .output and wb.references.active) {
                    const references_panel = @import("../../workbench/references_store.zig");
                    if (references_panel.Store.hitTest(
                        geo.editor_x,
                        geo.task_panel_y,
                        geo.task_panel_h,
                        event.x,
                        event.y,
                        wb.task_scroll_y,
                        wb.references.items.len,
                    )) |index| {
                        wb.dispatch(.{ .references_goto = index }) catch {};
                    }
                } else if (wb.bottom_panel_mode == .problems) {
                    const problems_panel = @import("../panel/problems_panel.zig");
                    if (problems_panel.hitTest(
                        geo.editor_x,
                        geo.task_panel_y,
                        geo.task_panel_h,
                        event.x,
                        event.y,
                        wb.task_scroll_y,
                        wb.diagnostics.list.items.len,
                    )) |index| {
                        wb.handleProblemsClick(index) catch {};
                    }
                } else if (wb.bottom_panel_mode == .debug_variables) {
                    const debug_variables = @import("../../workbench/debug_variables.zig");
                    if (debug_variables.hitTest(
                        geo.editor_x,
                        geo.task_panel_y,
                        geo.task_panel_h,
                        event.x,
                        event.y,
                        wb.task_scroll_y,
                        wb.debug_variables.items.items.len,
                    )) |index| {
                        wb.dispatch(.{ .debug_copy_variable = index }) catch {};
                    }
                } else if (wb.bottom_panel_mode == .debug_callstack) {
                    const debug_callstack = @import("../../workbench/debug_callstack.zig");
                    if (debug_callstack.hitTest(
                        geo.editor_x,
                        geo.task_panel_y,
                        geo.task_panel_h,
                        event.x,
                        event.y,
                        wb.task_scroll_y,
                        wb.debug_callstack.items.items.len,
                    )) |index| {
                        wb.dispatch(.{ .debug_stack_goto = index }) catch {};
                    }
                }
                wb.focused_panel = .editor;
            } else {
                wb.focused_panel = .editor;
            }
        }
    } else if (event.action == .up) {
        state.is_dragging_agent_splitter = false;
        state.is_dragging_explorer_splitter = false;
        state.is_dragging_bottom_panel_splitter = false;
        if (state.is_dragging_terminal_selection) {
            state.is_dragging_terminal_selection = false;
            if (wb.terminal_selection) |sel| {
                if (sel.isEmpty()) wb.terminal_selection = null;
            }
        }
        if (state.is_dragging_editor_selection) {
            state.is_dragging_editor_selection = false;
            if (wb.docForPane(wb.editor_pane_focus)) |doc| {
                if (!doc.buffer.hasSelection()) doc.buffer.clearSelection();
            }
        }
    } else if (event.action == .drag) {
        if (state.is_dragging_agent_splitter) {
            wb.agent_panel_width = w - event.x;
            wb.agent_panel_width = @max(200.0, @min(800.0, wb.agent_panel_width));
        } else if (state.is_dragging_explorer_splitter) {
            wb.explorer_panel_width = event.x;
            wb.explorer_panel_width = @max(100.0, @min(500.0, wb.explorer_panel_width));
        } else if (state.is_dragging_bottom_panel_splitter) {
            const new_editor_h = event.y - layout.header_height;
            wb.bottom_panel_height = std.math.clamp(
                geo.content_h - new_editor_h,
                80.0,
                @max(80.0, geo.content_h - 80.0),
            );
            wb.clampBottomPanelScroll(wb.bottom_panel_height);
            wb.syncTerminalSize();
        } else if (state.is_dragging_editor_selection and geo.shell_mode == .ide and editor_hit.isEditorContentArea(geo, event.x, event.y)) {
            const pane = wb.paneAt(geo.editor_x, geo.editor_w, event.x);
            if (wb.docForPane(pane)) |doc| {
                const pane_x = wb.paneOriginX(geo.editor_x, geo.editor_w, pane);
                const pane_w = wb.paneWidth(geo.editor_w);
                const scroll_y = if (pane == .secondary) wb.split_scroll_y else wb.editor_scroll_y;
                const scroll_x = if (pane == .secondary) wb.split_scroll_x else wb.editor_scroll_x;
                if (editor_hit.editorPosAt(wb, &doc.buffer, pane_x, pane_w, scroll_y, scroll_x, event.x, event.y)) |pos| {
                    doc.buffer.cursor.row = pos.row;
                    doc.buffer.cursor.col = pos.col;
                    wb.scrollEditorToCursor();
                }
            }
        } else if (state.is_dragging_terminal_selection and wb.bottom_panel_mode == .terminal) {
            const terminal = wb.activeTerminal();
            terminal.lock();
            defer terminal.unlock();
            if (terminal_panel.hitTest(
                geo.editor_x,
                geo.task_panel_y,
                geo.task_panel_h,
                event.x,
                event.y,
                wb.task_scroll_y,
                terminal.lines.items,
            )) |pos| {
                if (wb.terminal_selection) |*sel| sel.cursor = pos;
            }
        }
    } else if (event.action == .scroll) {
        const mx = state.last_mouse_x;
        const my = state.last_mouse_y;

        // Trackpads provide precise 2D deltas.
        // Multiply by 2.5 to match the fast, smooth feel of Cursor/Electron apps.
        const raw = scroll_axis.predominantDeltas(-event.x * 2.5, -event.y * 2.5);
        const scroll_delta_y = raw.y;
        const scroll_delta_x = raw.x;

        if (geo.shell_mode == .ide and wb.proposal_review_open and mx >= geo.editor_x and mx < geo.agent_splitter_x and my >= proposal_review_panel.contentTop()) {
            wb.proposal_review_scroll_y += scroll_delta_y;
            wb.clampProposalReviewScroll(geo.editor_h);
        } else if (geo.shell_mode == .ide and wb.ai_settings_open and mx >= geo.editor_x and mx < geo.agent_splitter_x and my >= ai_settings_panel.contentTop()) {
            wb.ai_settings_scroll_y += scroll_delta_y;
            wb.clampAiSettingsScroll(geo.editor_h);
        } else if (geo.shell_mode == .ide and mx >= geo.explorer_x and mx < geo.explorer_splitter_x and my >= layout.header_height) {
            switch (wb.sidebar_view) {
                .extensions => {
                    wb.extensions_scroll_y += scroll_delta_y;
                    wb.clampExtensionsScroll(h);
                },
                .ai => {},
                .search => {
                    wb.search_scroll_y += scroll_delta_y;
                    wb.clampSearchScroll(h);
                },
                .git => {
                    wb.git_scroll_y += scroll_delta_y;
                    wb.clampGitScroll(h);
                },
                .run => {
                    wb.run_scroll_y += scroll_delta_y;
                    wb.clampRunScroll(h);
                },
                .explorer => {
                    wb.explorer_scroll_y += scroll_delta_y;
                    wb.clampExplorerScroll(h);
                },
            }
        } else if (mx >= geo.agent_x) {
            if (wb.agent.show_review and !wb.proposal_review_open) {
                wb.agent.review_scroll_y += scroll_delta_y;
                wb.clampReviewScroll(h);
            } else {
                wb.agent.lock();
                const attachment_count = wb.agent.attachments.items.len;
                wb.agent.unlock();
                const agent_panel = @import("../agent/agent_panel.zig");
                const composer_layout = agent_panel.composerLayout(geo.agent_x, geo.agent_w, h, attachment_count, &wb.prompt_buffer);
                if (composer_layout.scroll_max > 0 and agent_panel.hitPromptInput(geo.agent_x, geo.agent_w, h, attachment_count, &wb.prompt_buffer, mx, my)) {
                    wb.prompt_scroll_y += scroll_delta_y;
                    wb.clampPromptScroll(geo.agent_w);
                } else {
                    wb.chat_scroll_y += scroll_delta_y;
                    wb.clampChatScroll(h);
                }
            }
        } else if (geo.shell_mode == .ide and my >= tabs_ui.tab_bar_top and my < tabs_ui.tab_bar_top + tabs_ui.tab_bar_height and mx >= geo.editor_x and mx < geo.agent_splitter_x) {
            const tab_delta = if (scroll_delta_x != 0) scroll_delta_x else scroll_delta_y;
            wb.tab_scroll_x += tab_delta;
            wb.clampTabScroll(geo.editor_w);
        } else if (geo.shell_mode == .ide and my >= geo.task_panel_y and mx >= geo.editor_x and mx < geo.agent_splitter_x) {
            wb.task_scroll_y += scroll_delta_y;
            wb.clampBottomPanelScroll(geo.task_panel_h);
        } else if (geo.shell_mode == .ide and mx >= geo.editor_x and mx < geo.agent_splitter_x and my > 65.0 and my < geo.task_panel_y - 35) {
            const pane = wb.paneAt(geo.editor_x, geo.editor_w, mx);
            if (pane == .secondary) {
                wb.split_scroll_y += scroll_delta_y;
                wb.split_scroll_x += scroll_delta_x;
            } else {
                wb.editor_scroll_y += scroll_delta_y;
                wb.editor_scroll_x += scroll_delta_x;
            }
            wb.clampEditorScroll(geo.editor_w, geo.editor_h);
        }
    }
}

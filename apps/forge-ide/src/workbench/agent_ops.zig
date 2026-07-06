const std = @import("std");
const editor = @import("forge-editor");
const workspace = @import("forge-workspace");
const lsp = @import("forge-lsp");
const ai = @import("forge-ai");
const agent_workflow = @import("../agent/workflow.zig");
const agent_scope_picker = @import("../agent/scope_picker.zig");
const ai_config_io = @import("ai_config_io.zig");
const agent_ui_queue_mod = @import("agent_ui_queue.zig");
const renderer = @import("forge-renderer");
const ChatRole = @import("types.zig").ChatRole;
const Workbench = @import("../workbench.zig").Workbench;

pub fn clearScopePickerPaths(wb: anytype) void {
    for (wb.scope_picker_paths.items) |path| wb.allocator.free(path);
    wb.scope_picker_paths.clearRetainingCapacity();
    wb.scope_picker_filtered.clearRetainingCapacity();
}

pub fn openScopePicker(wb: anytype) !void {
    clearScopePickerPaths(wb);
    try agent_scope_picker.collectFilePaths(wb.allocator, &wb.explorer, &wb.scope_picker_paths);
    wb.agent.openScopePicker();
    try applyScopePickerFilter(wb);
}

pub fn applyScopePickerFilter(wb: anytype) !void {
    wb.agent.lock();
    const query = wb.agent.scope_query[0..wb.agent.scope_query_len];
    wb.agent.unlock();
    try agent_scope_picker.applyFilter(wb.allocator, query, wb.scope_picker_paths.items, &wb.scope_picker_filtered);
    wb.agent.lock();
    if (wb.agent.scope_picker_selected >= wb.scope_picker_filtered.items.len) {
        wb.agent.scope_picker_selected = if (wb.scope_picker_filtered.items.len > 0) wb.scope_picker_filtered.items.len - 1 else 0;
    }
    wb.agent.unlock();
}

pub fn setAgentModelIndex(wb: anytype, index: usize) !void {
    const agent_composer = @import("../ui/agent/agent_composer.zig");
    if (index >= agent_composer.models.len) return;
    const option = agent_composer.models[index];
    if (wb.ai_model) |old| wb.allocator.free(old);
    wb.ai_model = try wb.allocator.dupe(u8, option.id);
    wb.allocator.free(wb.ai_provider);
    wb.ai_provider = try wb.allocator.dupe(u8, option.provider);
    wb.agent.closeMenus();
    try ai_config_io.writeAiProvider(wb.allocator, wb.io, wb.workspace_root, option.provider);
    try ai_config_io.writeAiModel(wb.allocator, wb.io, wb.workspace_root, option.id);
    try wb.setStatus("Model saved to forge.toml");
}

pub fn resolveWorkbenchHome(environ_map: ?*const std.process.Environ.Map) ?[]const u8 {
    if (environ_map) |map| return map.get("HOME");
    return null;
}

pub fn refreshAiMcpStatus(wb: anytype) !void {
    if (wb.ai_mcp_status) |old| wb.allocator.free(old);
    wb.ai_mcp_status = null;

    if (!wb.ai_mcp_enabled) {
        wb.ai_mcp_status = try wb.allocator.dupe(u8, "MCP disabled in forge.toml ([ai] mcp = false)");
        return;
    }

    var registry = ai.mcp_registry.Registry.load(
        wb.allocator,
        wb.io,
        wb.workspace_root,
        wb.workspace_path,
        true,
        resolveWorkbenchHome(wb.environ_map),
        wb.environ_map,
    ) catch |err| {
        const msg = try std.fmt.allocPrint(wb.allocator, "MCP load failed: {}", .{err});
        wb.ai_mcp_status = msg;
        return;
    };
    defer registry.deinit();
    wb.ai_mcp_status = try wb.allocator.dupe(u8, registry.status_lines);
}

pub fn toggleAiMcp(wb: anytype) !void {
    const next = !wb.ai_mcp_enabled;
    try ai_config_io.writeAiMcp(wb.allocator, wb.io, wb.workspace_root, next);
    wb.ai_mcp_enabled = next;
    try refreshAiMcpStatus(
        wb,
    );
    try wb.setStatus(if (next) "MCP tools enabled" else "MCP tools disabled");
}

pub fn openForgeToml(wb: anytype) !void {
    try wb.openFile("forge.toml");
}

pub fn openMcpConfig(wb: anytype) !void {
    try ensureMcpConfigFile(wb);
    const candidates = [_][]const u8{ ".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json" };
    for (candidates) |rel| {
        const wp = workspace.WorkspacePath.parse(rel) catch continue;
        var snap = workspace.FileSnapshot.read(wb.allocator, wb.io, wb.workspace_root, wp) catch continue;
        snap.deinit();
        try wb.openFile(rel);
        return;
    }
    try wb.openFile(".mcp.json");
}

pub fn ensureMcpConfigFile(wb: anytype) !void {
    const target = try workspace.WorkspacePath.parse(".mcp.json");
    if (workspace.FileSnapshot.read(wb.allocator, wb.io, wb.workspace_root, target)) |snap| {
        var owned = snap;
        owned.deinit();
        return;
    } else |_| {}

    const example = try workspace.WorkspacePath.parse(".mcp.json.example");
    var example_snap = try workspace.FileSnapshot.read(wb.allocator, wb.io, wb.workspace_root, example);
    defer example_snap.deinit();
    try workspace.atomic.replaceFile(wb.io, wb.workspace_root, target, example_snap.content);
}

pub fn openAiSettings(wb: anytype) !void {
    if (!wb.ai_settings_open) {
        wb.previous_focus = wb.focused_panel;
    }
    wb.ai_settings_open = true;
    wb.sidebar_visible = true;
    wb.sidebar_view = .ai;
    wb.focused_panel = .ai_settings;
    wb.ai_settings_scroll_y = 0;
    try refreshAiMcpStatus(
        wb,
    );
}

pub fn closeAiSettings(wb: anytype) void {
    wb.ai_settings_open = false;
    if (wb.focused_panel == .ai_settings) {
        wb.focused_panel = if (wb.previous_focus == .ai_settings) .editor else wb.previous_focus;
    }
    if (wb.sidebar_view == .ai) wb.sidebar_view = .explorer;
}

pub fn openProposalReview(wb: anytype) void {
    if (!wb.proposal_review_open) {
        wb.previous_focus = wb.focused_panel;
    }
    wb.proposal_review_open = true;
    wb.proposal_review_scroll_y = 0;
    wb.proposal_review_file_index = 0;
    wb.focused_panel = .proposal_review;
}

pub fn closeProposalReview(wb: anytype) void {
    wb.proposal_review_open = false;
    if (wb.focused_panel == .proposal_review) {
        wb.focused_panel = if (wb.previous_focus == .proposal_review) .agent else wb.previous_focus;
    }
}

pub fn handleProposalReviewClick(wb: anytype, hit: @import("../ui/editor/proposal_review_panel.zig").Hit) !void {
    switch (hit) {
        .close_tab => closeProposalReview(
            wb,
        ),
        .select_file => |index| {
            wb.proposal_review_file_index = index;
            wb.proposal_review_scroll_y = 0;
        },
        .toggle_hunk => |index| {
            wb.agent.lock();
            wb.agent.review.toggle(index);
            wb.agent.unlock();
        },
        .apply => try wb.dispatch(.agent_apply),
        .reject => try wb.dispatch(.agent_reject),
    }
}

pub fn handleAiSettingsClick(wb: anytype, hit: @import("../ui/agent/ai_settings_panel.zig").Hit) !void {
    switch (hit) {
        .toggle_mcp => try wb.toggleAiMcp(),
        .open_forge_toml => {
            closeAiSettings(
                wb,
            );
            try openForgeToml(
                wb,
            );
        },
        .open_mcp_json => {
            closeAiSettings(
                wb,
            );
            try openMcpConfig(
                wb,
            );
        },
        .refresh_mcp => try refreshAiMcpStatus(
            wb,
        ),
        .close_tab => closeAiSettings(
            wb,
        ),
    }
}

pub fn pasteIntoAgent(wb: anytype) !void {
    const timestamp_ms = std.Io.Timestamp.now(wb.io, .real).toMilliseconds();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel_path = try std.fmt.bufPrint(&path_buf, ".forge/attachments/att_{d}.png", .{timestamp_ms});
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ wb.workspace_path, rel_path });

    try ensureAgentAttachmentsDir(
        wb,
    );

    if (renderer.Renderer.saveClipboardPng(abs_path)) {
        var label_buf: [64:0]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "image_{d}.png", .{timestamp_ms}) catch "image.png";
        label_buf[label.len] = 0;
        try wb.agent.addAttachment(.{
            .kind = .image,
            .label = try wb.allocator.dupe(u8, label_buf[0..label.len]),
            .stored_path = try wb.allocator.dupe(u8, rel_path),
            .text_preview = null,
        });
        refreshAgentContextPreview(
            wb,
        );
        try wb.setStatus("Pasted image attachment");
        return;
    }

    const text = renderer.Renderer.clipboardText(wb.allocator) catch return;
    defer wb.allocator.free(text);
    if (text.len == 0) return;

    if (text.len > 4096) {
        var label_buf: [32:0]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "paste_{d}.txt", .{timestamp_ms}) catch "paste.txt";
        label_buf[label.len] = 0;
        const preview = try wb.allocator.dupe(u8, text[0..4096]);
        try wb.agent.addAttachment(.{
            .kind = .text_snippet,
            .label = try wb.allocator.dupe(u8, label_buf[0..label.len]),
            .stored_path = null,
            .text_preview = preview,
        });
        refreshAgentContextPreview(
            wb,
        );
        try wb.setStatus("Pasted text attachment");
        return;
    }

    try wb.prompt_buffer.insertString(text);
    ensurePromptCursorVisible(
        wb,
    );
}

pub fn ensureAgentAttachmentsDir(wb: anytype) !void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.forge/attachments", .{wb.workspace_path});
    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), wb.io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn ensurePromptCursorVisible(wb: anytype) void {
    var w: f32 = 0;
    var h: f32 = 0;
    renderer.Renderer.getWindowSize(&w, &h);
    const geo = wb.layoutGeometry(w, h);
    const ac = @import("../ui/agent/agent_composer.zig");
    const max_w = ac.promptMaxWidth(geo.agent_w);
    const input_h = wb.composerInputHeight(geo.agent_w);
    wb.prompt_scroll_y = ac.ensureCursorVisible(wb.prompt_scroll_y, &wb.prompt_buffer, max_w, input_h);
}

pub fn refreshAgentContextPreview(wb: anytype) void {
    const host = agentHost(wb);
    const active = wb.tabs.activeDoc();
    const active_path = if (active) |doc| doc.path else null;
    const intent_owned = blk: {
        wb.agent.lock();
        defer wb.agent.unlock();
        if (wb.agent.intent) |text| break :blk wb.allocator.dupe(u8, text) catch null;
        break :blk null;
    };
    if (intent_owned) |intent| {
        defer wb.allocator.free(intent);
        agent_workflow.refreshContextPreview(&host, intent, active_path) catch {};
        return;
    }
    const prompt = wb.prompt_buffer.content() catch return;
    defer wb.prompt_buffer.allocator.free(prompt);
    const trimmed = std.mem.trim(u8, prompt, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        agent_workflow.refreshContextPreview(&host, null, active_path) catch {};
    } else {
        agent_workflow.refreshContextPreview(&host, trimmed, active_path) catch {};
    }
}

pub fn selectScopePickerEntry(wb: anytype) !void {
    const query = wb.agent.scope_query[0..wb.agent.scope_query_len];
    const total_rows = agent_scope_picker.visibleRowCount(wb.scope_picker_filtered.items.len, query);
    if (total_rows == 0) {
        wb.agent.closeScopePicker();
        return;
    }
    wb.agent.lock();
    const selected = wb.agent.scope_picker_selected;
    wb.agent.unlock();

    if (agent_scope_picker.pinnedMarkerAt(query, selected)) |marker| {
        try wb.agent.addScopeFile(marker);
    } else if (agent_scope_picker.fileListIndex(selected, query)) |list_index| {
        if (list_index >= wb.scope_picker_filtered.items.len) return;
        const path_index = wb.scope_picker_filtered.items[list_index];
        const path = wb.scope_picker_paths.items[path_index];
        try wb.agent.addScopeFile(path);
    }
    wb.agent.closeScopePicker();
    refreshAgentContextPreview(
        wb,
    );
    try wb.setStatus("Added to agent scope");
}

pub fn scrollChatToEnd(wb: anytype, agent_h: f32) void {
    const layout_mod = @import("../ui/core/layout.zig");
    const context_inspector_mod = @import("../ui/agent/context_inspector.zig");
    const agent_panel_mod = @import("../ui/agent/agent_panel.zig");
    const chat_bubble_mod = @import("../ui/agent/chat_bubble.zig");
    const content_w = @max(40, wb.agent_panel_width - 40);
    var estimated_lines: usize = 0;
    for (wb.chat_history.items) |msg| {
        if (!agent_panel_mod.chatHasVisibleContent(msg.content)) continue;
        const msg_h = chat_bubble_mod.historyMessageHeight(msg.role == .user, msg.content, content_w);
        estimated_lines += @max(1, @as(usize, @intFromFloat(std.math.ceil(msg_h / chat_bubble_mod.line_h))));
    }
    wb.agent.lock();
    if (wb.agent.worker_running) {
        estimated_lines += chat_bubble_mod.estimateLiveLines(
            wb.agent.thinking_text.items,
            wb.agent.stream_text.items,
            true,
            content_w,
        );
        const tool_step_card_mod = @import("../ui/agent/tool_step_card.zig");
        const steps_h = tool_step_card_mod.totalStepsHeight(wb.agent.agent_steps.items, content_w, wb.agent.mode);
        estimated_lines += @as(usize, @intFromFloat(std.math.ceil(steps_h / chat_bubble_mod.line_h)));
    }
    const entry_count = wb.agent.context_entries.items.len;
    const expanded = wb.agent.context_inspector_expanded;
    const has_detail = wb.agent.context_selected_index != null and expanded;
    const attachment_count = wb.agent.attachments.items.len;
    wb.agent.unlock();
    const has_routing = wb.agent.hasRoutingPreview();
    const bottom = agent_panel_mod.bottomReserved(attachment_count, wb.agent_panel_width, &wb.prompt_buffer) + context_inspector_mod.stripHeight(expanded, entry_count, has_detail, has_routing);
    const viewport = @max(0, agent_h - layout_mod.status_height - 90 - bottom);
    const content_h = @as(f32, @floatFromInt(estimated_lines)) * chat_bubble_mod.line_h;
    wb.chat_scroll_y = @max(0, content_h - viewport);
}

pub fn showAgentReview(wb: anytype) !void {
    var owned_path: ?[]const u8 = null;
    defer if (owned_path) |path| wb.allocator.free(path);

    const proposal_rel = blk: {
        wb.agent.lock();
        defer wb.agent.unlock();
        if (wb.agent.proposal_rel) |path| break :blk path;
        if (wb.agent.run_history.items.len == 0) break :blk null;
        const entry = wb.agent.run_history.items[wb.agent.selected_run_index];
        owned_path = try std.fmt.allocPrint(wb.allocator, ".forge/proposals/{s}.json", .{entry.run_id});
        break :blk owned_path.?;
    };

    if (proposal_rel) |rel| {
        try agent_workflow.loadProposalPreview(&agentHost(wb), rel);
        openProposalReview(
            wb,
        );
        wb.focused_panel = .proposal_review;
        try wb.setStatus("Proposal review opened");
        return;
    }
    try wb.setStatus("No proposal to review — submit an agent prompt first");
}

pub fn agentHost(wb: anytype) agent_workflow.Host {
    return .{
        .allocator = wb.allocator,
        .io = wb.io,
        .environ_map = wb.environ_map,
        .ai_provider = wb.ai_provider,
        .ai_model = wb.ai_model,
        .ai_mcp_enabled = wb.ai_mcp_enabled,
        .workspace_root = wb.workspace_root,
        .workspace_path = wb.workspace_path,
        .agent = &wb.agent,
        .agent_cancel_slot = &wb.agent_cancel_source,
        .context = wb,
        .append_chat = bridgeAppendChat,
        .set_status = bridgeSetStatus,
        .enqueue_ui = bridgeEnqueueAgentUi,
        .refresh_explorer = bridgeRefreshExplorer,
        .open_file = bridgeOpenFile,
        .snapshot_conversation = bridgeSnapshotConversation,
        .free_conversation_snapshot = bridgeFreeConversationSnapshot,
        .snapshot_recent_files = bridgeSnapshotRecentFiles,
        .free_recent_files_snapshot = bridgeFreeRecentFilesSnapshot,
        .snapshot_context_supplement = bridgeSnapshotContextSupplement,
        .free_context_supplement = bridgeFreeContextSupplement,
    };
}

pub fn snapshotContextSupplement(wb: anytype, allocator: std.mem.Allocator) !ai.context_supplement.Supplement {
    var diagnostics: std.ArrayList(ai.context_supplement.DiagnosticEntry) = .empty;
    errdefer ai.context_supplement.freeDiagnosticEntries(allocator, diagnostics.items);

    var lsp_hints: std.ArrayList(ai.context_supplement.LspHint) = .empty;
    errdefer ai.context_supplement.freeLspHints(allocator, lsp_hints.items);

    var cursor_owned: ?[]const u8 = null;
    errdefer if (cursor_owned) |path| allocator.free(path);

    var hover_owned: ?[]const u8 = null;
    errdefer if (hover_owned) |text| allocator.free(text);

    var cursor_pos: ?ai.context_supplement.CursorPosition = null;

    const doc = wb.tabs.activeDoc();
    if (doc) |active| {
        cursor_owned = try allocator.dupe(u8, active.path);
        const line: u32 = @intCast(active.buffer.cursor.row);
        const character: u32 = @intCast(active.buffer.cursor.col);
        cursor_pos = .{
            .path = cursor_owned.?,
            .line = line,
            .character = character,
        };

        for (wb.diagnostics.list.items) |diag| {
            try diagnostics.append(allocator, .{
                .path = try allocator.dupe(u8, active.path),
                .line = diag.line,
                .character = diag.character,
                .severity = try allocator.dupe(u8, diagnosticSeverityLabel(diag.severity)),
                .message = try allocator.dupe(u8, diag.message),
            });
        }

        const owned = wb.lsp_registry.copyMatchForPath(allocator, active.path) catch null;
        if (owned) |config| {
            defer lsp.Registry.freeConfig(allocator, config);

            if (@import("editor_ops.zig").lspSyncDocument(wb, active)) |uri| {
                defer allocator.free(uri);

                const hover_req = lsp.hover.buildHoverRequest(allocator, 93, uri, line, character) catch null;
                if (hover_req) |hover_req_body| {
                    defer allocator.free(hover_req_body);
                    var hover_buf: [65536]u8 = undefined;
                    if (wb.lsp_proxy.request(config.language_id, hover_req_body, &hover_buf, hover_buf.len) catch null) |hover_len| {
                        hover_owned = lsp.hover.parseHoverResponse(allocator, hover_buf[0..hover_len]) catch null;
                    }
                }

                const def_req = lsp.navigation.buildDefinitionRequest(allocator, 91, uri, line, character) catch null;
                if (def_req) |req| {
                    defer allocator.free(req);
                    var response_buf: [65536]u8 = undefined;
                    if (wb.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len)) |len| {
                        if (lsp.navigation.parseDefinitionResponse(allocator, response_buf[0..len])) |location| {
                            if (location) |loc_value| {
                                var loc = loc_value;
                                defer loc.deinit(allocator);
                                if (lsp.navigation.uriToRelativePath(allocator, wb.workspace_path, loc.uri) catch null) |rel| {
                                    try lsp_hints.append(allocator, .{
                                        .kind = .definition,
                                        .path = rel,
                                        .line = loc.line,
                                        .character = loc.character,
                                    });
                                }
                            }
                        } else |_| {}
                    } else |_| {}
                }

                const refs_req = lsp.references.buildReferencesRequest(allocator, 94, uri, line, character) catch null;
                if (refs_req) |req| {
                    defer allocator.free(req);
                    var response_buf: [65536]u8 = undefined;
                    if (wb.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len)) |len| {
                        if (lsp.references.parseReferencesResponse(allocator, response_buf[0..len])) |list| {
                            var owned_list = list;
                            defer owned_list.deinit(allocator);
                            var ref_count: usize = 0;
                            for (owned_list.items) |loc_value| {
                                if (ref_count >= 5) break;
                                var loc = loc_value;
                                defer loc.deinit(allocator);
                                if (lsp.navigation.uriToRelativePath(allocator, wb.workspace_path, loc.uri) catch null) |rel| {
                                    try lsp_hints.append(allocator, .{
                                        .kind = .reference,
                                        .path = rel,
                                        .line = loc.line,
                                        .character = loc.character,
                                    });
                                    ref_count += 1;
                                }
                            }
                        } else |_| {}
                    } else |_| {}
                }
            } else |_| {}
        }
    }

    return .{
        .cursor = cursor_pos,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .lsp_hints = try lsp_hints.toOwnedSlice(allocator),
        .hover_text = hover_owned,
    };
}

pub fn diagnosticSeverityLabel(severity: lsp.diagnostics.Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .info => "info",
        .hint => "hint",
        else => "unknown",
    };
}

pub fn bridgeSnapshotContextSupplement(context: ?*anyopaque, allocator: std.mem.Allocator) ai.context_supplement.Supplement {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    return snapshotContextSupplement(wb, allocator) catch .{};
}

pub fn bridgeFreeContextSupplement(context: ?*anyopaque, allocator: std.mem.Allocator, supplement: ai.context_supplement.Supplement) void {
    _ = context;
    ai.context_supplement.freeSupplement(allocator, supplement);
}

pub fn snapshotRecentTabPaths(wb: anytype, allocator: std.mem.Allocator) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    if (wb.tabs.tabs.items.len == 0) return try paths.toOwnedSlice(allocator);

    if (wb.tabs.active < wb.tabs.tabs.items.len) {
        try paths.append(allocator, try allocator.dupe(u8, wb.tabs.tabs.items[wb.tabs.active].path));
    }

    var index = wb.tabs.tabs.items.len;
    while (index > 0) {
        index -= 1;
        if (index == wb.tabs.active) continue;
        const path = wb.tabs.tabs.items[index].path;
        var duplicate = false;
        for (paths.items) |existing| {
            if (std.mem.eql(u8, existing, path)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        try paths.append(allocator, try allocator.dupe(u8, path));
    }

    return try paths.toOwnedSlice(allocator);
}

pub fn bridgeSnapshotRecentFiles(context: ?*anyopaque, allocator: std.mem.Allocator) []const []const u8 {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    return snapshotRecentTabPaths(wb, allocator) catch return &.{};
}

pub fn bridgeFreeRecentFilesSnapshot(context: ?*anyopaque, allocator: std.mem.Allocator, paths: []const []const u8) void {
    _ = context;
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

pub fn snapshotAgentConversation(wb: anytype, allocator: std.mem.Allocator) ![]ai.conversation.Turn {
    var turns: std.ArrayList(ai.conversation.Turn) = .empty;
    errdefer ai.conversation.freeTurns(allocator, turns.items);

    var end = wb.chat_history.items.len;
    if (end > 0 and wb.chat_history.items[end - 1].role == .user) end -= 1;

    const start = if (end > ai.conversation.max_turns) end - ai.conversation.max_turns else 0;
    for (wb.chat_history.items[start..end]) |msg| {
        const slice = ai.conversation.truncateContent(msg.content);
        try turns.append(allocator, .{
            .role = switch (msg.role) {
                .user => .user,
                .agent => .agent,
            },
            .content = try allocator.dupe(u8, slice),
        });
    }
    return try turns.toOwnedSlice(allocator);
}

pub fn bridgeSnapshotConversation(context: ?*anyopaque, allocator: std.mem.Allocator) []const ai.conversation.Turn {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    return snapshotAgentConversation(wb, allocator) catch return &.{};
}

pub fn bridgeFreeConversationSnapshot(context: ?*anyopaque, allocator: std.mem.Allocator, turns: []const ai.conversation.Turn) void {
    _ = context;
    ai.conversation.freeTurns(allocator, turns);
}

pub fn bridgeAppendChat(context: ?*anyopaque, role: agent_workflow.ChatRole, content: []const u8) void {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    const mapped: ChatRole = if (role == .user) .user else .agent;
    appendChat(wb, mapped, content) catch {};
}

pub fn bridgeSetStatus(context: ?*anyopaque, message: []const u8) void {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    wb.setStatus(message) catch {};
}

pub fn bridgeEnqueueAgentUi(context: ?*anyopaque, op: agent_ui_queue_mod.Op) void {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    wb.agent_ui_queue.push(wb.allocator, op) catch {
        var owned = op;
        owned.deinit(wb.allocator);
    };
}

pub fn flushAgentUi(wb: anytype) !void {
    const agent_panel_mod = @import("../ui/agent/agent_panel.zig");
    const ops = try wb.agent_ui_queue.takeAll(wb.allocator);
    defer wb.allocator.free(ops);
    const host = agentHost(wb);
    for (ops) |*op| {
        defer op.deinit(wb.allocator);
        switch (op.*) {
            .append_chat => |payload| {
                const mapped: ChatRole = if (payload.role == .user) .user else .agent;
                try wb.appendChat(mapped, payload.text);
            },
            .set_status => |text| try wb.setStatus(text),
            .append_thinking => |text| {
                try wb.agent.appendThinkingChunk(text);
                wb.scrollChatToEnd(768);
            },
            .append_stream => |text| {
                try wb.agent.appendStreamChunk(text);
                wb.scrollChatToEnd(768);
            },
            .begin_step => |payload| {
                try wb.agent.beginAgentStep(payload.index, payload.kind, payload.label);
                wb.scrollChatToEnd(768);
            },
            .append_step => |payload| {
                try wb.agent.appendAgentStep(payload.index, payload.kind, payload.summary);
                wb.scrollChatToEnd(768);
            },
            .set_phase => |payload| {
                if (payload.phase == .sending) {
                    wb.agent.clearStreamText();
                } else if (payload.phase == .streaming) {
                    wb.agent.lock();
                    wb.agent.stream_live = true;
                    wb.agent.unlock();
                }
                try wb.agent.setPhase(payload.phase, payload.label);
            },
            .run_finished => |payload| {
                wb.agent.lock();
                if (wb.agent.run_id) |old| wb.allocator.free(old);
                if (wb.agent.proposal_rel) |old| wb.allocator.free(old);
                wb.agent.run_id = try wb.allocator.dupe(u8, payload.run_id);
                if (wb.agent.mode == .ask or payload.proposal_rel.len == 0) {
                    wb.agent.proposal_rel = null;
                } else {
                    wb.agent.proposal_rel = try wb.allocator.dupe(u8, payload.proposal_rel);
                }
                wb.agent.worker_running = false;
                wb.agent.unlock();

                try agent_workflow.applyManifestText(&host, payload.manifest_text);
                if (payload.proposal_rel.len > 0 and wb.agent.mode != .ask) {
                    try agent_workflow.loadProposalPreview(&host, payload.proposal_rel);
                    openProposalReview(
                        wb,
                    );
                    try wb.agent.setPhase(.proposal_ready, "Proposal ready for review");
                    try wb.setStatus("Proposal ready for review");
                } else {
                    if (wb.agent.mode == .ask) {
                        try wb.agent.setPhase(.idle, "Answer ready");
                        try wb.setStatus("Answer ready");
                    } else if (wb.agent.mode == .agent) {
                        try wb.agent.setPhase(.idle, "Agent finished without a proposal");
                        try wb.setStatus("Agent finished without a proposal");
                    } else {
                        try wb.agent.setPhase(.idle, "Spec ready — approve to continue");
                        try wb.setStatus("Spec ready — approve to continue");
                    }
                }
                try agent_workflow.refreshRunHistory(&host);
                if (payload.plan_text) |plan| {
                    if (agent_panel_mod.chatHasVisibleContent(plan)) {
                        try wb.appendChat(.agent, plan);
                    }
                }
                if (agent_panel_mod.chatHasVisibleContent(payload.chat_text)) {
                    try wb.appendChat(.agent, payload.chat_text);
                }
                wb.scrollChatToEnd(768);
            },
            .run_failed => |payload| {
                wb.agent.lock();
                wb.agent.worker_running = false;
                wb.agent.unlock();
                try wb.agent.setPhase(payload.phase, payload.message);
                try wb.appendChat(.agent, payload.message);
                try wb.setStatus(payload.message);
            },
            .refresh_context_preview => refreshAgentContextPreview(
                wb,
            ),
            .propose_edit => {
                // Legacy queue event retained for schema compatibility. Model
                // edits are rendered only from a persisted proposal review.
                try wb.setStatus("Pending AI edit captured for proposal review");
            },
        }
    }
}

pub fn appendChat(wb: anytype, role: ChatRole, content: []const u8) !void {
    const agent_panel_mod = @import("../ui/agent/agent_panel.zig");
    if (!agent_panel_mod.chatHasVisibleContent(content)) return;
    const owned = try wb.allocator.dupeZ(u8, content);
    try wb.chat_history.append(wb.allocator, .{ .role = role, .content = owned });
    wb.persistChatHistory() catch {};
}

pub fn bridgeRefreshExplorer(context: ?*anyopaque) void {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    wb.explorer.rebuild(wb.io, wb.workspace_root) catch {};
}

pub fn bridgeOpenFile(context: ?*anyopaque, path: []const u8) void {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    wb.dispatch(.{ .open_file = path }) catch {};
}

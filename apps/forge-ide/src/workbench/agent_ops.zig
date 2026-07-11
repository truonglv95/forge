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
    if (index >= wb.ai_models.len) return;
    const option = wb.ai_models[index];
    if (wb.ai_model) |old| wb.allocator.free(old);
    wb.ai_model = try wb.allocator.dupe(u8, option.id);
    wb.allocator.free(wb.ai_provider);
    wb.ai_provider = try wb.allocator.dupe(u8, option.provider);
    wb.agent.closeMenus();
    try ai_config_io.writeAiProvider(wb.allocator, wb.io, wb.workspace_root, option.provider);
    try ai_config_io.writeAiModel(wb.allocator, wb.io, wb.workspace_root, option.id);
    for (wb.tabs.tabs.items) |*doc| {
        const wp = @import("forge-workspace").WorkspacePath.parse(doc.path) catch continue;
        if (std.mem.eql(u8, wp.raw, "forge.toml")) {
            @import("../workspace_io.zig").loadDocument(wb.io, wb.workspace_root, doc) catch {};
        }
    }
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
    try ensureAgentAttachmentsDir(wb);

    // Build absolute path in session dir
    const session_dir = try workspace.global_store.getSessionDir(wb.allocator, wb.io, wb.workspace_root);
    defer wb.allocator.free(session_dir);
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fmt.bufPrint(&abs_buf, "{s}/attachments/att_{d}.png", .{ session_dir, timestamp_ms });

    if (renderer.Renderer.saveClipboardPng(abs_path)) {
        var label_buf: [64:0]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "image_{d}.png", .{timestamp_ms}) catch "image.png";
        label_buf[label.len] = 0;
        try wb.agent.addAttachment(.{
            .kind = .image,
            .label = try wb.allocator.dupe(u8, label_buf[0..label.len]),
            .stored_path = try wb.allocator.dupe(u8, abs_path),
            .text_preview = null,
        });
        refreshAgentContextPreview(wb);
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
    const session_dir = try workspace.global_store.getSessionDir(wb.allocator, wb.io, wb.workspace_root);
    defer wb.allocator.free(session_dir);
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const att_dir = try std.fmt.bufPrint(&dir_buf, "{s}/attachments", .{session_dir});
    workspace.global_store.mkdirAllAbsolute(att_dir) catch |err| switch (err) {
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
    wb.agent.lock();
    const worker_running = wb.agent.worker_running;
    wb.agent.unlock();
    if (worker_running) return;

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

pub fn scrollChatToEnd(wb: anytype) void {
    var win_w: f32 = 0;
    var win_h: f32 = 0;
    renderer.Renderer.getWindowSize(&win_w, &win_h);
    @import("chat_layout.zig").scrollToEnd(wb, win_h);
}

fn scrollChatToEndWithHeight(wb: anytype, agent_h: f32) void {
    @import("chat_layout.zig").scrollToEnd(wb, agent_h);
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
        // Build absolute proposal path in session dir
        const sess_dir = workspace.global_store.getSessionDir(wb.allocator, wb.io, wb.workspace_root) catch null;
        if (sess_dir) |sd| {
            const proposal_abs = std.fmt.allocPrint(wb.allocator, "{s}/proposals/{s}.json", .{ sd, entry.run_id }) catch {
                wb.allocator.free(sd);
                break :blk null;
            };
            wb.allocator.free(sd);
            owned_path = proposal_abs;
        } else {
            // Fallback: construct relative path (legacy)
            owned_path = std.fmt.allocPrint(wb.allocator, ".forge/proposals/{s}.json", .{entry.run_id}) catch null;
        }
        break :blk owned_path;
    };

    if (proposal_rel) |rel| {
        try agent_workflow.loadProposalPreview(&agentHost(wb), rel);
        openProposalReview(wb);
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
        .ai_ollama_url = wb.ai_ollama_url,
        .ai_openrouter_url = wb.ai_openrouter_url,
        .ai_embedding_provider = wb.ai_embedding_provider,
        .ai_embedding_model = wb.ai_embedding_model,
        .ai_embedding_url = wb.ai_embedding_url,
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
        .snapshot_editor_selection = bridgeSnapshotEditorSelection,
        .lsp_request = bridgeLspRequest,
    };
}

fn bridgeLspRequest(context: ?*anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ?[]const u8 {
    const wb = @as(*Workbench, @ptrCast(@alignCast(context.?)));

    var language_id: ?[]const u8 = null;
    wb.lsp_registry.mutex.lock();
    if (wb.lsp_registry.servers.items.len > 0) {
        language_id = wb.allocator.dupe(u8, wb.lsp_registry.servers.items[0].language_id) catch null;
    }
    wb.lsp_registry.mutex.unlock();

    const lang = language_id orelse return null;
    defer wb.allocator.free(lang);

    const id = blk: {
        const S = struct {
            var counter: u32 = 0;
        };
        S.counter += 1;
        break :blk S.counter;
    };
    const req_json = std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
    , .{ id, method, params_json }) catch return null;
    defer allocator.free(req_json);

    var response_buf: [2 * 1024 * 1024]u8 = undefined;
    const len = wb.lsp_proxy.request(lang, req_json, &response_buf, response_buf.len) catch return null;

    return allocator.dupe(u8, response_buf[0..len]) catch null;
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

pub fn snapshotEditorSelection(wb: anytype, allocator: std.mem.Allocator) !?[]const u8 {
    const doc = wb.tabs.activeDoc() orelse return null;
    if (!doc.buffer.hasSelection()) return null;
    const selected = try doc.buffer.selectedText(allocator);
    if (selected.len == 0) {
        allocator.free(selected);
        return null;
    }
    return selected;
}

pub fn bridgeSnapshotEditorSelection(context: ?*anyopaque, allocator: std.mem.Allocator) ?[]const u8 {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    return snapshotEditorSelection(wb, allocator) catch null;
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
        if (msg.role == .tool) continue;
        const slice = ai.conversation.truncateContent(msg.content);
        try turns.append(allocator, .{
            .role = switch (msg.role) {
                .user => .user,
                .agent => .agent,
                .tool => unreachable,
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

fn findOpenDoc(wb: anytype, path: []const u8) ?*editor.Document {
    for (wb.tabs.tabs.items, 0..) |*doc, index| {
        if (std.mem.eql(u8, doc.path, path)) {
            wb.tabs.active = index;
            return doc;
        }
    }
    return null;
}

fn lineRangeOffsets(content: []const u8, start_line: usize, end_line: usize) struct { start: usize, end: usize } {
    if (start_line == 0 and end_line == 0) return .{ .start = 0, .end = content.len };

    const start_target = @max(start_line, 1);
    var cursor: usize = 0;
    var line_no: usize = 1;
    while (line_no < start_target and cursor < content.len) : (line_no += 1) {
        while (cursor < content.len and content[cursor] != '\n') cursor += 1;
        if (cursor < content.len and content[cursor] == '\n') cursor += 1;
    }

    const start_offset = cursor;
    if (end_line < start_target) return .{ .start = start_offset, .end = start_offset };

    while (line_no <= end_line and cursor < content.len) : (line_no += 1) {
        while (cursor < content.len and content[cursor] != '\n') cursor += 1;
        if (cursor < content.len and content[cursor] == '\n') cursor += 1;
    }

    return .{ .start = start_offset, .end = cursor };
}

fn applyDirectAgentEdit(wb: anytype, path: []const u8, start_line: usize, end_line: usize, replacement: []const u8) !void {
    const trimmed_path = std.mem.trim(u8, path, &std.ascii.whitespace);
    if (trimmed_path.len == 0) return;

    const doc = findOpenDoc(wb, trimmed_path) orelse blk: {
        if (wb.openFile(trimmed_path)) |_| {
            break :blk wb.tabs.activeDoc() orelse return;
        } else |_| {
            const created = try wb.tabs.openOrActivate(trimmed_path);
            try created.buffer.loadFromSlice("");
            wb.focused_panel = .editor;
            break :blk created;
        }
    };

    const old_content = try doc.buffer.content();
    defer doc.buffer.allocator.free(old_content);

    const range = lineRangeOffsets(old_content, start_line, end_line);
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(wb.allocator);
    try next.appendSlice(wb.allocator, old_content[0..range.start]);
    try next.appendSlice(wb.allocator, replacement);
    try next.appendSlice(wb.allocator, old_content[range.end..]);
    try doc.buffer.loadFromSlice(next.items);
    try @import("../workspace_io.zig").saveDocument(wb.io, wb.workspace_root, doc);
    try wb.events.publish(.{ .file_saved = doc.path });

    wb.focused_panel = .editor;
    wb.explorer.select(trimmed_path) catch {};
    wb.diagnostics.setActivePath(trimmed_path) catch {};
    if (@import("editor_ops.zig").lspSyncDocument(wb, doc)) |uri| {
        wb.allocator.free(uri);
    } else |_| {}

    var status_buf: [160]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "AI edited {s} lines {d}-{d}", .{ trimmed_path, start_line, end_line }) catch "AI edit applied";
    try wb.setStatus(status);
}

pub fn flushAgentUi(wb: anytype) !void {
    const ops = try wb.agent_ui_queue.takeAll(wb.allocator);
    defer wb.allocator.free(ops);
    const host = agentHost(wb);
    var pending_context_refresh = false;
    for (ops) |*op| {
        defer op.deinit(wb.allocator);
        switch (op.*) {
            .refresh_context_preview => pending_context_refresh = true,
            .append_chat => |payload| {
                const mapped: ChatRole = if (payload.role == .user) .user else .agent;
                try wb.appendChat(mapped, payload.text);
            },
            .set_status => |text| try wb.setStatus(text),
            .append_thinking => |text| {
                try wb.agent.appendThinkingChunk(text);
                wb.chat_follow_stream = true;
                wb.chat_scroll_to_end_on_ready = true;
            },
            .append_stream => |text| {
                try wb.agent.appendStreamChunk(text);
                wb.chat_follow_stream = true;
                wb.chat_scroll_to_end_on_ready = true;
            },
            .begin_step => |payload| {
                try flushLiveAssistantBeforeTool(wb);
                try wb.agent.beginAgentStep(payload.index, payload.kind, payload.label, payload.content);
                try appendToolChatStep(wb, payload.index, payload.kind, payload.label, payload.content, true);
                wb.chat_follow_stream = true;
                wb.chat_scroll_to_end_on_ready = true;
            },
            .append_step => |payload| {
                try wb.agent.appendAgentStep(payload.index, payload.kind, payload.summary);
                try finishToolChatStep(wb, payload.index, payload.kind, payload.summary);
                wb.chat_follow_stream = true;
                wb.chat_scroll_to_end_on_ready = true;
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
                wb.chat_scroll_to_end_on_ready = true;
            },
            .run_finished => |payload| {
                wb.agent.lock();
                const stream_snapshot = wb.allocator.dupe(u8, wb.agent.stream_text.items) catch {
                    wb.agent.unlock();
                    return;
                };
                errdefer wb.allocator.free(stream_snapshot);
                const thinking_snapshot = wb.allocator.dupe(u8, wb.agent.thinking_text.items) catch {
                    wb.agent.unlock();
                    wb.allocator.free(stream_snapshot);
                    return;
                };
                errdefer wb.allocator.free(thinking_snapshot);
                if (wb.agent.run_id) |old| wb.allocator.free(old);
                if (wb.agent.proposal_rel) |old| wb.allocator.free(old);
                wb.agent.run_id = try wb.allocator.dupe(u8, payload.run_id);
                if (wb.agent.mode == .ask or payload.proposal_rel.len == 0) {
                    wb.agent.proposal_rel = null;
                } else {
                    wb.agent.proposal_rel = try wb.allocator.dupe(u8, payload.proposal_rel);
                }
                wb.agent.stream_text.clearRetainingCapacity();
                wb.agent.thinking_text.clearRetainingCapacity();
                wb.agent.stream_live = false;
                wb.agent.worker_running = false;
                wb.agent.unlock();

                agent_workflow.applyManifestText(&host, payload.manifest_text) catch {};
                if (payload.proposal_rel.len > 0 and wb.agent.mode != .ask) {
                    if (agent_workflow.loadProposalPreview(&host, payload.proposal_rel)) {
                        openProposalReview(wb);
                        try wb.agent.setPhase(.proposal_ready, "Proposal ready for review");
                        try wb.setStatus("Proposal ready for review");
                    } else |_| {
                        try wb.agent.setPhase(.idle, "Proposal preview unavailable");
                        try wb.setStatus("Proposal preview unavailable");
                    }
                } else if (wb.agent.mode == .ask) {
                    try wb.agent.setPhase(.idle, "Answer ready");
                    try wb.setStatus("Answer ready");
                } else if (wb.agent.mode == .agent) {
                    try wb.agent.setPhase(.idle, "Agent finished");
                    try wb.setStatus("Agent finished");
                } else {
                    try wb.agent.setPhase(.idle, "Spec ready — approve to continue");
                    try wb.setStatus("Spec ready — approve to continue");
                }
                agent_workflow.refreshRunHistory(&host) catch {};
                try appendAgentRunChat(wb, payload.chat_text, payload.plan_text, stream_snapshot, thinking_snapshot);
                wb.allocator.free(stream_snapshot);
                wb.allocator.free(thinking_snapshot);
                wb.chat_follow_stream = true;
            },
            .run_failed => |payload| {
                wb.agent.lock();
                wb.agent.worker_running = false;
                wb.agent.unlock();
                try wb.agent.setPhase(payload.phase, payload.message);
                try wb.appendChat(.agent, payload.message);
                try wb.setStatus(payload.message);
            },
            .propose_edit => |*payload| {
                wb.agent.lock();
                if (wb.agent.ephemeral_proposal) |*p| p.deinit();
                wb.agent.ephemeral_proposal = @import("forge-workspace").OwnedProposal{
                    .allocator = wb.allocator,
                    .files = @constCast(payload.files),
                    .metadata = .{},
                };
                wb.agent.unlock();

                wb.agent.review.buildFromProposal(
                    wb.allocator,
                    wb.io,
                    wb.workspace_root,
                    &wb.agent.ephemeral_proposal.?,
                ) catch {};

                openProposalReview(wb);
            },
        }
    }
    if (pending_context_refresh) refreshAgentContextPreview(wb);
}

fn flushLiveAssistantBeforeTool(wb: anytype) !void {
    wb.agent.lock();
    const stream_snapshot = wb.allocator.dupe(u8, wb.agent.stream_text.items) catch {
        wb.agent.unlock();
        return;
    };
    wb.agent.stream_text.clearRetainingCapacity();
    wb.agent.thinking_text.clearRetainingCapacity();
    wb.agent.unlock();
    defer wb.allocator.free(stream_snapshot);

    const agent_panel_mod = @import("../ui/agent/agent_panel.zig");
    if (!agent_panel_mod.chatHasVisibleContent(stream_snapshot)) return;
    try appendChat(wb, .agent, stream_snapshot);
}

pub fn appendChat(wb: anytype, role: ChatRole, content: []const u8) !void {
    const agent_panel_mod = @import("../ui/agent/agent_panel.zig");
    const normalized = if (role == .agent) try normalizeAgentChatContent(wb.allocator, content) else null;
    defer if (normalized) |text| wb.allocator.free(text);
    const source = normalized orelse content;
    if (!agent_panel_mod.chatHasVisibleContent(source)) return;
    const owned = try wb.allocator.dupeZ(u8, source);
    try wb.chat_history.append(wb.allocator, .{ .role = role, .content = owned });
    wb.chat_history_revision += 1;
    wb.chat_follow_stream = true;
    wb.chat_scroll_to_end_on_ready = true;
    wb.persistChatHistory() catch {};
}

fn appendToolChatStep(
    wb: anytype,
    index: u32,
    kind: []const u8,
    label: []const u8,
    content: ?[]const u8,
    running: bool,
) !void {
    const owned_label = try wb.allocator.dupeZ(u8, label);
    errdefer wb.allocator.free(owned_label);
    const owned_kind = try wb.allocator.dupeZ(u8, kind);
    errdefer wb.allocator.free(owned_kind);
    const owned_content = if (content) |text| try wb.allocator.dupeZ(u8, text) else null;
    errdefer if (owned_content) |text| wb.allocator.free(text);

    try wb.chat_history.append(wb.allocator, .{
        .role = .tool,
        .content = owned_label,
        .tool_index = index,
        .tool_kind = owned_kind,
        .tool_content = owned_content,
        .tool_running = running,
    });
    wb.chat_history_revision += 1;
    wb.chat_follow_stream = true;
    wb.chat_scroll_to_end_on_ready = true;
    wb.persistChatHistory() catch {};
}

fn finishToolChatStep(wb: anytype, index: u32, kind: []const u8, summary: []const u8) !void {
    const chat_persistence = @import("chat_persistence.zig");
    const compact_summary = try chat_persistence.compactToolSummaryAlloc(wb.allocator, summary);
    defer wb.allocator.free(compact_summary);

    var i = wb.chat_history.items.len;
    while (i > 0) : (i -= 1) {
        const msg = &wb.chat_history.items[i - 1];
        if (msg.role != .tool or msg.tool_index != index or !msg.tool_running) continue;
        if (msg.tool_kind) |existing_kind| {
            if (!std.mem.eql(u8, existing_kind, kind)) continue;
        }
        const owned_summary = try wb.allocator.dupeZ(u8, compact_summary);
        errdefer wb.allocator.free(owned_summary);
        const owned_kind = try wb.allocator.dupeZ(u8, kind);
        errdefer wb.allocator.free(owned_kind);

        wb.allocator.free(msg.content);
        if (msg.tool_kind) |old| wb.allocator.free(old);
        msg.content = owned_summary;
        msg.tool_kind = owned_kind;
        msg.tool_running = false;
        wb.chat_history_revision += 1;
        wb.chat_follow_stream = true;
        wb.chat_scroll_to_end_on_ready = true;
        wb.persistChatHistory() catch {};
        return;
    }

    try appendToolChatStep(wb, index, kind, compact_summary, null, false);
}

fn normalizeAgentChatContent(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "```")) return null;
    if (trimmed[0] != '{' and trimmed[0] != '[') return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (try chatWrapperJsonToContent(allocator, parsed.value)) |chat| return chat;
    if (try proposalJsonToChat(allocator, parsed.value)) |chat| return chat;
    const pretty = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(pretty);
    return try std.fmt.allocPrint(allocator, "```json\n{s}\n```", .{pretty});
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn appendJsonStringList(writer: *std.Io.Writer, title: []const u8, value: ?std.json.Value) !void {
    const array_value = value orelse return;
    if (array_value != .array or array_value.array.items.len == 0) return;
    try writer.print("\n\n{s}:\n", .{title});
    for (array_value.array.items) |item| {
        if (item == .string) {
            try writer.print("- {s}\n", .{item.string});
        }
    }
}

fn chatWrapperJsonToContent(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    if (value != .object) return null;
    const obj = value.object;
    const content_value = obj.get("content") orelse return null;
    if (content_value != .string) return null;
    return try allocator.dupe(u8, content_value.string);
}

fn proposalJsonToChat(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    if (value != .object) return null;
    const obj = value.object;
    if (obj.get("schema_version") == null and obj.get("workspace_edit") == null) return null;

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    if (jsonString(obj, "summary")) |summary| {
        try writer.print("{s}", .{summary});
    } else {
        try writer.writeAll("Agent returned a proposal result.");
    }

    try appendJsonStringList(writer, "Assumptions", obj.get("assumptions"));
    try appendJsonStringList(writer, "Validation", obj.get("validation_tasks"));

    var edit_count: usize = 0;
    if (obj.get("workspace_edit")) |workspace_edit| {
        if (workspace_edit == .object) {
            if (workspace_edit.object.get("files")) |files| {
                if (files == .array) edit_count = files.array.items.len;
            }
        }
    }

    if (edit_count == 0) {
        try writer.writeAll("\n\nNo code changes were proposed.");
    } else {
        try writer.print("\n\nProposed changes: {d} file(s).", .{edit_count});
    }

    return try out.toOwnedSlice();
}

fn appendAgentRunChat(
    wb: anytype,
    chat_text: []const u8,
    plan_text: ?[]const u8,
    stream_snapshot: []const u8,
    thinking_snapshot: []const u8,
) !void {
    const agent_panel_mod = @import("../ui/agent/agent_panel.zig");

    var appended_plan: ?[]const u8 = null;
    if (plan_text) |plan| {
        if (agent_panel_mod.chatHasVisibleContent(plan)) {
            try appendChat(wb, .agent, plan);
            appended_plan = plan;
        }
    }

    const final_text = if (agent_panel_mod.chatHasVisibleContent(chat_text) and
        !std.mem.eql(u8, std.mem.trim(u8, chat_text, &std.ascii.whitespace), "Agent finished"))
        chat_text
    else if (agent_panel_mod.chatHasVisibleContent(stream_snapshot))
        stream_snapshot
    else if (agent_panel_mod.chatHasVisibleContent(thinking_snapshot))
        thinking_snapshot
    else
        chat_text;

    if (agent_panel_mod.chatHasVisibleContent(final_text)) {
        if (appended_plan == null or !std.mem.eql(u8, appended_plan.?, final_text)) {
            try appendChat(wb, .agent, final_text);
        }
    }
}

test "normalizes agent chat wrapper markdown content" {
    const allocator = std.testing.allocator;
    const wrapped =
        \\{"role":"agent","content":"### Overview\n- item"}
    ;
    const normalized = (try normalizeAgentChatContent(allocator, wrapped)).?;
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("### Overview\n- item", normalized);
}

pub fn bridgeRefreshExplorer(context: ?*anyopaque) void {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    wb.explorer.rebuild(wb.io, wb.workspace_root) catch {};
}

pub fn bridgeOpenFile(context: ?*anyopaque, path: []const u8) void {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    wb.dispatch(.{ .open_file = path }) catch {};
}

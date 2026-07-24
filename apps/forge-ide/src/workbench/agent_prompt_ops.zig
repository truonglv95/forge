const std = @import("std");
const editor = @import("forge-editor");
const workspace = @import("forge-workspace");
const agent_workflow = @import("../agent/workflow.zig");
const agent_ops = @import("agent_ops.zig");
const mention_resolver_mod = @import("mention_resolver.zig");

pub fn submitAgentPrompt(wb: anytype) !void {
    const prompt_text = try wb.agent_ui.prompt_buffer.content();
    defer wb.agent_ui.prompt_buffer.allocator.free(prompt_text);
    const trimmed = std.mem.trim(u8, prompt_text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    var resolved = mention_resolver_mod.resolveMentions(
        wb.allocator,
        wb.io,
        wb.workspace_root,
        trimmed,
    ) catch mention_resolver_mod.ResolvedList{ .items = &.{} };
    defer resolved.deinit(wb.allocator);

    const preamble = mention_resolver_mod.buildContextPreamble(wb.allocator, resolved.items) catch try wb.allocator.dupe(u8, "");
    defer wb.allocator.free(preamble);

    const full_prompt = if (preamble.len > 0)
        std.fmt.allocPrint(wb.allocator, "{s}{s}", .{ preamble, trimmed }) catch try wb.allocator.dupe(u8, trimmed)
    else
        try wb.allocator.dupe(u8, trimmed);
    defer wb.allocator.free(full_prompt);

    const owned_prompt = try wb.allocator.dupe(u8, trimmed);
    defer wb.allocator.free(owned_prompt);

    wb.agent_ui.prompt_buffer.deinit();
    wb.agent_ui.prompt_buffer = try editor.Buffer.init(wb.allocator);
    wb.prompt_scroll_y = 0;
    wb.focused_panel = .agent;

    try agent_ops.appendChat(wb, .user, owned_prompt);
    wb.chat_follow_stream = true;
    const active = wb.editor.tabs.activeDoc();
    const active_path = if (active) |doc| doc.path else null;

    var scope_files: std.ArrayList([]const u8) = .empty;
    defer scope_files.deinit(wb.allocator);
    for (resolved.items) |m| {
        if (m.kind == .file and m.ok) {
            scope_files.append(wb.allocator, m.label) catch |err| {
                wb.logBackgroundError("Add mentioned file scope", err);
            };
        }
    }

    agent_workflow.spawnGenerate(&agent_ops.agentHost(wb), full_prompt, scope_files.items, active_path) catch |err| {
        const msg = switch (err) {
            error.AgentBusy => "Agent is already running",
            else => "Agent failed to start",
        };
        try wb.setStatus(msg);
        return;
    };
    wb.chat_scroll_to_end_on_ready = true;
    try wb.setStatus("Agent: building context...");
}

pub fn editSelectedCodeWithAgent(wb: anytype) !void {
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

    try agent_ops.appendChat(wb, .user, intent);
    wb.chat_follow_stream = true;

    const scope = try wb.allocator.alloc([]const u8, 1);
    defer wb.allocator.free(scope);
    scope[0] = try wb.allocator.dupe(u8, doc.path);
    defer wb.allocator.free(scope[0]);

    agent_workflow.spawnGenerate(&agent_ops.agentHost(wb), intent, scope, doc.path) catch |err| {
        const msg = switch (err) {
            error.AgentBusy => "Agent is already running",
            else => "Agent failed to start",
        };
        try wb.setStatus(msg);
        return;
    };
    try wb.setStatus("Agent: editing selection...");
}

pub fn openChatMessageAsMarkdown(wb: anytype, index: usize) !void {
    if (index >= wb.agent_ui.chat_history.items.len) {
        try wb.setStatus("Message not found");
        return;
    }

    const session_dir = workspace.global_store.getSessionDir(wb.allocator, wb.io, wb.workspace_root) catch {
        try wb.setStatus("Failed to open session storage");
        return;
    };
    defer wb.allocator.free(session_dir);

    const messages_dir = try std.fmt.allocPrint(wb.allocator, "{s}/messages", .{session_dir});
    defer wb.allocator.free(messages_dir);
    workspace.global_store.mkdirAllAbsolute(messages_dir) catch {
        try wb.setStatus("Failed to create message export folder");
        return;
    };

    const filename = try std.fmt.allocPrint(wb.allocator, "{s}/message-{d}.md", .{ messages_dir, index });
    defer wb.allocator.free(filename);

    var file = std.Io.Dir.createFileAbsolute(wb.io, filename, .{ .truncate = true }) catch {
        try wb.setStatus("Failed to write message markdown");
        return;
    };
    defer file.close(wb.io);
    file.writeStreamingAll(wb.io, wb.agent_ui.chat_history.items[index].content) catch {
        try wb.setStatus("Failed to write message markdown");
        return;
    };

    try wb.openFile(filename);
    try wb.setStatus("Opened message markdown");
}

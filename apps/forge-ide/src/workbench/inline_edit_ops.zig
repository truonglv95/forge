const agent_workflow = @import("../agent/workflow.zig");

pub fn open(wb: anytype) !void {
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

pub fn submit(wb: anytype) !void {
    if (!wb.editor.inline_edit.active) return;
    if (wb.editor.inline_edit.promptText().len == 0) {
        try wb.setStatus("Type an instruction first");
        return;
    }
    wb.editor.inline_edit.markPending();
    try wb.setStatus("Generating edit...");

    const intent = try wb.editor.inline_edit.buildAgentPrompt();
    defer wb.allocator.free(intent);
    const scope_files: []const []const u8 = &.{};
    const active_file = wb.editor.inline_edit.file_path;
    agent_workflow.spawnGenerate(&@import("../workbench/agent_ops.zig").agentHost(wb), intent, scope_files, active_file) catch |err| {
        wb.logBackgroundError("Start inline edit agent", err);
        wb.editor.inline_edit.close();
        try wb.setStatus("Inline edit failed");
    };
}

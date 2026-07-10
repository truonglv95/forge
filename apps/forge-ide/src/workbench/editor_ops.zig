const std = @import("std");
const editor = @import("forge-editor");
const lsp = @import("forge-lsp");
const references_store_mod = @import("references_store.zig");

pub fn lspSyncDocument(wb: anytype, doc: *editor.Document) ![]const u8 {
    return wb.lsp_sync.ensureSyncedBlocking(doc);
}

pub fn applyWorkspaceEdit(wb: anytype, edit: *const lsp.rename.WorkspaceEdit) !void {
    for (edit.files) |file_edit| {
        const rel = try lsp.navigation.uriToRelativePath(wb.allocator, wb.workspace_path, file_edit.uri);
        const path = rel orelse continue;
        defer wb.allocator.free(path);

        const doc = try wb.tabs.openOrActivate(path);
        var index = file_edit.edits.len;
        while (index > 0) {
            index -= 1;
            const text_edit = file_edit.edits[index];
            try doc.buffer.applyLspTextEdit(
                @intCast(text_edit.line),
                @intCast(text_edit.character),
                @intCast(text_edit.end_line),
                @intCast(text_edit.end_character),
                text_edit.new_text,
            );
        }
    }
}

pub fn wordAtCursor(buf: *editor.Buffer) []const u8 {
    const line = buf.lineAt(buf.cursor.row);
    if (line.len == 0) return "";
    var start = buf.cursor.col;
    if (start >= line.len) start = line.len - 1;
    while (start > 0 and isIdentByte(line[start - 1])) start -= 1;
    var end = start;
    while (end < line.len and isIdentByte(line[end])) end += 1;
    return line[start..end];
}

fn isIdentByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

pub fn scrollEditorToCursor(wb: anytype) void {
    const renderer_mod = @import("forge-renderer");
    var w: f32 = 0;
    var h: f32 = 0;
    renderer_mod.Renderer.getWindowSize(&w, &h);
    const geo = wb.layoutGeometry(w, h);
    const pane = wb.focusedPane();
    const doc = wb.docForPane(pane) orelse return;
    const pane_w = wb.paneWidth(geo.editor_w);
    const scroll_y: *f32 = if (pane == .secondary) &wb.split_scroll_y else &wb.editor_scroll_y;
    const scroll_x: *f32 = if (pane == .secondary) &wb.split_scroll_x else &wb.editor_scroll_x;
    if (wb.user_settings.word_wrap) {
        const word_wrap = @import("../ui/editor/word_wrap.zig");
        const viewport_w = @import("../ui/editor/editor_scroll.zig").viewportWidth(pane_w, &wb.theme);
        scroll_y.* = word_wrap.scrollToCursor(scroll_y.*, &doc.buffer, geo.editor_h, viewport_w, wb.theme.editor_font_size, &wb.theme);
        scroll_x.* = 0;
    } else {
        const scrolled = @import("../ui/editor/editor_scroll.zig").scrollToCursor(
            scroll_y.*,
            scroll_x.*,
            &doc.buffer,
            pane_w,
            geo.editor_h,
            &wb.theme,
        );
        scroll_y.* = scrolled.y;
        scroll_x.* = scrolled.x;
    }
}

pub fn openEditorFind(wb: anytype, replace_mode: bool) !void {
    wb.previous_focus = wb.focused_panel;
    wb.focused_panel = .find;
    wb.find_bar.openFind(replace_mode);
    if (wb.activeBuffer()) |buf| {
        try wb.find_bar.refreshMatches(buf);
        wb.scrollEditorToCursor();
    }
}

pub fn openGotoLine(wb: anytype) !void {
    wb.previous_focus = wb.focused_panel;
    wb.focused_panel = .goto_line;
    wb.goto_bar.open = true;
    try wb.goto_bar.input.loadFromSlice("");
}

pub fn closeEditorOverlay(wb: anytype) void {
    wb.find_bar.close();
    wb.goto_bar.open = false;
    wb.rename_bar.close();
    if (wb.focused_panel == .find or wb.focused_panel == .goto_line or wb.focused_panel == .rename) {
        wb.focused_panel = wb.previous_focus;
    }
    wb.completions.dismiss();
}

/// Notify the ghost completion store that the buffer changed.
/// Called after every character insertion in the editor. The store
/// debounces internally; this function is cheap to call on every keystroke.
pub fn notifyGhostBufferChanged(wb: anytype, row: usize, col: usize) void {
    wb.ghost.onBufferChanged(row, col);
}

/// Tick the ghost completion debounce timer and fire a request when ready.
/// `delta_s` is the frame elapsed time in seconds.
/// Should be called every frame from the render/update loop.
pub fn tickGhostCompletion(wb: anytype, delta_s: f32) void {
    if (!wb.ghost.config.enabled) return;
    const doc = wb.tabs.activeDoc() orelse return;

    // Sync cursor position — dismiss if moved.
    wb.ghost.onCursorMoved(doc.buffer.cursor.row, doc.buffer.cursor.col);

    if (!wb.ghost.tick(delta_s * 1000.0)) return;

    // Build prefix: content from the start of file up to cursor.
    const row = doc.buffer.cursor.row;
    const col = doc.buffer.cursor.col;

    var prefix_buf: std.ArrayList(u8) = .empty;
    defer prefix_buf.deinit(wb.allocator);
    const start_row = if (row > 200) row - 200 else 0;
    for (doc.buffer.lines.items[start_row..row]) |line| {
        prefix_buf.appendSlice(wb.allocator, line.items) catch return;
        prefix_buf.append(wb.allocator, '\n') catch return;
    }
    const current_line = doc.buffer.lines.items[row].items;
    const end_col = @min(col, current_line.len);
    prefix_buf.appendSlice(wb.allocator, current_line[0..end_col]) catch return;

    // Build suffix: content from cursor to end (truncated).
    var suffix_buf: std.ArrayList(u8) = .empty;
    defer suffix_buf.deinit(wb.allocator);
    for (doc.buffer.lines.items, 0..) |line, r| {
        if (r == row) {
            const start_col = @min(col, line.items.len);
            suffix_buf.appendSlice(wb.allocator, line.items[start_col..]) catch return;
            suffix_buf.append(wb.allocator, '\n') catch return;
        } else if (r > row) {
            suffix_buf.appendSlice(wb.allocator, line.items) catch return;
            suffix_buf.append(wb.allocator, '\n') catch return;
            if (suffix_buf.items.len >= @import("ghost_completion.zig").max_suffix_bytes) break;
        }
    }

    const line_content = doc.buffer.lineAt(row);
    wb.ghost.requestCompletion(
        line_content,
        prefix_buf.items,
        suffix_buf.items,
        row,
        col,
    );
}

pub fn openRenameSymbol(wb: anytype) !void {
    const buf = wb.activeBuffer() orelse return;
    const word = wordAtCursor(buf);
    if (word.len == 0) {
        try wb.setStatus("No symbol at cursor");
        return;
    }
    wb.previous_focus = wb.focused_panel;
    wb.focused_panel = .rename;
    try wb.rename_bar.openRename(word);
}

pub fn commitRenameSymbol(wb: anytype) !void {
    const name = wb.rename_bar.name();
    if (name.len == 0) return;
    try wb.previewRenameSymbol(name);
    wb.closeEditorOverlay();
}

pub fn previewRenameSymbol(wb: anytype, new_name: []const u8) !void {
    const doc = wb.tabs.activeDoc() orelse return;
    const owned = try wb.lsp_registry.copyMatchForPath(wb.allocator, doc.path);
    const config = owned orelse {
        try wb.setStatus("No language server for this file");
        return;
    };
    defer lsp.Registry.freeConfig(wb.allocator, config);

    const uri = try lspSyncDocument(wb, doc);
    defer wb.allocator.free(uri);

    const line: u32 = @intCast(doc.buffer.cursor.row);
    const character: u32 = @intCast(doc.buffer.cursor.col);
    const req = try lsp.rename.buildRenameRequest(wb.allocator, 93, uri, line, character, new_name);
    defer wb.allocator.free(req);

    var response_buf: [65536]u8 = undefined;
    const len = wb.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len) catch {
        try wb.setStatus("Rename failed");
        return;
    };

    const edit = try lsp.rename.parseRenameResponse(wb.allocator, response_buf[0..len]);
    if (edit) |workspace_edit| {
        try wb.rename_preview.setPreview(wb.workspace_path, &wb.tabs, new_name, workspace_edit);
        wb.references.clear();
        wb.bottom_panel_mode = .output;
        wb.task_scroll_y = 0;
        var status_buf: [96]u8 = undefined;
        const msg = try std.fmt.bufPrint(&status_buf, "Rename preview: {d} change(s)", .{wb.rename_preview.lines.len});
        try wb.setStatus(msg);
        return;
    }
    try wb.setStatus("Rename rejected by language server");
}

pub fn acceptRenamePreview(wb: anytype) !void {
    if (wb.rename_preview.edit) |*edit| {
        try applyWorkspaceEdit(wb, edit);
        wb.rename_preview.clear();
        try wb.setStatus("Rename applied");
        return;
    }
    try wb.setStatus("No rename preview");
}

pub fn rejectRenamePreview(wb: anytype) void {
    if (!wb.rename_preview.active) return;
    wb.rename_preview.clear();
    wb.setStatus("Rename cancelled") catch {};
}

pub fn gotoReference(wb: anytype, index: usize) !void {
    if (index >= wb.references.items.len) return;
    const item = wb.references.items[index];
    try wb.openFile(item.path);
    if (wb.activeBuffer()) |buf| {
        buf.goToLine(@intCast(item.line + 1));
        buf.cursor.col = @intCast(item.character);
        wb.scrollEditorToCursor();
    }
}

pub fn gotoLocation(wb: anytype, loc: lsp.navigation.Location) !void {
    const rel = try lsp.navigation.uriToRelativePath(wb.allocator, wb.workspace_path, loc.uri);
    if (rel) |path| {
        defer wb.allocator.free(path);
        try wb.openFile(path);
        if (wb.activeBuffer()) |buf| {
            buf.goToLine(@intCast(loc.line + 1));
            buf.cursor.col = @intCast(loc.character);
            wb.scrollEditorToCursor();
        }
        return;
    }
    try wb.setStatus("Location outside workspace");
}

pub fn findReferences(wb: anytype) !void {
    const doc = wb.tabs.activeDoc() orelse return;
    const owned = try wb.lsp_registry.copyMatchForPath(wb.allocator, doc.path);
    const config = owned orelse {
        try wb.setStatus("No language server for this file");
        return;
    };
    defer lsp.Registry.freeConfig(wb.allocator, config);

    const uri = try lspSyncDocument(wb, doc);
    defer wb.allocator.free(uri);

    const line: u32 = @intCast(doc.buffer.cursor.row);
    const character: u32 = @intCast(doc.buffer.cursor.col);
    const req = try lsp.references.buildReferencesRequest(wb.allocator, 92, uri, line, character);
    defer wb.allocator.free(req);

    var response_buf: [65536]u8 = undefined;
    const len = wb.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len) catch {
        try wb.setStatus("Find references failed");
        return;
    };

    var list = try lsp.references.parseReferencesResponse(wb.allocator, response_buf[0..len]);
    defer list.deinit(wb.allocator);

    var items: std.ArrayList(references_store_mod.Item) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(wb.allocator);
        items.deinit(wb.allocator);
    }

    for (list.items) |loc| {
        const rel = try lsp.navigation.uriToRelativePath(wb.allocator, wb.workspace_path, loc.uri);
        const path = rel orelse continue;
        const label = try std.fmt.allocPrint(wb.allocator, "{s}:{d}:{d}", .{
            path,
            loc.line + 1,
            loc.character + 1,
        });
        errdefer wb.allocator.free(label);
        try items.append(wb.allocator, .{
            .path = path,
            .line = loc.line,
            .character = loc.character,
            .label = label,
        });
    }

    wb.references.setItems(try items.toOwnedSlice(wb.allocator));
    wb.rename_preview.clear();
    wb.bottom_panel_mode = .output;
    wb.task_scroll_y = 0;
    var status_buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&status_buf, "{d} references", .{wb.references.items.len});
    try wb.setStatus(msg);
}

pub fn renameSymbol(wb: anytype, new_name: []const u8) !void {
    try wb.previewRenameSymbol(new_name);
    if (wb.rename_preview.active) try wb.acceptRenamePreview();
}

pub fn formatDocument(wb: anytype) !void {
    const doc = wb.tabs.activeDoc() orelse {
        try wb.setStatus("No file open to format");
        return;
    };
    _ = try wb.lsp_sync.ensureSyncedBlocking(doc);

    const uri = try lsp.diagnostics.fileUri(wb.allocator, wb.workspace_path, doc.path);
    defer wb.allocator.free(uri);

    const req = try lsp.format.buildFormatRequest(wb.allocator, 94, uri, 4);
    defer wb.allocator.free(req);

    const owned = try wb.lsp_registry.copyMatchForPath(wb.allocator, doc.path);
    const config = owned orelse {
        try wb.setStatus("No language server for format");
        return;
    };
    defer lsp.Registry.freeConfig(wb.allocator, config);

    var response_buf: [256 * 1024]u8 = undefined;
    const len = wb.lsp_proxy.request(config.language_id, req, &response_buf, response_buf.len) catch |err| {
        try wb.setStatus(@errorName(err));
        return;
    };

    const edits = try lsp.format.parseFormatResponse(wb.allocator, response_buf[0..len]);
    defer {
        for (edits) |*edit| edit.deinit(wb.allocator);
        wb.allocator.free(edits);
    }
    if (edits.len == 0) {
        try wb.setStatus("Nothing to format");
        return;
    }

    var index = edits.len;
    while (index > 0) {
        index -= 1;
        const text_edit = edits[index];
        try doc.buffer.applyLspTextEdit(
            @intCast(text_edit.line),
            @intCast(text_edit.character),
            @intCast(text_edit.end_line),
            @intCast(text_edit.end_character),
            text_edit.new_text,
        );
    }
    try wb.setStatus("Document formatted");
}

pub fn findNextMatch(wb: anytype) !void {
    const buf = wb.activeBuffer() orelse return;
    if (wb.find_bar.matches.len == 0) try wb.find_bar.refreshMatches(buf);
    wb.find_bar.nextMatch(buf);
    wb.scrollEditorToCursor();
}

pub fn findPrevMatch(wb: anytype) !void {
    const buf = wb.activeBuffer() orelse return;
    if (wb.find_bar.matches.len == 0) try wb.find_bar.refreshMatches(buf);
    wb.find_bar.prevMatch(buf);
    wb.scrollEditorToCursor();
}

pub fn commitGotoLine(wb: anytype) !void {
    const line = wb.goto_bar.parseLine() orelse return;
    if (wb.activeBuffer()) |buf| {
        buf.goToLine(line);
        wb.scrollEditorToCursor();
    }
    wb.closeEditorOverlay();
}

pub fn gotoProblem(wb: anytype, index: usize) !void {
    if (index >= wb.diagnostics.list.items.len) return;
    const diag = wb.diagnostics.list.items[index];
    if (wb.activeBuffer()) |buf| {
        buf.cursor.row = @intCast(@min(diag.line, buf.lineCount() - 1));
        const line_len = buf.lineAt(buf.cursor.row).len;
        buf.cursor.col = @intCast(@min(diag.character, line_len));
        wb.scrollEditorToCursor();
        wb.focused_panel = .editor;
    }
}

const std = @import("std");
const ai = @import("forge-ai");
const lsp = @import("forge-lsp");
const Workbench = @import("../workbench.zig").Workbench;

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

    const doc = wb.editor.tabs.activeDoc();
    if (doc) |active| {
        cursor_owned = try allocator.dupe(u8, active.path);
        const line: u32 = @intCast(active.buffer.cursor.row);
        const character: u32 = @intCast(active.buffer.cursor.col);
        cursor_pos = .{
            .path = cursor_owned.?,
            .line = line,
            .character = character,
        };

        for (wb.lsp.diagnostics.list.items) |diag| {
            try diagnostics.append(allocator, .{
                .path = try allocator.dupe(u8, active.path),
                .line = diag.line,
                .character = diag.character,
                .severity = try allocator.dupe(u8, diagnosticSeverityLabel(diag.severity)),
                .message = try allocator.dupe(u8, diag.message),
            });
        }

        const owned = wb.lsp.registry.copyMatchForPath(allocator, active.path) catch null;
        if (owned) |config| {
            defer lsp.Registry.freeConfig(allocator, config);

            if (@import("editor_ops.zig").lspSyncDocument(wb, active)) |uri| {
                defer allocator.free(uri);

                const hover_req = lsp.hover.buildHoverRequest(allocator, 93, uri, line, character) catch null;
                if (hover_req) |hover_req_body| {
                    defer allocator.free(hover_req_body);
                    var hover_buf: [65536]u8 = undefined;
                    if (wb.lsp.proxy.request(config.language_id, hover_req_body, &hover_buf, hover_buf.len) catch null) |hover_len| {
                        hover_owned = lsp.hover.parseHoverResponse(allocator, hover_buf[0..hover_len]) catch null;
                    }
                }

                const def_req = lsp.navigation.buildDefinitionRequest(allocator, 91, uri, line, character) catch null;
                if (def_req) |req| {
                    defer allocator.free(req);
                    var response_buf: [65536]u8 = undefined;
                    if (wb.lsp.proxy.request(config.language_id, req, &response_buf, response_buf.len)) |len| {
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
                    if (wb.lsp.proxy.request(config.language_id, req, &response_buf, response_buf.len)) |len| {
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
    const doc = wb.editor.tabs.activeDoc() orelse return null;
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

pub fn snapshotEditorContext(wb: anytype, allocator: std.mem.Allocator) !?[]const u8 {
    const doc = wb.editor.tabs.activeDoc() orelse return null;

    var open_tabs_arr: std.ArrayList([]const u8) = .empty;
    defer open_tabs_arr.deinit(allocator);
    for (wb.editor.tabs.tabs.items) |tab| {
        try open_tabs_arr.append(allocator, tab.path);
    }

    var selection_str: ?[]const u8 = null;
    if (doc.buffer.hasSelection()) {
        selection_str = try doc.buffer.selectedText(allocator);
    }
    defer if (selection_str) |s| allocator.free(s);

    const Ctx = struct {
        active_tab: []const u8,
        cursor_row: usize,
        cursor_col: usize,
        selection: ?[]const u8,
        open_tabs: [][]const u8,
    };

    const ctx = Ctx{
        .active_tab = doc.path,
        .cursor_row = doc.buffer.cursor.row,
        .cursor_col = doc.buffer.cursor.col,
        .selection = selection_str,
        .open_tabs = open_tabs_arr.items,
    };
    return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(ctx, .{})});
}

pub fn bridgeSnapshotEditorContext(context: ?*anyopaque, allocator: std.mem.Allocator) ?[]const u8 {
    const wb: *Workbench = @ptrCast(@alignCast(context.?));
    return snapshotEditorContext(wb, allocator) catch null;
}

pub fn snapshotRecentTabPaths(wb: anytype, allocator: std.mem.Allocator) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    if (wb.editor.tabs.tabs.items.len == 0) return try paths.toOwnedSlice(allocator);

    if (wb.editor.tabs.active < wb.editor.tabs.tabs.items.len) {
        try paths.append(allocator, try allocator.dupe(u8, wb.editor.tabs.tabs.items[wb.editor.tabs.active].path));
    }

    var index = wb.editor.tabs.tabs.items.len;
    while (index > 0) {
        index -= 1;
        if (index == wb.editor.tabs.active) continue;
        const path = wb.editor.tabs.tabs.items[index].path;
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

pub fn bridgeLspRequest(context: ?*anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ?[]const u8 {
    const wb = @as(*Workbench, @ptrCast(@alignCast(context.?)));

    var language_id: ?[]const u8 = null;
    wb.lsp.registry.mutex.lock();
    if (wb.lsp.registry.servers.items.len > 0) {
        language_id = wb.allocator.dupe(u8, wb.lsp.registry.servers.items[0].language_id) catch null;
    }
    wb.lsp.registry.mutex.unlock();

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
    const len = wb.lsp.proxy.request(lang, req_json, &response_buf, response_buf.len) catch return null;

    return allocator.dupe(u8, response_buf[0..len]) catch null;
}

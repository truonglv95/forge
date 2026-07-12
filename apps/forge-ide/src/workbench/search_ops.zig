const std = @import("std");
const search_engine = @import("../search/engine.zig");
const workspace = @import("forge-workspace");
const background_jobs = @import("background_jobs.zig");
const renderer = @import("forge-renderer");

pub fn runSearch(wb: anytype) !void {
    const query = try wb.search_buffer.content();
    var query_owned = true;
    errdefer if (query_owned) wb.search_buffer.allocator.free(query);

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        wb.search_buffer.allocator.free(query);
        query_owned = false;
        if (wb.search_results) |*results| results.deinit(wb.allocator);
        wb.search_results = null;
        wb.search_scroll_y = 0;
        try wb.setStatus("Search cleared");
        return;
    }

    wb.search_mutex.lock();
    if (wb.search_running) {
        wb.search_mutex.unlock();
        wb.search_buffer.allocator.free(query);
        query_owned = false;
        try wb.setStatus("Search already running");
        return;
    }
    wb.search_running = true;
    wb.search_ready = false;
    wb.search_failed = false;
    if (wb.search_pending_results) |*results| results.deinit(wb.allocator);
    wb.search_pending_results = null;
    wb.search_mutex.unlock();
    errdefer if (query_owned) {
        wb.search_mutex.lock();
        wb.search_running = false;
        wb.search_failed = true;
        wb.search_mutex.unlock();
    };

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| wb.allocator.free(path);
        paths.deinit(wb.allocator);
    }
    for (wb.explorer.entries) |entry| {
        if (entry.kind != .file) continue;
        try paths.append(wb.allocator, try wb.allocator.dupe(u8, entry.path));
    }

    const ctx = SearchCtx{
        .wb = wb,
        .query = query,
        .paths = try paths.toOwnedSlice(wb.allocator),
    };
    background_jobs.spawnDetached("workspace-search", SearchCtx, wb.allocator, ctx, searchWorker) catch |err| {
        freePathSnapshot(wb.allocator, ctx.paths);
        wb.search_mutex.lock();
        wb.search_running = false;
        wb.search_failed = true;
        wb.search_mutex.unlock();
        return err;
    };
    query_owned = false;
    wb.setStatus("Search running...") catch {};
}

const SearchCtx = struct {
    wb: *@import("../workbench.zig").Workbench,
    query: []const u8,
    paths: []const []const u8,
};

fn freePathSnapshot(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn searchWorker(ctx: *SearchCtx) void {
    const wb = ctx.wb;
    defer {
        wb.allocator.free(ctx.query);
        freePathSnapshot(wb.allocator, ctx.paths);
        wb.allocator.destroy(ctx);
    }

    var root = workspace.WorkspaceRoot.open(wb.io, wb.workspace_path) catch {
        markSearchFailed(wb);
        return;
    };
    defer root.close(wb.io);

    const result = search_engine.searchWorkspacePaths(wb.allocator, wb.io, root, ctx.paths, ctx.query) catch {
        markSearchFailed(wb);
        return;
    };

    wb.search_mutex.lock();
    if (wb.search_pending_results) |*old| old.deinit(wb.allocator);
    wb.search_pending_results = result;
    wb.search_ready = true;
    wb.search_failed = false;
    wb.search_running = false;
    wb.search_mutex.unlock();
    renderer.Renderer.requestRedraw();
}

fn markSearchFailed(wb: *@import("../workbench.zig").Workbench) void {
    wb.search_mutex.lock();
    wb.search_failed = true;
    wb.search_running = false;
    wb.search_mutex.unlock();
    renderer.Renderer.requestRedraw();
}

pub fn flushSearchResults(wb: *@import("../workbench.zig").Workbench) !bool {
    wb.search_mutex.lock();
    const ready = wb.search_ready;
    const failed = wb.search_failed;
    const pending = if (ready) wb.search_pending_results else null;
    if (ready) {
        wb.search_pending_results = null;
        wb.search_ready = false;
    }
    wb.search_failed = false;
    wb.search_mutex.unlock();

    if (pending) |results| {
        if (wb.search_results) |*old| old.deinit(wb.allocator);
        wb.search_results = results;
        wb.search_scroll_y = 0;
        var buf: [96]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Search: {d} result(s)", .{results.matches.len});
        try wb.setStatus(msg);
        return true;
    }

    if (failed) {
        try wb.setStatus("Search failed");
    }
    return false;
}

pub fn handleSearchClick(wb: anytype, hit: @import("../ui/sidebar/search_panel.zig").Hit) !void {
    switch (hit) {
        .run_search => try wb.dispatch(.search_run),
        .open_result => |index| {
            const results = wb.search_results orelse return;
            if (index >= results.matches.len) return;
            const match = results.matches[index];
            const path = try wb.allocator.dupe(u8, match.path);
            defer wb.allocator.free(path);
            try wb.dispatch(.{ .open_file = path });
            if (match.line) |line| {
                if (wb.activeBuffer()) |buf| {
                    if (line < buf.lineCount()) {
                        buf.cursor.row = line;
                        buf.cursor.col = 0;
                    }
                }
            }
        },
    }
}

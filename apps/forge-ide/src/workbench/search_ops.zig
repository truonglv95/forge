const std = @import("std");
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
        if (wb.search.results) |*results| results.deinit(wb.allocator);
        wb.search.results = null;
        wb.search.scroll_y = 0;
        try wb.setStatus("Search cleared");
        return;
    }

    wb.search.mutex.lock();
    if (wb.search.running) {
        wb.search.mutex.unlock();
        wb.search_buffer.allocator.free(query);
        query_owned = false;
        try wb.setStatus("Search already running");
        return;
    }
    wb.search.running = true;
    wb.search.ready = false;
    wb.search.failed = false;
    if (wb.search.pending_results) |*results| results.deinit(wb.allocator);
    wb.search.pending_results = null;
    wb.search.mutex.unlock();
    errdefer if (query_owned) {
        wb.search.mutex.lock();
        wb.search.running = false;
        wb.search.failed = true;
        wb.search.mutex.unlock();
    };

    const ctx = try wb.allocator.create(SearchCtx);
    ctx.* = .{
        .wb = wb,
        .query = query,
    };
    background_jobs.spawnDetached("workspace-search", SearchCtx, wb.allocator, ctx, searchWorker) catch |err| {
        wb.allocator.free(ctx.query);
        wb.allocator.destroy(ctx);
        wb.search.mutex.lock();
        wb.search.running = false;
        wb.search.failed = true;
        wb.search.mutex.unlock();
        return err;
    };
    query_owned = false;
    wb.setStatus("Search running...") catch {};
}

const SearchCtx = struct {
    wb: *@import("../workbench.zig").Workbench,
    query: []const u8,
};

fn searchWorker(ctx: *SearchCtx) void {
    const wb = ctx.wb;
    defer {
        wb.allocator.free(ctx.query);
        wb.allocator.destroy(ctx);
    }

    var root = workspace.WorkspaceRoot.open(wb.io, wb.workspace_path) catch {
        markSearchFailed(wb);
        return;
    };
    defer root.close(wb.io);

    const result = workspace.search.grepContent(wb.allocator, wb.io, root, .{
        .pattern = ctx.query,
        .path = ".",
        .case_sensitive = false,
    }) catch {
        markSearchFailed(wb);
        return;
    };

    wb.search.mutex.lock();
    if (wb.search.pending_results) |*old| old.deinit(wb.allocator);
    wb.search.pending_results = result;
    wb.search.ready = true;
    wb.search.failed = false;
    wb.search.running = false;
    wb.search.mutex.unlock();
    renderer.Renderer.requestRedraw();
}

fn markSearchFailed(wb: *@import("../workbench.zig").Workbench) void {
    wb.search.mutex.lock();
    wb.search.failed = true;
    wb.search.running = false;
    wb.search.mutex.unlock();
    renderer.Renderer.requestRedraw();
}

pub fn flushSearchResults(wb: *@import("../workbench.zig").Workbench) !bool {
    wb.search.mutex.lock();
    const ready = wb.search.ready;
    const failed = wb.search.failed;
    const pending = if (ready) wb.search.pending_results else null;
    if (ready) {
        wb.search.pending_results = null;
        wb.search.ready = false;
    }
    wb.search.failed = false;
    wb.search.mutex.unlock();

    if (pending) |results| {
        if (wb.search.results) |*old| old.deinit(wb.allocator);
        wb.search.results = results;
        wb.search.scroll_y = 0;
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
            const results = wb.search.results orelse return;
            if (index >= results.matches.len) return;
            const match = results.matches[index];
            const path = try wb.allocator.dupe(u8, match.path);
            defer wb.allocator.free(path);
            try wb.dispatch(.{ .open_file = path });
            const line = if (match.line > 0) match.line - 1 else 0;
            if (wb.activeBuffer()) |buf| {
                if (line < buf.lineCount()) {
                    buf.cursor.row = line;
                    buf.cursor.col = 0;
                }
            }
        },
    }
}

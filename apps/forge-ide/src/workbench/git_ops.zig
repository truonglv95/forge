const std = @import("std");
const git_status_mod = @import("../git/status.zig");
const git_diff_mod = @import("../git/diff.zig");
const background_jobs = @import("background_jobs.zig");
const renderer = @import("forge-renderer");

pub fn refreshGitStatus(wb: anytype) !void {
    const new_status = try git_status_mod.refresh(wb.allocator, wb.workspace_path);
    replaceGitStatus(wb, new_status, true) catch |err| {
        var owned = new_status;
        owned.deinit(wb.allocator);
        return err;
    };
}

fn replaceGitStatus(wb: anytype, new_status: git_status_mod.Status, reset_scroll: bool) !void {
    if (wb.git_status) |*status| status.deinit(wb.allocator);
    wb.git_status = new_status;
    if (reset_scroll) wb.git_scroll_y = 0;
    if (wb.git_status.?.is_repo) {
        var buf: [96]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Git: {d} change(s)", .{wb.git_status.?.entries.len});
        try wb.setStatus(msg);
    } else {
        try wb.setStatus("Not a git repository");
    }
}

const RefreshCtx = struct {
    wb: *@import("../workbench.zig").Workbench,
};

pub fn scheduleGitStatusRefresh(wb: *@import("../workbench.zig").Workbench) void {
    wb.git_refresh_mutex.lock();
    if (wb.git_refresh_running) {
        wb.git_refresh_mutex.unlock();
        return;
    }
    wb.git_refresh_running = true;
    wb.git_refresh_failed = false;
    wb.git_refresh_mutex.unlock();

    background_jobs.spawnDetached("git-refresh", RefreshCtx, wb.allocator, .{ .wb = wb }, gitRefreshWorker) catch {
        wb.git_refresh_mutex.lock();
        wb.git_refresh_running = false;
        wb.git_refresh_mutex.unlock();
        return;
    };
}

fn gitRefreshWorker(ctx: *RefreshCtx) void {
    const wb = ctx.wb;
    defer wb.allocator.destroy(ctx);

    const result = git_status_mod.refresh(wb.allocator, wb.workspace_path);

    wb.git_refresh_mutex.lock();
    defer wb.git_refresh_mutex.unlock();

    if (result) |status| {
        if (wb.git_refresh_pending_status) |*old| old.deinit(wb.allocator);
        wb.git_refresh_pending_status = status;
        wb.git_refresh_ready = true;
        wb.git_refresh_failed = false;
    } else |_| {
        wb.git_refresh_failed = true;
    }
    wb.git_refresh_running = false;
    renderer.Renderer.requestRedraw();
}

pub fn flushGitStatusRefresh(wb: *@import("../workbench.zig").Workbench) !bool {
    wb.git_refresh_mutex.lock();
    const ready = wb.git_refresh_ready;
    const failed = wb.git_refresh_failed;
    const pending = if (ready) wb.git_refresh_pending_status else null;
    if (ready) {
        wb.git_refresh_pending_status = null;
        wb.git_refresh_ready = false;
    }
    wb.git_refresh_failed = false;
    wb.git_refresh_mutex.unlock();

    if (pending) |status| {
        replaceGitStatus(wb, status, false) catch |err| {
            var owned = status;
            owned.deinit(wb.allocator);
            return err;
        };
        return true;
    }

    if (failed) {
        try wb.setStatus("Git refresh failed");
    }
    return false;
}

pub fn handleGitClick(wb: anytype, hit: @import("../ui/sidebar/git_panel.zig").Hit) !void {
    switch (hit) {
        .refresh => try wb.dispatch(.git_refresh),
        .commit => try wb.commitStagedChanges(),
        .ai_generate => try wb.setStatus("AI Commit Generation not yet implemented"),
        .view_as_tree => try wb.setStatus("View as tree not yet implemented"),
        .more_actions => try wb.setStatus("More actions not yet implemented"),
        .focus_commit_msg => {
            // Focus is already set to .git by input.zig
        },
        .toggle_staged_section => wb.git_staged_collapsed = !wb.git_staged_collapsed,
        .toggle_changes_section => wb.git_changes_collapsed = !wb.git_changes_collapsed,
        .toggle_file_staged => |index| {
            const status = wb.git_status orelse return;
            if (index >= status.entries.len) return;
            const entry = status.entries[index];
            const process_spawn = @import("forge-util").process_spawn;
            if (entry.isStaged() and !entry.isUnstaged()) {
                // It is ONLY staged. Unstage it.
                _ = process_spawn.runWait(wb.allocator, &.{ "git", "restore", "--staged", entry.path }, .{ .cwd = wb.workspace_path }) catch {};
            } else if (entry.isUnstaged()) {
                // It is unstaged. Stage it.
                _ = process_spawn.runWait(wb.allocator, &.{ "git", "add", entry.path }, .{ .cwd = wb.workspace_path }) catch {};
            }
            try refreshGitStatus(wb);
        },
        .open_file => |index| {
            const status = wb.git_status orelse return;
            if (index >= status.entries.len) return;
            const entry = status.entries[index];
            const path = try wb.allocator.dupe(u8, entry.path);
            defer wb.allocator.free(path);
            const untracked = entry.status[0] == '?' or entry.status[1] == '?';
            try wb.showGitDiff(path, untracked);
            const open_path = try wb.allocator.dupe(u8, path);
            try wb.dispatch(.{ .open_file = open_path });
        },
    }
}

pub fn commitStagedChanges(wb: anytype) !void {
    const msg = try wb.git_commit_msg.content();
    defer wb.allocator.free(msg);

    if (msg.len == 0) {
        try wb.setStatus("Commit message cannot be empty");
        return;
    }

    const process_spawn = @import("forge-util").process_spawn;
    const exit_code = process_spawn.runWait(wb.allocator, &.{ "git", "commit", "-m", msg }, .{ .cwd = wb.workspace_path }) catch -1;

    if (exit_code == 0) {
        wb.git_commit_msg.clear();
        try refreshGitStatus(wb);
        try wb.setStatus("Commit successful");
    } else {
        try wb.setStatus("Commit failed (are there staged changes?)");
    }
}

pub fn showGitDiff(wb: anytype, path: []const u8, untracked: bool) !void {
    const diff = try git_diff_mod.fileDiff(wb.allocator, wb.workspace_path, path, untracked);
    defer wb.allocator.free(diff);
    wb.task_output.clear();
    try wb.task_output.appendChunk(diff);
    wb.bottom_panel_mode = .output;
    wb.task_scroll_y = 0;
    try wb.setStatus("Git diff");
}

const std = @import("std");
const git_status_mod = @import("../git/status.zig");
const git_diff_mod = @import("../git/diff.zig");
const background_jobs = @import("background_jobs.zig");
const renderer = @import("forge-renderer");

pub fn refreshGitStatus(wb: anytype) !void {
    scheduleGitStatusRefresh(wb);
    try wb.setStatus("Git refresh running...");
}

fn replaceGitStatus(wb: anytype, new_status: git_status_mod.Status, reset_scroll: bool) !void {
    if (wb.git.status) |*status| status.deinit(wb.allocator);
    wb.git.status = new_status;
    if (reset_scroll) wb.git.scroll_y = 0;
    if (wb.git.status.?.is_repo) {
        var buf: [96]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Git: {d} change(s)", .{wb.git.status.?.entries.len});
        try wb.setStatus(msg);
    } else {
        try wb.setStatus("Not a git repository");
    }
}

const RefreshCtx = struct {
    wb: *@import("../workbench.zig").Workbench,
};

pub fn scheduleGitStatusRefresh(wb: *@import("../workbench.zig").Workbench) void {
    wb.git.refresh_mutex.lock();
    if (wb.git.refresh_running) {
        wb.git.refresh_mutex.unlock();
        return;
    }
    wb.git.refresh_running = true;
    wb.git.refresh_failed = false;
    wb.git.refresh_mutex.unlock();

    background_jobs.spawnDetached("git-refresh", RefreshCtx, wb.allocator, .{ .wb = wb }, gitRefreshWorker) catch {
        wb.git.refresh_mutex.lock();
        wb.git.refresh_running = false;
        wb.git.refresh_mutex.unlock();
        return;
    };
}

fn gitRefreshWorker(ctx: *RefreshCtx) void {
    const wb = ctx.wb;
    defer wb.allocator.destroy(ctx);

    const result = git_status_mod.refresh(wb.allocator, wb.workspace_path);

    wb.git.refresh_mutex.lock();
    defer wb.git.refresh_mutex.unlock();

    if (result) |status| {
        if (wb.git.refresh_pending_status) |*old| old.deinit(wb.allocator);
        wb.git.refresh_pending_status = status;
        wb.git.refresh_ready = true;
        wb.git.refresh_failed = false;
    } else |_| {
        wb.git.refresh_failed = true;
    }
    wb.git.refresh_running = false;
    renderer.Renderer.requestRedraw();
}

const SyncCtx = struct {
    wb: *@import("../workbench.zig").Workbench,
};

pub fn scheduleGitPull(wb: *@import("../workbench.zig").Workbench) void {
    if (wb.git.pull_running or wb.git.push_running) return;
    wb.git.pull_running = true;
    wb.git.pull_done = false;
    wb.setStatus("Git pull running...") catch {};
    background_jobs.spawnDetached("git-pull", SyncCtx, wb.allocator, .{ .wb = wb }, gitPullWorker) catch {
        wb.git.pull_running = false;
        wb.setStatus("Git pull failed to start") catch {};
        return;
    };
}

fn gitPullWorker(ctx: *SyncCtx) void {
    const wb = ctx.wb;
    defer wb.allocator.destroy(ctx);
    defer wb.git.pull_done = true;

    _ = runGitWithOutput(wb, &.{ "git", "pull" }, "git pull", true) catch -1;
}

pub fn scheduleGitPush(wb: *@import("../workbench.zig").Workbench) void {
    if (wb.git.push_running or wb.git.pull_running) return;
    wb.git.push_running = true;
    wb.git.push_done = false;
    wb.setStatus("Git push running...") catch {};
    background_jobs.spawnDetached("git-push", SyncCtx, wb.allocator, .{ .wb = wb }, gitPushWorker) catch {
        wb.git.push_running = false;
        wb.setStatus("Git push failed to start") catch {};
        return;
    };
}

fn gitPushWorker(ctx: *SyncCtx) void {
    const wb = ctx.wb;
    defer wb.allocator.destroy(ctx);
    defer wb.git.push_done = true;

    _ = runGitWithOutput(wb, &.{ "git", "push" }, "git push", true) catch -1;
}

pub fn runGitWithOutput(wb: *@import("../workbench.zig").Workbench, args: []const []const u8, log_title: []const u8, open_panel_on_error: bool) !i32 {
    const process_spawn = @import("forge-util").process_spawn;
    const result = process_spawn.runCapture(wb.allocator, args, .{ .cwd = wb.workspace_path }) catch return -1;
    defer wb.allocator.free(result.output);

    var title_buf: [256]u8 = undefined;
    const title_str = std.fmt.bufPrint(&title_buf, "[info] > {s}\n", .{log_title}) catch "> git command\n";
    if (wb.getOrCreateOutputChannel("git", "Git") catch null) |git_chan| {
        git_chan.output.appendChunk(title_str) catch {};
        if (result.output.len > 0) {
            git_chan.output.appendChunk(result.output) catch {};
        }
    }

    if (result.exit_code == 0) {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} completed", .{log_title}) catch "git command completed";
        wb.setStatus(msg) catch {};
    } else {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s} failed", .{log_title}) catch "git command failed";
        wb.setStatus(msg) catch {};
        if (open_panel_on_error) {
            wb.bottom_panel_visible = true;
            wb.bottom_panel_mode = .output;
            wb.active_output_channel_id = "git";
        }
    }
    return result.exit_code;
}

pub fn flushGitStatusRefresh(wb: *@import("../workbench.zig").Workbench) !bool {
    wb.git.refresh_mutex.lock();
    const ready = wb.git.refresh_ready;
    const failed = wb.git.refresh_failed;
    const pending = if (ready) wb.git.refresh_pending_status else null;
    if (ready) {
        wb.git.refresh_pending_status = null;
        wb.git.refresh_ready = false;
    }
    wb.git.refresh_failed = false;
    wb.git.refresh_mutex.unlock();

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
        .push => try wb.dispatch(.git_push),
        .pull => try wb.dispatch(.git_pull),
        .switch_branch => {
            try wb.setStatus("Switch branch not yet implemented via Palette");
            // TODO: dispatch a palette command for branch switching
        },
        .commit => try wb.commitStagedChanges(),
        .ai_generate => try wb.setStatus("AI Commit Generation not yet implemented"),
        .view_as_tree => try wb.setStatus("View as tree not yet implemented"),
        .more_actions => try wb.setStatus("More actions not yet implemented"),
        .focus_commit_msg => {
            // Focus is already set to .git by input.zig
        },
        .toggle_staged_section => wb.git.staged_collapsed = !wb.git.staged_collapsed,
        .toggle_changes_section => wb.git.changes_collapsed = !wb.git.changes_collapsed,
        .toggle_file_staged => |index| {
            const status = wb.git.status orelse return;
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
        .discard_file_changes => |index| {
            const status = wb.git.status orelse return;
            if (index >= status.entries.len) return;
            const entry = status.entries[index];
            const process_spawn = @import("forge-util").process_spawn;
            if (entry.isUnstaged()) {
                if (entry.status[1] == '?') {
                    // Untracked file
                    // We probably should delete the file? Or maybe let user handle it manually, but 'git clean' works.
                    // For now, let's use standard git checkout if tracked, or rm if untracked.
                    _ = process_spawn.runWait(wb.allocator, &.{ "rm", entry.path }, .{ .cwd = wb.workspace_path }) catch {};
                } else {
                    _ = process_spawn.runWait(wb.allocator, &.{ "git", "checkout", "--", entry.path }, .{ .cwd = wb.workspace_path }) catch {};
                }
            }
            try refreshGitStatus(wb);
        },
        .open_file => |info| {
            const status = wb.git.status orelse return;
            if (info.index >= status.entries.len) return;
            const entry = status.entries[info.index];
            const path = try wb.allocator.dupe(u8, entry.path);
            defer wb.allocator.free(path);
            const untracked = entry.status[0] == '?' or entry.status[1] == '?';
            try wb.showGitDiff(path, untracked, info.is_staged);
        },
        .stage_all => {
            const process_spawn = @import("forge-util").process_spawn;
            _ = process_spawn.runWait(wb.allocator, &.{ "git", "add", "-A" }, .{ .cwd = wb.workspace_path }) catch {};
            try refreshGitStatus(wb);
        },
        .unstage_all => {
            const process_spawn = @import("forge-util").process_spawn;
            _ = process_spawn.runWait(wb.allocator, &.{ "git", "reset" }, .{ .cwd = wb.workspace_path }) catch {};
            try refreshGitStatus(wb);
        },
        .discard_all => {
            const process_spawn = @import("forge-util").process_spawn;
            _ = process_spawn.runWait(wb.allocator, &.{ "git", "checkout", "--", "." }, .{ .cwd = wb.workspace_path }) catch {};
            _ = process_spawn.runWait(wb.allocator, &.{ "git", "clean", "-fd" }, .{ .cwd = wb.workspace_path }) catch {};
            try refreshGitStatus(wb);
        },
    }
}

pub fn commitStagedChanges(wb: anytype) !void {
    const msg = try wb.git.commit_msg.content();
    defer wb.allocator.free(msg);

    if (msg.len == 0) {
        try wb.setStatus("Commit message cannot be empty");
        return;
    }

    const exit_code = try runGitWithOutput(wb, &.{ "git", "commit", "-m", msg }, "git commit", true);

    if (exit_code == 0) {
        wb.git.commit_msg.clear();
        try refreshGitStatus(wb);
    }
}

pub fn showGitDiff(wb: anytype, path: []const u8, untracked: bool, is_staged: bool) !void {
    const diff = try git_diff_mod.fileDiff(wb.allocator, wb.workspace_path, path, untracked, is_staged);
    defer wb.allocator.free(diff);

    // Create a virtual path for the diff tab
    var buf: [1024]u8 = undefined;
    const diff_path = try std.fmt.bufPrint(&buf, "git-diff://{s}", .{path});

    // Open or activate the tab
    const doc = try wb.tabs.openOrActivate(diff_path);
    try doc.buffer.loadFromSlice(diff);

    // Set it as read-only (if buffer supports it, otherwise just leave it as is)
    // we could also set doc.saved_hash to prevent unsaved changes indicator
    const hash = @import("forge-workspace").edit.contentHash(diff);
    doc.saved_hash = hash;
    doc.disk_hash = hash;
    doc.external_conflict = false;

    wb.focused_panel = .editor;
    wb.syncTabScroll();
    try wb.setStatus("Git diff");
}

pub fn gitCheckout(wb: anytype, branch: []const u8) !void {
    const process_spawn = @import("forge-util").process_spawn;
    const exit_code = process_spawn.runWait(wb.allocator, &.{ "git", "checkout", branch }, .{ .cwd = wb.workspace_path }) catch -1;

    if (exit_code == 0) {
        try refreshGitStatus(wb);
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Switched to branch '{s}'", .{branch}) catch "Switched branch";
        try wb.setStatus(msg);
    } else {
        try wb.setStatus("Git checkout failed");
    }
}

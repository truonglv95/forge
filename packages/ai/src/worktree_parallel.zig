//! Git worktree parallel agents — run multiple agents concurrently in
//! separate git worktrees, then merge results.
//!
//! When the user wants to try multiple approaches to the same task in parallel,
//! this module creates N git worktrees from the current branch, spawns an agent
//! in each, and collects results. The best result (or all results) can then be
//! merged back into the main workspace.
//!
//! This is the Antigravity "spin up 3 agents, pick best" model, implemented
//! via git worktrees instead of cloud sessions.
//!
//! Usage:
//!   forge agent run-parallel "fix the login bug" --count 3
//!
//! Each agent runs in .forge-worktrees/agent-0, .forge-worktrees/agent-1, etc.
//! Worktrees are git branches off the current HEAD, so agents can make edits
//! without conflicting with each other. After all agents complete, the user
//! can inspect diffs and merge the best one.

const std = @import("std");

pub const WorktreeError = error{
    GitFailed,
    WorktreeCreateFailed,
    AgentFailed,
    OutOfMemory,
    InvalidConfig,
};

pub const WorktreeResult = struct {
    agent_index: usize,
    worktree_path: []const u8,
    branch_name: []const u8,
    exit_code: u8,
    session_id: ?[]const u8 = null,
    /// Summary of the agent's final output (first 500 chars).
    summary: ?[]const u8 = null,
};

/// Configuration for a parallel agent run.
pub const ParallelConfig = struct {
    /// Number of parallel agents to spawn.
    count: u32 = 3,
    /// Base directory for worktrees (relative to workspace root).
    worktree_dir: []const u8 = ".forge-worktrees",
    /// Branch name prefix. Branches will be named forge-parallel-<index>.
    branch_prefix: []const u8 = "forge-parallel",
    /// Whether to clean up worktrees after collecting results.
    cleanup_on_finish: bool = false,
};

/// Create N git worktrees from the current HEAD. Returns the paths and branch
/// names for each worktree. The caller is responsible for spawning agents in
/// each worktree and cleaning up afterwards.
pub fn createWorktrees(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    config: ParallelConfig,
) ![]WorktreeInfo {
    if (config.count == 0) return error.InvalidConfig;

    const infos = try allocator.alloc(WorktreeInfo, config.count);
    errdefer {
        for (infos) |info| {
            allocator.free(info.path);
            allocator.free(info.branch);
        }
        allocator.free(infos);
    }

    for (infos, 0..) |*info, i| {
        const branch_name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ config.branch_prefix, i });
        errdefer allocator.free(branch_name);

        const worktree_path = try std.fmt.allocPrint(allocator, "{s}/agent-{d}", .{ config.worktree_dir, i });
        errdefer allocator.free(worktree_path);

        // Create a new branch and worktree: git worktree add -b <branch> <path> HEAD
        const argv = [_][]const u8{
            "git",       "-C",          workspace_path, "worktree", "add", "-b",
            branch_name, worktree_path, "HEAD",
        };

        // Execute git worktree add.
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &argv,
        }) catch {
            allocator.free(branch_name);
            allocator.free(worktree_path);
            return error.WorktreeCreateFailed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            allocator.free(branch_name);
            allocator.free(worktree_path);
            return error.WorktreeCreateFailed;
        }

        info.* = .{
            .path = worktree_path,
            .branch = branch_name,
            .index = i,
        };
    }

    return infos;
}

pub const WorktreeInfo = struct {
    path: []const u8,
    branch: []const u8,
    index: usize,
};

/// Remove a git worktree and its branch. Called during cleanup.
pub fn removeWorktree(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    info: WorktreeInfo,
) void {
    // git worktree remove --force <path>
    const remove_argv = [_][]const u8{
        "git", "-C", workspace_path, "worktree", "remove", "--force", info.path,
    };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &remove_argv,
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // git branch -D <branch>
    const branch_argv = [_][]const u8{
        "git", "-C", workspace_path, "branch", "-D", info.branch,
    };
    const branch_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &branch_argv,
    }) catch return;
    defer allocator.free(branch_result.stdout);
    defer allocator.free(branch_result.stderr);
}

/// Free an array of WorktreeInfo.
pub fn freeWorktreeInfos(allocator: std.mem.Allocator, infos: []WorktreeInfo) void {
    for (infos) |info| {
        allocator.free(info.path);
        allocator.free(info.branch);
    }
    allocator.free(infos);
}

/// Format a summary of parallel results for display. Returns owned slice.
pub fn formatResultsSummary(allocator: std.mem.Allocator, results: []const WorktreeResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.print(allocator, "Parallel agent results ({d} agents):\n\n", .{results.len});
    for (results) |r| {
        try buf.print(allocator, "  Agent {d}:\n", .{r.agent_index});
        try buf.print(allocator, "    Branch: {s}\n", .{r.branch_name});
        try buf.print(allocator, "    Exit code: {d}\n", .{r.exit_code});
        if (r.session_id) |id| {
            try buf.print(allocator, "    Session: {s}\n", .{id});
        }
        if (r.summary) |s| {
            const preview = if (s.len > 200) s[0..200] else s;
            try buf.print(allocator, "    Summary: {s}\n", .{preview});
        }
        try buf.append(allocator, '\n');
    }

    try buf.appendSlice(allocator, "To merge a result:\n");
    try buf.appendSlice(allocator, "  git merge <branch-name>\n");
    try buf.appendSlice(allocator, "  # or cherry-pick specific commits\n");

    return try buf.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "ParallelConfig has sensible defaults" {
    const config = ParallelConfig{};
    try std.testing.expectEqual(@as(u32, 3), config.count);
    try std.testing.expectEqualStrings(".forge-worktrees", config.worktree_dir);
    try std.testing.expectEqualStrings("forge-parallel", config.branch_prefix);
    try std.testing.expect(!config.cleanup_on_finish);
}

test "formatResultsSummary formats agent results" {
    const allocator = std.testing.allocator;
    const results = [_]WorktreeResult{
        .{
            .agent_index = 0,
            .worktree_path = ".forge-worktrees/agent-0",
            .branch_name = "forge-parallel-0",
            .exit_code = 0,
            .session_id = "sess_123",
            .summary = "Fixed the bug by adding null check",
        },
        .{
            .agent_index = 1,
            .worktree_path = ".forge-worktrees/agent-1",
            .branch_name = "forge-parallel-1",
            .exit_code = 1,
            .session_id = null,
            .summary = null,
        },
    };

    const summary = try formatResultsSummary(allocator, &results);
    defer allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "2 agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Agent 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Agent 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "forge-parallel-0") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Fixed the bug") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "git merge") != null);
}

test "formatResultsSummary handles empty results" {
    const allocator = std.testing.allocator;
    const summary = try formatResultsSummary(allocator, &.{});
    defer allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "0 agents") != null);
}

const std = @import("std");
const workspace = @import("forge-workspace");
const validation_runner = @import("validation_runner.zig");

pub const TrialError = error{
    InvalidProposal,
    WorkspaceFailed,
    OutOfMemory,
};

pub const TrialResult = struct {
    passed: bool,
    report: []const u8,
    task_count: u32 = 0,
    failed_count: u32 = 0,
    hint_paths: []const []const u8 = &.{},
    isolation: Isolation = .snapshot,
};

pub const Isolation = enum {
    /// Disposable copy of the current workspace, including dirty source files.
    /// This protects the authoritative tree from edits but is not an OS-level
    /// security boundary for hostile build scripts.
    snapshot,
};

const TrialWorkspace = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_dir: std.Io.Dir,
    directory_name: []u8,
    absolute_path: []u8,
    root: workspace.WorkspaceRoot,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        source_root: workspace.WorkspaceRoot,
        source_cwd: []const u8,
    ) !TrialWorkspace {
        _ = source_cwd;
        var source_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const source_path_len = try source_root.dir.realPath(io, &source_path_buf);
        const canonical_source = source_path_buf[0..source_path_len];
        const timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const parent_path = std.fs.path.dirname(canonical_source) orelse return error.WorkspaceFailed;
        const source_name = std.fs.path.basename(canonical_source);
        const directory_name = try std.fmt.allocPrint(allocator, ".forge-trial-{s}-{d}-{d}", .{ source_name, timestamp, std.Thread.getCurrentId() });
        errdefer allocator.free(directory_name);
        var parent_dir = try std.Io.Dir.openDirAbsolute(io, parent_path, .{ .access_sub_paths = true, .iterate = true });
        errdefer parent_dir.close(io);
        parent_dir.deleteTree(io, directory_name) catch {};
        try parent_dir.createDirPath(io, directory_name);
        errdefer parent_dir.deleteTree(io, directory_name) catch {};
        var sandbox_dir = try parent_dir.openDir(io, directory_name, .{ .access_sub_paths = true, .iterate = true });
        errdefer sandbox_dir.close(io);
        const sandbox_root = workspace.WorkspaceRoot.init(sandbox_dir);

        var walker = try source_root.dir.walk(allocator);
        defer walker.deinit();
        var copied_files: usize = 0;
        var copied_bytes: usize = 0;
        while (try walker.next(io)) |entry| {
            if (excluded(entry.path)) continue;
            if (copied_files >= 50_000 or copied_bytes >= 512 * 1024 * 1024) return error.WorkspaceFailed;
            switch (entry.kind) {
                .directory => try sandbox_root.dir.createDirPath(io, entry.path),
                .file => {
                    if (std.fs.path.dirname(entry.path)) |parent| try sandbox_root.dir.createDirPath(io, parent);
                    const source_path = workspace.WorkspacePath.parse(entry.path) catch continue;
                    var snapshot = try workspace.FileSnapshot.read(allocator, io, source_root, source_path);
                    defer snapshot.deinit();
                    copied_files += 1;
                    copied_bytes += snapshot.content.len;
                    try workspace.atomic.replaceFile(io, sandbox_root, source_path, snapshot.content);
                },
                else => {},
            }
        }

        const absolute_path = try std.fs.path.join(allocator, &.{ parent_path, directory_name });
        errdefer allocator.free(absolute_path);
        return .{
            .allocator = allocator,
            .io = io,
            .parent_dir = parent_dir,
            .directory_name = directory_name,
            .absolute_path = absolute_path,
            .root = sandbox_root,
        };
    }

    fn deinit(self: *TrialWorkspace) void {
        self.root.close(self.io);
        self.parent_dir.deleteTree(self.io, self.directory_name) catch {};
        self.parent_dir.close(self.io);
        self.allocator.free(self.directory_name);
        self.allocator.free(self.absolute_path);
        self.* = undefined;
    }

    fn excluded(path: []const u8) bool {
        return pathEqualOrChild(path, ".git") or
            pathEqualOrChild(path, ".forge") or
            pathEqualOrChild(path, ".zig-cache") or
            pathEqualOrChild(path, "zig-cache") or
            pathEqualOrChild(path, "node_modules");
    }

    fn pathEqualOrChild(path: []const u8, prefix: []const u8) bool {
        if (std.mem.eql(u8, path, prefix)) return true;
        return path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/';
    }
};

pub fn hasFailures(results: []const validation_runner.Result) bool {
    for (results) |item| {
        if (!item.skipped and item.exit_code != 0) return true;
    }
    return false;
}

/// Applies proposal to workspace, runs validation_tasks, then restores checkpoint.
pub fn trialApplyAndValidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    workspace_cwd: []const u8,
    proposal_body: []const u8,
) TrialError!TrialResult {
    var proposal = workspace.OwnedProposal.parseJson(allocator, proposal_body) catch return error.InvalidProposal;
    defer proposal.deinit();

    const tasks = proposal.metadata.validation_tasks;
    if (tasks.len == 0) {
        return .{ .passed = true, .report = try allocator.dupe(u8, "") };
    }

    const workspace_edit = proposal.workspaceEdit();
    workspace_edit.validate() catch return error.InvalidProposal;

    var trial_workspace = TrialWorkspace.create(allocator, io, root, workspace_cwd) catch return error.WorkspaceFailed;
    defer trial_workspace.deinit();

    var service = workspace.TransactionService.init(allocator, io, trial_workspace.root);
    var record = workspace.TransactionRecord{
        .id = 0,
        .state = .approved,
        .workspace_edit = workspace_edit,
        .timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    defer service.freeRecord(&record);

    service.apply(&record) catch {
        const report = try allocator.dupe(u8, "proposal failed to apply (stale hash or invalid edit)");
        return .{ .passed = false, .report = report };
    };

    const results = validation_runner.runTasks(allocator, io, trial_workspace.absolute_path, tasks) catch {
        const report = try allocator.dupe(u8, "validation runner failed");
        return .{ .passed = false, .report = report };
    };
    defer validation_runner.freeResults(allocator, results);

    const task_count: u32 = @intCast(results.len);
    var failed_count: u32 = 0;
    for (results) |item| {
        if (!item.skipped and item.exit_code != 0) failed_count += 1;
    }

    const validation_report = validation_runner.formatLines(allocator, results) catch return error.OutOfMemory;
    defer allocator.free(validation_report);
    var hint_paths: []const []const u8 = &.{};
    if (validation_runner.extractFailureHints(allocator, results, 4)) |owned| {
        if (owned.len == 0) {
            allocator.free(owned);
        } else {
            hint_paths = owned;
        }
    } else |_| {}
    errdefer {
        if (hint_paths.len > 0) {
            for (hint_paths) |p| allocator.free(p);
            allocator.free(hint_paths);
        }
    }

    var report_buf: std.ArrayList(u8) = .empty;
    errdefer report_buf.deinit(allocator);
    try report_buf.appendSlice(allocator, "isolation: snapshot (disposable workspace; not an OS security boundary)\n");
    if (hint_paths.len > 0) {
        try report_buf.appendSlice(allocator, "hints:\n");
        for (hint_paths) |p| {
            try report_buf.appendSlice(allocator, " - ");
            try report_buf.appendSlice(allocator, p);
            try report_buf.appendSlice(allocator, "\n");
        }
    }
    try report_buf.appendSlice(allocator, validation_report);
    const report = try report_buf.toOwnedSlice(allocator);
    return .{
        .passed = failed_count == 0,
        .report = report,
        .task_count = task_count,
        .failed_count = failed_count,
        .hint_paths = hint_paths,
    };
}

test "hasFailures detects non-zero exit" {
    const results = [_]validation_runner.Result{
        .{ .task = "zig build test", .exit_code = 0, .output = "" },
        .{ .task = "zig build", .exit_code = 1, .output = "error" },
    };
    try std.testing.expect(hasFailures(results[0..]));
    try std.testing.expect(!hasFailures(results[0..1]));
}

test "repair trial applies only inside disposable snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("source.txt"), "before\n");

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(io, &cwd_buf);
    const cwd = try allocator.dupe(u8, cwd_buf[0..cwd_len]);
    defer allocator.free(cwd);
    const proposal =
        \\{"schema_version":1,"summary":"trial","validation_tasks":["property: inspect manually"],"workspace_edit":{"files":[{"path":"trial-only.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"created only in trial\\n"}]}]}}
    ;
    const result = try trialApplyAndValidate(allocator, io, root, cwd, proposal);
    defer allocator.free(result.report);
    try std.testing.expect(result.passed);
    try std.testing.expect(std.mem.indexOf(u8, result.report, "isolation: snapshot") != null);

    var unchanged = try workspace.FileSnapshot.read(allocator, io, root, try workspace.WorkspacePath.parse("source.txt"));
    defer unchanged.deinit();
    try std.testing.expectEqualStrings("before\n", unchanged.content);
    try std.testing.expectError(error.FileNotFound, root.dir.openFile(io, "trial-only.txt", .{}));
}

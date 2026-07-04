const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const tools = @import("tools.zig");

pub const AgentToolError = error{
    Cancelled,
    NotAllowed,
    WorkspaceFailed,
    TaskFailed,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    cwd: []const u8,
    profile: tools.CapabilityProfile,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
};

pub const Outcome = struct {
    summary: []const u8,
};

pub const SearchOutcome = struct {
    summary: []const u8,
    first_match_path: ?[]const u8,
};

fn checkCancel(ctx: Context) AgentToolError!void {
    if (ctx.cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }
}

fn requireTool(ctx: Context, tool: tools.ToolId) AgentToolError!void {
    if (!tools.isAllowed(ctx.profile, tool)) return error.NotAllowed;
}

pub fn search(ctx: Context, term: []const u8) AgentToolError!SearchOutcome {
    try checkCancel(ctx);
    try requireTool(ctx, .search);

    var result = workspace.search.searchContent(ctx.allocator, ctx.io, ctx.root, ".", term) catch return error.WorkspaceFailed;
    defer result.deinit();

    const summary = std.fmt.allocPrint(ctx.allocator, "search '{s}' -> {d} hits", .{ term, result.matches.len }) catch return error.WorkspaceFailed;

    const first_match_path = if (result.matches.len > 0)
        ctx.allocator.dupe(u8, result.matches[0].path) catch return error.WorkspaceFailed
    else
        null;

    return .{ .summary = summary, .first_match_path = first_match_path };
}

pub fn listTree(ctx: Context) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .list_tree);

    var tree = workspace.tree.scan(ctx.allocator, ctx.io, ctx.root, ".") catch return error.WorkspaceFailed;
    defer tree.deinit();

    const summary = std.fmt.allocPrint(ctx.allocator, "list_tree -> {d} files, {d} dirs", .{
        tree.file_count,
        tree.dir_count,
    }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn readFile(ctx: Context, rel_path: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .read_file);

    const wp = workspace.WorkspacePath.parse(rel_path) catch return error.WorkspaceFailed;
    var snap = workspace.FileSnapshot.read(ctx.allocator, ctx.io, ctx.root, wp) catch return error.WorkspaceFailed;
    defer snap.deinit();

    const summary = std.fmt.allocPrint(ctx.allocator, "read_file '{s}' -> {d} bytes (hash {x})", .{
        rel_path,
        snap.content.len,
        snap.hash,
    }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn runTask(ctx: Context, task_name: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .run_task);

    const argv = if (std.mem.eql(u8, task_name, "test"))
        &[_][]const u8{ "zig", "build", "test" }
    else if (std.mem.eql(u8, task_name, "build"))
        &[_][]const u8{ "zig", "build" }
    else if (std.mem.eql(u8, task_name, "fmt"))
        &[_][]const u8{ "zig", "fmt", "--check", "." }
    else
        return error.NotAllowed;

    const term = kernel.process.run(ctx.allocator, ctx.io, .{
        .argv = argv,
        .cwd = ctx.cwd,
        .token = if (ctx.cancel_token) |token| token else null,
    }) catch return error.TaskFailed;

    const exit_code: u8 = switch (term) {
        .exited => |code| @intCast(code),
        else => 1,
    };

    if (ctx.cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const summary = std.fmt.allocPrint(ctx.allocator, "run_task '{s}' -> exit {d}", .{ task_name, exit_code }) catch return error.WorkspaceFailed;
    if (exit_code != 0) return error.TaskFailed;
    return .{ .summary = summary };
}

test "tool executor search finds content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge search\n");

    const outcome = try search(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .propose,
    }, "forge");
    defer allocator.free(outcome.summary);
    if (outcome.first_match_path) |path| {
        defer allocator.free(path);
    }

    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "1 hits") != null);
    try std.testing.expect(outcome.first_match_path != null);
}

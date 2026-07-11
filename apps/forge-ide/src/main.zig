const std = @import("std");
const kernel = @import("forge-kernel");
const workspace = @import("forge-workspace");
const Workbench = @import("workbench.zig");
const builtin_ext = @import("extensions/builtin.zig");
const recent_workspaces = @import("workbench/recent_workspaces.zig");
const state = @import("ui/core/state.zig");
const shell = @import("ui/core/shell.zig");

pub fn main(init: std.process.Init) !void {
    state.gpa = std.heap.page_allocator;
    const allocator = state.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    var owned_workspace_path: ?[]u8 = null;
    defer if (owned_workspace_path) |path| allocator.free(path);
    const workspace_path = try resolveWorkspacePath(allocator, io, args, &owned_workspace_path);

    std.debug.print("Forge IDE starting for workspace: {s}\n", .{workspace_path});

    const launcher: []const u8 = if (args.len > 0) args[0] else "forge-ide";
    const wb = try allocator.create(Workbench.Workbench);
    std.debug.print("Forge IDE: loading workbench…\n", .{});
    try Workbench.Workbench.init(wb, allocator, io, workspace_path, launcher, init.environ_map);
    std.debug.print("Forge IDE ready — opening window (close window or Ctrl+C to exit)\n", .{});
    defer {
        wb.deinit();
        allocator.destroy(wb);
    }
    state.wb = wb;
    builtin_ext.bindStatus(&.{ .setStatus = state.StatusBridge.setStatus });

    state.prompt_buffer = &wb.prompt_buffer;
    state.chat_history = &wb.chat_history;

    const kernel_thread = try std.Thread.spawn(.{}, backgroundKernelTask, .{workspace_path});
    _ = kernel_thread;

    try shell.initShell(allocator);
    shell.runRenderer();

    std.debug.print("Forge IDE UI closed, shutting down.\n", .{});
}

fn backgroundKernelTask(workspace_path: []const u8) void {
    std.debug.print("[Kernel] Background thread started.\n", .{});
    var lifecycle = kernel.Lifecycle{};
    lifecycle.transition(.starting) catch unreachable;
    std.debug.print("[Kernel] Initializing workspace at {s}\n", .{workspace_path});
    lifecycle.transition(.running) catch unreachable;
    std.debug.print("[Kernel] Ready and listening for events.\n", .{});
}

fn resolveWorkspacePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    owned_workspace_path: *?[]u8,
) ![]const u8 {
    if (args.len > 1 and !std.mem.startsWith(u8, args[1], "-psn_")) {
        return args[1];
    }

    if (!shouldUseAppLaunchFallback(io)) {
        return ".";
    }

    if (try latestUsableRecentWorkspace(allocator, io)) |recent| {
        owned_workspace_path.* = recent;
        return recent;
    }

    if (homeWorkspace(allocator, io)) |home| {
        owned_workspace_path.* = home;
        return home;
    }

    return ".";
}

fn shouldUseAppLaunchFallback(io: std.Io) bool {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return false;
    const cwd = cwd_buf[0..cwd_len];
    return std.mem.eql(u8, cwd, "/") or std.mem.indexOf(u8, cwd, ".app/Contents/MacOS") != null;
}

fn latestUsableRecentWorkspace(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const paths = recent_workspaces.loadAll(allocator, io) catch return null;
    defer recent_workspaces.freePaths(allocator, paths);

    for (paths) |path| {
        if (!std.fs.path.isAbsolute(path)) continue;
        if (!isUsableWorkspace(io, path)) continue;
        return try allocator.dupe(u8, path);
    }

    return null;
}

fn homeWorkspace(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    const home_env = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_env);
    if (!isUsableWorkspace(io, home)) return null;
    return allocator.dupe(u8, home) catch null;
}

fn isUsableWorkspace(io: std.Io, path: []const u8) bool {
    var root = workspace.WorkspaceRoot.open(io, path) catch return false;
    root.close(io);
    return true;
}

const std = @import("std");
const kernel = @import("forge-kernel");
const workspace = @import("forge-workspace");
const core = @import("forge-core");
const telemetry = core.telemetry;
const Workbench = @import("workbench.zig");
const builtin_ext = @import("extensions/builtin.zig");
const recent_workspaces = @import("workbench/recent_workspaces.zig");
const state = @import("ui/core/state.zig");
const shell = @import("ui/core/shell.zig");

pub fn main(init: std.process.Init) !void {
    state.gpa = std.heap.c_allocator;
    const allocator = state.gpa;
    const io = init.io;
    if (init.environ_map.get("FORGE_PERF")) |value| {
        state.perf_overlay_enabled = std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
    }

    const args = try init.minimal.args.toSlice(allocator);

    var is_perf_harness = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--perf-harness")) {
            is_perf_harness = true;
            try telemetry.init("trace.json");
            state.continuous_rendering_enabled = true;
            break;
        }
    }
    defer telemetry.deinit();

    var opt_startup_span: ?telemetry.Span = null;
    if (is_perf_harness) {
        opt_startup_span = telemetry.startSpan("ide", "startup");
    }

    var owned_workspace_path: ?[]u8 = null;
    defer if (owned_workspace_path) |path| allocator.free(path);
    const launch = try resolveWorkspacePath(allocator, io, args, &owned_workspace_path);

    std.debug.print("Forge IDE starting for workspace: {s}\n", .{launch.path});

    const launcher: []const u8 = if (args.len > 0) args[0] else "forge-ide";
    const wb = try allocator.create(Workbench.Workbench);
    std.debug.print("Forge IDE: loading workbench…\n", .{});
    try Workbench.Workbench.initWithOptions(wb, allocator, io, launch.path, launcher, init.environ_map, .{
        .show_welcome = launch.show_welcome,
        .record_workspace = launch.record_workspace,
    });
    std.debug.print("Forge IDE ready — opening window (close window or Ctrl+C to exit)\n", .{});
    defer {
        wb.deinit();
        allocator.destroy(wb);
    }
    state.wb = wb;
    builtin_ext.bindStatus(&.{ .setStatus = state.StatusBridge.setStatus });

    state.prompt_buffer = &wb.agent_ui.prompt_buffer;
    state.chat_history = &wb.agent_ui.chat_history;

    const kernel_thread = try std.Thread.spawn(.{}, backgroundKernelTask, .{launch.path});
    _ = kernel_thread;

    try shell.initShell(allocator);

    if (opt_startup_span) |*span| span.end();

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

const LaunchWorkspace = struct {
    path: []const u8,
    show_welcome: bool = false,
    record_workspace: bool = true,
};

fn resolveWorkspacePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    owned_workspace_path: *?[]u8,
) !LaunchWorkspace {
    var path_arg: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            path_arg = arg;
            break;
        }
    }

    if (path_arg) |p| {
        return .{ .path = p };
    }

    if (!shouldUseAppLaunchFallback(io)) {
        return .{ .path = "." };
    }

    if (try latestUsableRecentWorkspace(allocator, io)) |recent| {
        owned_workspace_path.* = recent;
        return .{ .path = recent };
    }

    if (homeWorkspace(allocator, io)) |home| {
        owned_workspace_path.* = home;
        return .{ .path = home, .show_welcome = true, .record_workspace = false };
    }

    return .{ .path = ".", .show_welcome = true, .record_workspace = false };
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

test {
    _ = @import("workbench/conflict_resolver_test.zig");
    _ = @import("workbench/debug_recovery_test.zig");
    _ = @import("workbench/lsp_controller_test.zig");
}

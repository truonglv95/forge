const std = @import("std");
const kernel = @import("forge-kernel");
const Workbench = @import("workbench.zig");
const builtin_ext = @import("extensions/builtin.zig");
const state = @import("ui/core/state.zig");
const shell = @import("ui/core/shell.zig");

pub fn main(init: std.process.Init) !void {
    state.gpa = std.heap.page_allocator;
    const allocator = state.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    const workspace_path: []const u8 = if (args.len > 1) args[1] else ".";

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

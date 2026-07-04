const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;

pub fn spawn(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_name: []const u8,
    workspace_path: []const u8,
    on_line: *const fn (context: ?*anyopaque, line: []const u8) void,
    on_finished: *const fn (context: ?*anyopaque, exit_code: i32) void,
    context: ?*anyopaque,
) !void {
    _ = io;
    const ctx = try allocator.create(SpawnContext);
    ctx.* = .{
        .allocator = allocator,
        .task_name = try allocator.dupe(u8, task_name),
        .workspace_path = try allocator.dupe(u8, workspace_path),
        .on_line = on_line,
        .on_finished = on_finished,
        .context = context,
    };

    const thread = try std.Thread.spawn(.{}, worker, .{ctx});
    thread.detach();
}

const SpawnContext = struct {
    allocator: std.mem.Allocator,
    task_name: []const u8,
    workspace_path: []const u8,
    on_line: *const fn (context: ?*anyopaque, line: []const u8) void,
    on_finished: *const fn (context: ?*anyopaque, exit_code: i32) void,
    context: ?*anyopaque,

    fn deinit(self: *SpawnContext) void {
        self.allocator.free(self.task_name);
        self.allocator.free(self.workspace_path);
        self.allocator.destroy(self);
    }
};

fn worker(ctx: *SpawnContext) void {
    defer ctx.deinit();

    const argv = taskArgv(ctx.task_name);
    ctx.on_line(ctx.context, "→ running task...");

    const result = process_spawn.runCapture(ctx.allocator, argv, .{
        .cwd = ctx.workspace_path,
        .stdin = .ignore,
    }) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "spawn failed: {}", .{err}) catch "spawn failed";
        ctx.on_line(ctx.context, msg);
        ctx.on_finished(ctx.context, 1);
        return;
    };
    defer ctx.allocator.free(result.output);

    emitLines(ctx, result.output);
    ctx.on_finished(ctx.context, result.exit_code);
}

fn emitLines(ctx: *SpawnContext, bytes: []const u8) void {
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == '\n') {
            ctx.on_line(ctx.context, bytes[start..index]);
            start = index + 1;
        }
    }
    if (start < bytes.len) ctx.on_line(ctx.context, bytes[start..]);
}

fn taskArgv(task_name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, task_name, "test")) {
        return &[_][]const u8{ "zig", "build", "test" };
    }
    if (std.mem.eql(u8, task_name, "check")) {
        return &[_][]const u8{ "sh", "-c", "./scripts/check.sh" };
    }
    if (std.mem.eql(u8, task_name, "build")) {
        return &[_][]const u8{ "zig", "build" };
    }
    return &[_][]const u8{ "sh", "-c", task_name };
}

test "task argv maps test name" {
    const argv = taskArgv("test");
    try std.testing.expectEqualStrings("zig", argv[0]);
}

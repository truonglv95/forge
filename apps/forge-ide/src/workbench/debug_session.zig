const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;
const breakpoints_mod = @import("breakpoints.zig");

const max_lldb_args = 30;

pub fn spawnCurrentFile(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    source_rel_path: []const u8,
    breakpoints: *const breakpoints_mod.Store,
    on_line: *const fn (context: ?*anyopaque, line: []const u8) void,
    on_finished: *const fn (context: ?*anyopaque, exit_code: i32) void,
    context: ?*anyopaque,
) !void {
    const ctx = try allocator.create(SpawnContext);
    ctx.* = .{
        .allocator = allocator,
        .workspace_path = try allocator.dupe(u8, workspace_path),
        .source_path = try allocator.dupe(u8, source_rel_path),
        .on_line = on_line,
        .on_finished = on_finished,
        .context = context,
    };
    for (breakpoints.items.items) |bp| {
        try ctx.breakpoint_paths.append(allocator, try allocator.dupe(u8, bp.path));
        try ctx.breakpoint_lines.append(allocator, bp.line);
    }

    const thread = try std.Thread.spawn(.{}, worker, .{ctx});
    thread.detach();
}

const SpawnContext = struct {
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    source_path: []const u8,
    breakpoint_paths: std.ArrayList([]const u8) = .empty,
    breakpoint_lines: std.ArrayList(usize) = .empty,
    bp_commands: [8][512]u8 = undefined,
    bp_command_count: usize = 0,
    on_line: *const fn (context: ?*anyopaque, line: []const u8) void,
    on_finished: *const fn (context: ?*anyopaque, exit_code: i32) void,
    context: ?*anyopaque,

    fn deinit(self: *SpawnContext) void {
        for (self.breakpoint_paths.items) |path| self.allocator.free(path);
        self.breakpoint_paths.deinit(self.allocator);
        self.breakpoint_lines.deinit(self.allocator);
        self.allocator.free(self.workspace_path);
        self.allocator.free(self.source_path);
        self.allocator.destroy(self);
    }
};

fn worker(ctx: *SpawnContext) void {
    defer ctx.deinit();

    var argv_storage: [max_lldb_args][]const u8 = undefined;
    var argv_len: usize = 0;

    argv_storage[argv_len] = "lldb";
    argv_len += 1;

    var bp_count: usize = 0;
    for (ctx.breakpoint_paths.items, ctx.breakpoint_lines.items) |path, line| {
        if (bp_count >= ctx.bp_commands.len) break;
        if (!std.mem.eql(u8, path, ctx.source_path)) continue;

        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ ctx.workspace_path, path }) catch continue;

        const cmd = std.fmt.bufPrint(&ctx.bp_commands[bp_count], "breakpoint set -f {s} -l {d}", .{ abs_path, line + 1 }) catch continue;

        argv_storage[argv_len] = "-o";
        argv_len += 1;
        argv_storage[argv_len] = cmd;
        argv_len += 1;
        bp_count += 1;
    }
    ctx.bp_command_count = bp_count;

    argv_storage[argv_len] = "-o";
    argv_len += 1;
    argv_storage[argv_len] = "run";
    argv_len += 1;
    argv_storage[argv_len] = "-o";
    argv_len += 1;
    argv_storage[argv_len] = "bt all";
    argv_len += 1;
    argv_storage[argv_len] = "-o";
    argv_len += 1;
    argv_storage[argv_len] = "quit";
    argv_len += 1;
    argv_storage[argv_len] = "--";
    argv_len += 1;
    argv_storage[argv_len] = "zig";
    argv_len += 1;
    argv_storage[argv_len] = "run";
    argv_len += 1;
    argv_storage[argv_len] = ctx.source_path;
    argv_len += 1;

    ctx.on_line(ctx.context, "→ lldb debug session starting…");

    const result = process_spawn.runCapture(ctx.allocator, argv_storage[0..argv_len], .{
        .cwd = ctx.workspace_path,
        .stdin = .ignore,
    }) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "lldb spawn failed: {}", .{err}) catch "lldb spawn failed";
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

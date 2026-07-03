const std = @import("std");
const kernel = @import("forge-kernel");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: task requires a task name\n");
        return 2;
    }

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    const task_name = parsed.positional[0];
    const argv = if (std.mem.eql(u8, task_name, "test"))
        &[_][]const u8{ "zig", "build", "test" }
    else if (std.mem.eql(u8, task_name, "build"))
        &[_][]const u8{ "zig", "build" }
    else if (std.mem.eql(u8, task_name, "fmt"))
        &[_][]const u8{ "zig", "fmt", "--check", "." }
    else {
        try writer.print("error: unknown task '{s}'\n", .{task_name});
        return 2;
    };

    const cwd = resolveWorkspaceCwd(opened.path);
    if (!parsed.flags.quiet) {
        try writer.print("Running task '{s}'\n", .{task_name});
    }

    const term = try kernel.process.run(allocator, io, .{ .argv = argv, .cwd = cwd });
    const exit_code: u8 = switch (term) {
        .exited => |code| @intCast(code),
        else => 1,
    };

    if (parsed.flags.json) {
        try writer.print("{{\"status\":\"ok\",\"type\":\"task\",\"name\":\"{s}\",\"exit_code\":{d}}}\n", .{ task_name, exit_code });
    } else {
        try writer.print("Task '{s}' finished with exit code {d}\n", .{ task_name, exit_code });
    }

    return exit_code;
}

fn resolveWorkspaceCwd(path: []const u8) []const u8 {
    return path;
}

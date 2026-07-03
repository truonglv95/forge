const std = @import("std");
const kernel = @import("forge-kernel");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    const cwd = resolveWorkspaceCwd(opened.path);

    if (!parsed.flags.quiet) {
        try writer.writeAll("Running validation: zig build test\n");
    }

    const term = try kernel.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", "test" },
        .cwd = cwd,
    });

    const exit_code: u8 = switch (term) {
        .exited => |code| @intCast(code),
        else => 1,
    };

    if (parsed.flags.json) {
        try writer.print("{{\"status\":\"ok\",\"type\":\"check\",\"exit_code\":{d}}}\n", .{exit_code});
    } else if (exit_code == 0) {
        try writer.writeAll("All checks passed.\n");
    } else {
        try writer.print("Checks failed with exit code {d}\n", .{exit_code});
    }

    return exit_code;
}

fn resolveWorkspaceCwd(path: []const u8) []const u8 {
    return path;
}

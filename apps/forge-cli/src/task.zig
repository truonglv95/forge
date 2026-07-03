const std = @import("std");
const args_mod = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    _ = allocator;

    if (parsed.positional.len == 0) {
        try writer.writeAll("error: task requires a task name\n");
        return 2;
    }

    const task_name = parsed.positional[0];
    try writer.print("Running task: {s}\n", .{task_name});

    return 0;
}

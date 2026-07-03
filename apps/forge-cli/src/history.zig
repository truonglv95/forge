const std = @import("std");
const args_mod = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    _ = allocator;
    _ = parsed;

    try writer.writeAll("Transaction history:\n");
    try writer.writeAll(" (No transactions yet)\n");
    return 0;
}

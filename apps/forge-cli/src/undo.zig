const std = @import("std");
const args_mod = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    _ = allocator;

    if (parsed.positional.len == 0) {
        try writer.writeAll("error: undo requires a transaction id\n");
        return 2;
    }

    const tx_id = parsed.positional[0];
    try writer.print("Undoing transaction: {s}\n", .{tx_id});
    return 0;
}

const std = @import("std");
const args_mod = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    _ = allocator;
    
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: apply requires a proposal file\n");
        return 2;
    }
    
    const file_path = parsed.positional[0];
    
    if (parsed.flags.dry_run) {
        try writer.print("Dry-run apply for proposal: {s}\n", .{file_path});
    } else {
        try writer.print("Applying proposal: {s}\n", .{file_path});
    }
    
    return 0;
}

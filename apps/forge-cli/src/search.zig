const std = @import("std");
const args_mod = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    _ = allocator;

    if (parsed.positional.len == 0) {
        try writer.writeAll("error: search requires a query\n");
        return 2;
    }
    
    const query = parsed.positional[0];

    if (parsed.flags.json) {
        try writer.print("{{\"status\": \"ok\", \"type\": \"search\", \"query\": \"{s}\", \"matches\": []}}\n", .{query});
    } else {
        try writer.print("Searching for: '{s}'\n", .{query});
        try writer.writeAll("No matches found.\n");
    }
    
    return 0;
}

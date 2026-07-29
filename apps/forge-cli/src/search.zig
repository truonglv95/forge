const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: search requires a query\n");
        return 2;
    }

    const query = parsed.positional[0];
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var result = try workspace.search.searchContent(allocator, io, opened.root, opened.path, query);
    defer result.deinit();

    if (parsed.flags.json) {
        try writer.print("{{\"status\":\"ok\",\"type\":\"search\",\"query\":\"{s}\",\"matches\":[", .{query});
        for (result.matches, 0..) |match, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("{{\"path\":\"{s}\",\"line\":{d},\"column\":{d},\"text\":\"{s}\"}}", .{
                match.path, match.line, match.column, match.line_text,
            });
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.print("Search results for '{s}' ({d} matches)\n", .{ query, result.matches.len });
        for (result.matches) |match| {
            try writer.print("{s}:{d}:{d}: {s}\n", .{ match.path, match.line, match.column, match.line_text });
        }
    }

    return 0;
}

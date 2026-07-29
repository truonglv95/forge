const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var list = try workspace.history.listEntries(allocator, io, opened.root);
    defer list.deinit();

    if (parsed.flags.json) {
        try writer.writeAll("{\"status\":\"ok\",\"type\":\"history\",\"transactions\":[");
        for (list.items, 0..) |entry, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("{{\"id\":{d},\"state\":\"{s}\",\"timestamp_ms\":{d},\"proposal_path\":\"{s}\"}}", .{
                entry.id, @tagName(entry.state), entry.timestamp_ms, entry.proposal_path,
            });
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.writeAll("Transaction history:\n");
        if (list.items.len == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            for (list.items) |entry| {
                try writer.print("  {d} [{s}] {s} ({d})\n", .{
                    entry.id, @tagName(entry.state), entry.proposal_path, entry.timestamp_ms,
                });
            }
        }
    }

    return 0;
}

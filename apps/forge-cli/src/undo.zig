const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: undo requires a transaction id\n");
        return 2;
    }

    const tx_id = try std.fmt.parseInt(u64, parsed.positional[0], 10);

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var loaded = try workspace.history.loadRecord(allocator, io, opened.root, tx_id);
    var service = workspace.TransactionService.init(allocator, io, opened.root);
    defer loaded.deinit(&service);

    if (loaded.record.state != .applied) {
        try writer.print("error: transaction {d} is not in applied state\n", .{tx_id});
        return 2;
    }

    service.undo(&loaded.record) catch |err| switch (err) {
        error.UndoConflict => {
            if (parsed.flags.json) {
                try writer.print("{{\"status\":\"error\",\"type\":\"undo\",\"transaction_id\":{d},\"error\":\"undo_conflict\"}}\n", .{tx_id});
            } else {
                try writer.print("error: transaction {d} cannot be undone because affected files changed after apply\n", .{tx_id});
            }
            return 3;
        },
        else => return err,
    };
    try workspace.history.updateEntryState(io, opened.root, tx_id, .undone);

    if (parsed.flags.json) {
        try writer.print("{{\"status\":\"ok\",\"type\":\"undo\",\"transaction_id\":{d},\"state\":\"undone\"}}\n", .{tx_id});
    } else {
        try writer.print("Undid transaction {d}\n", .{tx_id});
    }

    return 0;
}

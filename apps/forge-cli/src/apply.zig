const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: apply requires a proposal file\n");
        return 2;
    }

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var proposal = try workspace_cmd.loadProposal(allocator, io, opened, parsed.positional[0]);
    defer proposal.deinit();

    const workspace_edit = proposal.workspaceEdit();
    try workspace_edit.validate();

    if (parsed.flags.dry_run) {
        if (parsed.flags.json) {
            try writer.writeAll("{\"status\":\"ok\",\"type\":\"apply\",\"dry_run\":true}\n");
        } else {
            try writer.print("Dry-run apply for {s}\n\n", .{parsed.positional[0]});
            try workspace.preview.renderDiff(allocator, io, opened.root, workspace_edit, writer);
        }
        return 0;
    }

    if (!workspace_cmd.approved(parsed)) {
        try writer.writeAll("error: apply requires --yes or --non-interactive approval\n");
        return 2;
    }

    var service = workspace.TransactionService.init(allocator, io, opened.root);
    const tx_id = try workspace.history.nextTransactionId(allocator, io, opened.root);

    var record = workspace.TransactionRecord{
        .id = tx_id,
        .state = .approved,
        .workspace_edit = workspace_edit,
        .timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    defer service.freeRecord(&record);

    try service.apply(&record);
    try workspace.history.persistApplied(allocator, io, opened.root, &record, parsed.positional[0]);

    if (parsed.flags.json) {
        try writer.print("{{\"status\":\"ok\",\"type\":\"apply\",\"transaction_id\":{d},\"state\":\"applied\"}}\n", .{tx_id});
    } else {
        try writer.print("Applied transaction {d}\n", .{tx_id});
    }

    return 0;
}

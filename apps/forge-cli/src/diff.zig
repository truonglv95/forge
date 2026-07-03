const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: diff requires a proposal file\n");
        return 2;
    }

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var proposal = try workspace_cmd.loadProposal(allocator, io, opened, parsed.positional[0]);
    defer proposal.deinit();

    const edit = proposal.workspaceEdit();
    try edit.validate();

    if (parsed.flags.json) {
        try writer.writeAll("{\"status\":\"ok\",\"type\":\"diff\",\"valid\":true,\"files\":");
        try writer.print("{d}}}\n", .{edit.files.len});
    } else {
        try writer.print("Diff preview for {s}\n\n", .{parsed.positional[0]});
        try workspace.preview.renderDiff(allocator, io, opened.root, edit, writer);
    }

    return 0;
}

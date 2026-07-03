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
        try writer.writeAll("{\"status\":\"ok\",\"type\":\"diff\",\"valid\":true");
        if (proposal.metadata.schema_version) |version| {
            try writer.print(",\"schema_version\":{d}", .{version});
        }
        if (proposal.metadata.summary) |summary| {
            try writer.print(",\"summary\":\"{s}\"", .{summary});
        }
        if (proposal.metadata.assumptions.len > 0) {
            try writer.writeAll(",\"assumptions\":[");
            for (proposal.metadata.assumptions, 0..) |item, index| {
                if (index > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{item});
            }
            try writer.writeAll("]");
        }
        if (proposal.metadata.validation_tasks.len > 0) {
            try writer.writeAll(",\"validation_tasks\":[");
            for (proposal.metadata.validation_tasks, 0..) |item, index| {
                if (index > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{item});
            }
            try writer.writeAll("]");
        }
        try writer.writeAll(",\"files\":");
        try writer.print("{d}}}\n", .{edit.files.len});
    } else {
        try writer.print("Diff preview for {s}\n\n", .{parsed.positional[0]});
        try workspace.preview.renderDiff(allocator, io, opened.root, edit, writer);
    }

    return 0;
}

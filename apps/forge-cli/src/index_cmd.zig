const std = @import("std");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    const status_only = parsed.positional.len > 0 and std.mem.eql(u8, parsed.positional[0], "status");

    if (status_only) {
        const status = try ai.index_warm.workspaceStatus(allocator, io, opened.root, opened.path);
        if (parsed.flags.json) {
            try writer.print(
                "{{\"status\":\"{s}\",\"workspace\":\"{s}\"}}\n",
                .{ @tagName(status), opened.path },
            );
        } else {
            try writer.print("semantic index: {s} ({s})\n", .{ @tagName(status), opened.path });
        }
        return 0;
    }

    if (!parsed.flags.quiet and !parsed.flags.json) {
        try writer.print("Building semantic index for {s}...\n", .{opened.path});
    }

    const report = try ai.index_warm.buildForeground(allocator, io, opened.root, environ_map);

    if (parsed.flags.json) {
        try writer.print(
            "{{\"status\":\"{s}\",\"rebuilt\":{},\"chunk_count\":{d},\"file_count\":{d},\"workspace\":\"{s}\"}}\n",
            .{ @tagName(report.status), report.rebuilt, report.chunk_count, report.file_count, opened.path },
        );
    } else if (!parsed.flags.quiet) {
        try writer.print(
            "semantic index ready: {d} chunks, {d} files{s}\n",
            .{ report.chunk_count, report.file_count, if (report.rebuilt) " (rebuilt)" else "" },
        );
    }

    return 0;
}

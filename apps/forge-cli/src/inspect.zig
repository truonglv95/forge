const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    const workspace_path = parsed.flags.workspace orelse ".";
    var root = try workspace.WorkspaceRoot.open(io, workspace_path);
    defer root.close(io);

    var summary = try workspace.tree.scan(allocator, io, root, workspace_path);
    defer summary.deinit();

    if (parsed.flags.json) {
        try writer.writeAll("{\"status\":\"ok\",\"type\":\"inspect\",\"data\":{");
        try writer.print("\"root\":\"{s}\",\"files\":{d},\"directories\":{d},\"entries\":[", .{
            summary.root_path,
            summary.file_count,
            summary.dir_count,
        });
        for (summary.entries, 0..) |entry, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print("{{\"path\":\"{s}\",\"kind\":\"{s}\"}}", .{
                entry.path,
                kindName(entry.kind),
            });
        }
        try writer.writeAll("]}}\n");
    } else {
        try writer.print("Workspace Inspection\n", .{});
        try writer.print("Root: {s}\n", .{summary.root_path});
        try writer.print("Files: {d}\n", .{summary.file_count});
        try writer.print("Directories: {d}\n\n", .{summary.dir_count});
        try writer.writeAll("Tree:\n");
        for (summary.entries) |entry| {
            try writer.print("  [{s}] {s}\n", .{ kindName(entry.kind), entry.path });
        }
    }

    return 0;
}

fn kindName(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "dir",
        .sym_link => "symlink",
        .unknown => "unknown",
        else => "other",
    };
}

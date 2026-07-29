const std = @import("std");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");

pub fn renderDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    workspace_edit: edit.WorkspaceEdit,
    writer: *std.Io.Writer,
) !void {
    for (workspace_edit.files) |file_edit| {
        const wp = try path_mod.WorkspacePath.parse(file_edit.path);
        try writer.print("--- a/{s}\n", .{file_edit.path});
        try writer.print("+++ b/{s}\n", .{file_edit.path});

        switch (file_edit.operation) {
            .create => {
                const after = try workspace_edit.materializeContent(allocator, io, root, file_edit);
                defer allocator.free(after);
                try writer.writeAll("@@ new file @@\n");
                var lines = std.mem.splitScalar(u8, after, '\n');
                while (lines.next()) |line| {
                    try writer.print("+{s}\n", .{line});
                }
            },
            .delete => {
                var before = try snapshot.FileSnapshot.read(allocator, io, root, wp);
                defer before.deinit();
                try writer.writeAll("@@ deleted file @@\n");
                for (before.content) |byte| {
                    try writer.print("-{c}", .{byte});
                    if (byte == '\n') {}
                }
                if (before.content.len == 0 or before.content[before.content.len - 1] != '\n') try writer.writeAll("\n");
            },
            .modify => {
                var before = try snapshot.FileSnapshot.read(allocator, io, root, wp);
                defer before.deinit();
                const after = try workspace_edit.materializeContent(allocator, io, root, file_edit);
                defer allocator.free(after);
                try writer.writeAll("@@ modified @@\n");
                try renderLineDiff(before.content, after, writer);
            },
        }
        try writer.writeAll("\n");
    }
}

fn renderLineDiff(before: []const u8, after: []const u8, writer: *std.Io.Writer) !void {
    if (std.mem.eql(u8, before, after)) {
        try writer.writeAll(" (no net change)\n");
        return;
    }

    var before_lines = std.mem.splitScalar(u8, before, '\n');
    var after_lines = std.mem.splitScalar(u8, after, '\n');
    while (true) {
        const b = before_lines.next();
        const a = after_lines.next();
        if (b == null and a == null) break;
        const before_line = b orelse "";
        const after_line = a orelse "";
        if (!std.mem.eql(u8, before_line, after_line)) {
            if (b != null) try writer.print("-{s}\n", .{before_line});
            if (a != null) try writer.print("+{s}\n", .{after_line});
        }
    }
}

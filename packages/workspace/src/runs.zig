const std = @import("std");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");

pub const runs_dir = ".forge/runs";
pub const runs_index = ".forge/runs/index.jsonl";

pub fn ensureLayout(io: std.Io, root: path_mod.WorkspaceRoot) !void {
    try root.dir.createDirPath(io, ".forge");
    try root.dir.createDirPath(io, runs_dir);
}

pub fn persistRun(io: std.Io, root: path_mod.WorkspaceRoot, run_id: []const u8, json_body: []const u8) !void {
    try ensureLayout(io, root);

    var path_buf: [128]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ runs_dir, run_id });
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(rel), json_body);
}

pub fn appendIndex(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, line: []const u8) !void {
    try ensureLayout(io, root);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const existing = readRelativeFile(allocator, io, root, runs_index) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        try buffer.appendSlice(allocator, bytes);
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try buffer.append(allocator, '\n');
    }

    try buffer.appendSlice(allocator, line);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(runs_index), buffer.items);
}

fn readRelativeFile(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, rel_path: []const u8) ![]u8 {
    var file = try root.dir.openFile(io, rel_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

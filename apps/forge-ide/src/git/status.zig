const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;

pub const Entry = struct {
    status: [2]u8,
    path: []const u8,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn label(self: Entry) []const u8 {
        return switch (self.status[0]) {
            '?' => "untracked",
            '!' => "ignored",
            'A' => "added",
            'M' => "modified",
            'D' => "deleted",
            'R' => "renamed",
            'C' => "copied",
            'U' => "conflict",
            else => "changed",
        };
    }
};

pub const Status = struct {
    entries: []Entry,
    is_repo: bool,
    branch: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        if (self.branch) |branch| allocator.free(branch);
        self.* = undefined;
    }
};

/// Uses raw pipe/fork instead of std.process.spawn(Io) so C-opened PTY fds are not reused.
pub fn refresh(allocator: std.mem.Allocator, workspace_path: []const u8) !Status {
    const output = runCapture(allocator, workspace_path, &.{
        "git", "status", "--porcelain=v1", "-b",
    }) catch return .{ .entries = &.{}, .is_repo = false };
    defer allocator.free(output);

    if (output.len == 0) {
        const is_repo = runExitCode(workspace_path, &.{ "git", "rev-parse", "--is-inside-work-tree" }) == 0;
        return .{ .entries = &.{}, .is_repo = is_repo };
    }

    var branch: ?[]const u8 = null;
    var ahead: u32 = 0;
    var behind: u32 = 0;

    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |*entry| entry.deinit(allocator);
        list.deinit(allocator);
        if (branch) |name| allocator.free(name);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            parseBranchLine(allocator, line[3..], &branch, &ahead, &behind) catch {};
            continue;
        }
        if (line.len < 4) continue;
        const status: [2]u8 = .{ line[0], line[1] };
        const path = std.mem.trim(u8, line[3..], " \t\r");
        if (path.len == 0) continue;
        try list.append(allocator, .{
            .status = status,
            .path = try allocator.dupe(u8, path),
        });
    }

    return .{
        .entries = try list.toOwnedSlice(allocator),
        .is_repo = true,
        .branch = branch,
        .ahead = ahead,
        .behind = behind,
    };
}

fn runCapture(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const result = try process_spawn.runCapture(allocator, args, .{ .cwd = cwd });
    defer allocator.free(result.output);
    return try allocator.dupe(u8, result.output);
}

fn runExitCode(cwd: []const u8, args: []const []const u8) i32 {
    const allocator = std.heap.page_allocator;
    return process_spawn.runWait(allocator, args, .{ .cwd = cwd }) catch -1;
}

fn parseBranchLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    branch_out: *?[]const u8,
    ahead_out: *u32,
    behind_out: *u32,
) !void {
    if (std.mem.startsWith(u8, line, "HEAD (no branch)")) return;

    const branch_name = blk: {
        if (std.mem.indexOf(u8, line, "...")) |idx| break :blk std.mem.trim(u8, line[0..idx], " \t");
        if (std.mem.indexOfScalar(u8, line, ' ')) |idx| break :blk std.mem.trim(u8, line[0..idx], " \t");
        break :blk std.mem.trim(u8, line, " \t");
    };
    if (branch_name.len == 0) return;

    branch_out.* = try allocator.dupe(u8, branch_name);

    if (std.mem.indexOf(u8, line, "[ahead ")) |start| {
        const num_start = start + "[ahead ".len;
        const rest = line[num_start..];
        const num_end = std.mem.indexOfScalar(u8, rest, ']') orelse rest.len;
        ahead_out.* = std.fmt.parseInt(u32, std.mem.trim(u8, rest[0..num_end], " ,"), 10) catch 0;
    }
    if (std.mem.indexOf(u8, line, "behind ")) |start| {
        const num_start = start + "behind ".len;
        const rest = line[num_start..];
        const num_end = std.mem.indexOfScalar(u8, rest, ',') orelse std.mem.indexOfScalar(u8, rest, ']') orelse rest.len;
        behind_out.* = std.fmt.parseInt(u32, std.mem.trim(u8, rest[0..num_end], " ,"), 10) catch 0;
    }
}

test "parse porcelain line" {
    const allocator = std.testing.allocator;
    var status = refresh(allocator, ".") catch .{ .entries = &.{}, .is_repo = false };
    defer status.deinit(allocator);
    _ = status.is_repo;
}

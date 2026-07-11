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

    pub fn isStaged(self: Entry) bool {
        return self.status[0] != ' ' and self.status[0] != '?';
    }

    pub fn isUnstaged(self: Entry) bool {
        return self.status[1] != ' ' or self.status[0] == '?';
    }
};

pub const Status = struct {
    entries: []Entry,
    staged_ptrs: []*const Entry,
    unstaged_ptrs: []*const Entry,
    directory_status: std.StringHashMap([2]u8),
    is_repo: bool,
    branch: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        allocator.free(self.staged_ptrs);
        allocator.free(self.unstaged_ptrs);
        var dir_it = self.directory_status.iterator();
        while (dir_it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.directory_status.deinit();
        if (self.branch) |branch| allocator.free(branch);
        self.* = undefined;
    }

    /// Returns the first entry that starts with `path`. Since entries are sorted,
    /// if `path` is a directory (e.g. "src/"), this finds the first file inside it.
    /// If `path` is a file, this finds the exact match if it exists.
    pub fn findFirstStartingWith(self: *const Status, path: []const u8) ?usize {
        var l: usize = 0;
        var r: usize = self.entries.len;
        while (l < r) {
            const m = l + (r - l) / 2;
            const entry_path = self.entries[m].path;
            const cmp_len = @min(entry_path.len, path.len);
            const ord = std.mem.order(u8, entry_path[0..cmp_len], path);
            switch (ord) {
                .lt => l = m + 1,
                .gt => r = m,
                .eq => {
                    if (entry_path.len < path.len) {
                        l = m + 1;
                    } else {
                        // We found a prefix match, but it might not be the *first* one.
                        // So we continue searching to the left.
                        r = m;
                    }
                },
            }
        }
        if (l < self.entries.len and std.mem.startsWith(u8, self.entries[l].path, path)) {
            return l;
        }
        return null;
    }

    pub fn directoryAggregate(self: *const Status, path: []const u8) ?[2]u8 {
        var trimmed = path;
        while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '/' or trimmed[trimmed.len - 1] == '\\')) {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
        return self.directory_status.get(trimmed);
    }
};

fn emptyStatus(allocator: std.mem.Allocator, is_repo: bool) Status {
    return .{
        .entries = &.{},
        .staged_ptrs = &.{},
        .unstaged_ptrs = &.{},
        .directory_status = std.StringHashMap([2]u8).init(allocator),
        .is_repo = is_repo,
    };
}

/// Uses raw pipe/fork instead of std.process.spawn(Io) so C-opened PTY fds are not reused.
pub fn refresh(allocator: std.mem.Allocator, workspace_path: []const u8) !Status {
    const output = runCapture(allocator, workspace_path, &.{
        "git", "status", "--porcelain=v1", "-b",
    }) catch return emptyStatus(allocator, false);
    defer allocator.free(output);

    if (output.len == 0) {
        const is_repo = runExitCode(workspace_path, &.{ "git", "rev-parse", "--is-inside-work-tree" }) == 0;
        return emptyStatus(allocator, is_repo);
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

    const entries = try list.toOwnedSlice(allocator);

    std.sort.pdq(Entry, entries, {}, struct {
        pub fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);

    var staged_ptrs: std.ArrayList(*const Entry) = .empty;
    var unstaged_ptrs: std.ArrayList(*const Entry) = .empty;
    for (entries) |*entry| {
        if (entry.isStaged()) try staged_ptrs.append(allocator, entry);
        if (entry.isUnstaged()) try unstaged_ptrs.append(allocator, entry);
    }

    var directory_status = std.StringHashMap([2]u8).init(allocator);
    errdefer {
        var dir_it = directory_status.iterator();
        while (dir_it.next()) |entry| allocator.free(entry.key_ptr.*);
        directory_status.deinit();
    }
    try buildDirectoryStatus(allocator, &directory_status, entries);

    return .{
        .entries = entries,
        .staged_ptrs = try staged_ptrs.toOwnedSlice(allocator),
        .unstaged_ptrs = try unstaged_ptrs.toOwnedSlice(allocator),
        .directory_status = directory_status,
        .is_repo = true,
        .branch = branch,
        .ahead = ahead,
        .behind = behind,
    };
}

fn mergeStatus(current: [2]u8, next: [2]u8) [2]u8 {
    var out = current;
    if (out[0] == ' ' or out[0] == 0) out[0] = next[0];
    if (out[1] == ' ' or out[1] == 0) out[1] = next[1];
    if (next[0] == '?' or next[1] == '?') out = .{ '?', '?' };
    if (next[0] == 'U' or next[1] == 'U') out = .{ 'U', 'U' };
    return out;
}

fn addDirectoryAggregate(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([2]u8),
    path: []const u8,
    status: [2]u8,
) !void {
    const owned = try allocator.dupe(u8, path);
    const gop = try map.getOrPut(owned);
    if (gop.found_existing) {
        allocator.free(owned);
        gop.value_ptr.* = mergeStatus(gop.value_ptr.*, status);
        return;
    }
    gop.value_ptr.* = status;
}

fn buildDirectoryStatus(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([2]u8),
    entries: []const Entry,
) !void {
    for (entries) |entry| {
        var slash_pos = std.mem.indexOfScalar(u8, entry.path, '/') orelse continue;
        while (true) {
            if (slash_pos > 0) try addDirectoryAggregate(allocator, map, entry.path[0..slash_pos], entry.status);
            slash_pos = std.mem.indexOfScalarPos(u8, entry.path, slash_pos + 1, '/') orelse break;
        }
    }
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

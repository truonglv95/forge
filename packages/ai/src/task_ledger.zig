const std = @import("std");

pub const Phase = enum {
    planning,
    gathering,
    editing,
    validating,
    repairing,
    summarizing,
    completed,
    blocked,
};

pub const EntryKind = enum {
    goal,
    assumption,
    file_read,
    file_edited,
    search,
    command,
    validation,
    blocker,
    decision,
    context_compaction,
};

pub const StepInput = struct {
    index: u32,
    kind: []const u8,
    summary: []const u8,
};

pub const Entry = struct {
    kind: EntryKind,
    step_index: u32 = 0,
    path: []const u8 = "",
    text: []const u8,
};

pub const Snapshot = struct {
    phase: Phase,
    goal: []const u8,
    entries: []Entry,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.goal);
        for (self.entries) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.text);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub fn fromSteps(
    allocator: std.mem.Allocator,
    goal: []const u8,
    steps: []const StepInput,
    phase: Phase,
) !Snapshot {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.text);
        }
        entries.deinit(allocator);
    }

    try entries.append(allocator, .{
        .kind = .goal,
        .text = try allocator.dupe(u8, goal),
    });

    for (steps) |step| {
        const classified = classifyStep(step.kind, step.summary);
        const path = extractBacktickValue(allocator, step.summary) catch try allocator.dupe(u8, "");
        errdefer allocator.free(path);
        try entries.append(allocator, .{
            .kind = classified,
            .step_index = step.index,
            .path = path,
            .text = try allocator.dupe(u8, trimWhitespace(step.summary)),
        });
    }

    return .{
        .phase = phase,
        .goal = try allocator.dupe(u8, goal),
        .entries = try entries.toOwnedSlice(allocator),
    };
}

pub fn toJsonAlloc(allocator: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, snapshot, .{});
}

pub fn formatMarkdown(
    allocator: std.mem.Allocator,
    snapshot: Snapshot,
    max_entries: usize,
    max_entry_bytes: usize,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.print("Task ledger\nPhase: {s}\nGoal: {s}\n", .{ @tagName(snapshot.phase), snapshot.goal });
    if (snapshot.entries.len == 0) return try out.toOwnedSlice();

    try writer.writeAll("Recent state:\n");
    const start = if (snapshot.entries.len > max_entries) snapshot.entries.len - max_entries else 0;
    if (start > 0) try writer.print("- ... {d} older ledger entrie(s) compacted\n", .{start});
    for (snapshot.entries[start..]) |entry| {
        if (entry.kind == .goal) continue;
        const text = trimTail(entry.text, max_entry_bytes);
        if (entry.path.len > 0) {
            try writer.print("- #{d} {s} `{s}`: {s}\n", .{ entry.step_index, @tagName(entry.kind), entry.path, text });
        } else if (entry.step_index > 0) {
            try writer.print("- #{d} {s}: {s}\n", .{ entry.step_index, @tagName(entry.kind), text });
        } else {
            try writer.print("- {s}: {s}\n", .{ @tagName(entry.kind), text });
        }
    }
    return try out.toOwnedSlice();
}

pub fn classifyStep(kind: []const u8, summary: []const u8) EntryKind {
    if (containsAny(summary, &.{ "failed", "error", "could not", "invalid JSON" })) return .blocker;
    if (containsAny(kind, &.{ "replace_file_content", "write_file", "apply_proposal", "propose", "Write" })) return .file_edited;
    if (containsAny(kind, &.{ "read_file", "Read", "file" })) return .file_read;
    if (containsAny(kind, &.{ "grep", "search", "list_tree", "Tree" })) return .search;
    if (containsAny(kind, &.{ "run_command", "Run" })) return .command;
    if (containsAny(kind, &.{ "validate", "test", "diagnostic" })) return .validation;
    return .decision;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn extractBacktickValue(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const first = std.mem.indexOfScalar(u8, text, '`') orelse return allocator.dupe(u8, "");
    const rest = text[first + 1 ..];
    const second_rel = std.mem.indexOfScalar(u8, rest, '`') orelse return allocator.dupe(u8, "");
    return allocator.dupe(u8, rest[0..second_rel]);
}

fn trimWhitespace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

pub fn trimTail(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    return text[text.len - max_bytes ..];
}

test "ledger classifies file reads and writes" {
    const allocator = std.testing.allocator;
    const steps = [_]StepInput{
        .{ .index = 1, .kind = "read_file", .summary = "Read `src/main.zig` lines 1-40" },
        .{ .index = 2, .kind = "replace_file_content", .summary = "Write `src/main.zig`: add resume support" },
    };
    var snapshot = try fromSteps(allocator, "fix resume", &steps, .editing);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(EntryKind.goal, snapshot.entries[0].kind);
    try std.testing.expectEqual(EntryKind.file_read, snapshot.entries[1].kind);
    try std.testing.expectEqual(EntryKind.file_edited, snapshot.entries[2].kind);
    try std.testing.expectEqualStrings("src/main.zig", snapshot.entries[1].path);
}

test "ledger markdown compacts older entries" {
    const allocator = std.testing.allocator;
    const steps = [_]StepInput{
        .{ .index = 1, .kind = "grep", .summary = "Grep `agent` in `.`: 10 hit(s)" },
        .{ .index = 2, .kind = "read_file", .summary = "Read `src/a.zig`" },
        .{ .index = 3, .kind = "read_file", .summary = "Read `src/b.zig`" },
    };
    var snapshot = try fromSteps(allocator, "audit agent", &steps, .gathering);
    defer snapshot.deinit(allocator);
    const text = try formatMarkdown(allocator, snapshot, 2, 64);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "older ledger") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/b.zig") != null);
}

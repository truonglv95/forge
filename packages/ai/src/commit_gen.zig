//! AI Commit Message Generation — generates conventional commit messages from git diff.
const std = @import("std");

pub const CommitType = enum {
    feat, // New feature
    fix, // Bug fix
    docs, // Documentation
    style, // Formatting
    refactor, // Code restructuring
    perf, // Performance
    @"test", // Tests
    chore, // Build/tooling
    ci, // CI changes

    pub fn label(self: CommitType) []const u8 {
        return switch (self) {
            .feat => "feat",
            .fix => "fix",
            .docs => "docs",
            .style => "style",
            .refactor => "refactor",
            .perf => "perf",
            .@"test" => "test",
            .chore => "chore",
            .ci => "ci",
        };
    }
};

pub const CommitMessage = struct {
    type: CommitType,
    scope: ?[]const u8 = null,
    description: []const u8,
    body: ?[]const u8 = null,

    pub fn format(self: CommitMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, self.type.label());
        if (self.scope) |scope| {
            try buf.append(allocator, '(');
            try buf.appendSlice(allocator, scope);
            try buf.append(allocator, ')');
        }
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, self.description);

        if (self.body) |body| {
            try buf.appendSlice(allocator, "\n\n");
            try buf.appendSlice(allocator, body);
        }

        return buf.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *CommitMessage, allocator: std.mem.Allocator) void {
        if (self.scope) |s| allocator.free(s);
        allocator.free(self.description);
        if (self.body) |b| allocator.free(b);
    }
};

/// Generate a commit message from a git diff using heuristics.
/// For AI-powered generation, the agent can analyze the diff with an LLM.
pub fn generateCommitMessage(
    allocator: std.mem.Allocator,
    diff: []const u8,
) !CommitMessage {
    // Analyze the diff to determine type and scope
    const commit_type = classifyDiff(diff);

    // Extract scope from file paths
    const scope = extractScope(allocator, diff) catch null;

    // Generate description from changes
    const description = try generateDescription(allocator, diff, commit_type);

    return .{
        .type = commit_type,
        .scope = scope,
        .description = description,
    };
}

fn classifyDiff(diff: []const u8) CommitType {
    // Count added/removed lines
    var added: usize = 0;
    var removed: usize = 0;
    var new_files: usize = 0;
    var test_files: usize = 0;

    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) {
            new_files += 1;
            if (std.mem.indexOf(u8, line, "test") != null or
                std.mem.indexOf(u8, line, "spec") != null)
            {
                test_files += 1;
            }
        }
        if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) added += 1;
        if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) removed += 1;
    }

    // All test files → test
    if (test_files == new_files and new_files > 0) return .@"test";

    // Mostly new code → feat
    if (added > removed * 3 and added > 10) return .feat;

    // More removed than added → refactor
    if (removed > added) return .refactor;

    // Small changes → fix
    if (added + removed < 20) return .fix;

    // Default
    return .chore;
}

fn extractScope(allocator: std.mem.Allocator, diff: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) {
            const path = line[6..];
            // Extract directory or module name as scope
            if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
                const dir = path[0..slash];
                if (dir.len > 0 and dir.len < 30) {
                    return try allocator.dupe(u8, dir);
                }
            }
        }
    }
    return null;
}

fn generateDescription(allocator: std.mem.Allocator, diff: []const u8, commit_type: CommitType) ![]u8 {
    // Extract the most significant added line (first non-trivial addition)
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
            const added = std.mem.trim(u8, line[1..], &std.ascii.whitespace);
            if (added.len > 5 and added.len < 80) {
                // Use first meaningful addition as description basis
                const prefix = switch (commit_type) {
                    .feat => "add",
                    .fix => "fix",
                    .refactor => "refactor",
                    .@"test" => "add tests for",
                    .docs => "document",
                    else => "update",
                };
                return std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, added });
            }
        }
    }

    // Fallback
    return allocator.dupe(u8, "update code");
}

test "classifyDiff detects feature" {
    const diff =
        \\+++ b/new_feature.zig
        \\+pub fn newFeature() void {
        \\+    // lots of new code
        \\+    const x = 42;
        \\+    const y = processX(x);
        \\+    const z = transformY(y);
        \\+    const a = computeA(z);
        \\+    const b = computeB(a);
        \\+    const c = computeC(b);
        \\+    const d = computeD(c);
        \\+    const e = computeE(d);
        \\+    const result = finalize(e);
        \\+    return result;
        \\+}
    ;
    try std.testing.expectEqual(CommitType.feat, classifyDiff(diff));
}

test "classifyDiff detects test" {
    const diff =
        \\+++ b/test_main.zig
        \\+test "something works" {
        \\+    try std.testing.expect(true);
        \\+}
    ;
    try std.testing.expectEqual(CommitType.@"test", classifyDiff(diff));
}

test "generateCommitMessage produces valid format" {
    const allocator = std.testing.allocator;
    const diff =
        \\+++ b/editor/main.zig
        \\+pub fn newEditorFeature() void {
        \\+    // implementation
        \\+}
    ;
    var msg = try generateCommitMessage(allocator, diff);
    defer msg.deinit(allocator);
    const formatted = try msg.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, ":") != null);
}

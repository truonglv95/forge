//! Code Review Agent — analyzes git diff and generates review comments.
const std = @import("std");

pub const ReviewSeverity = enum {
    critical, // bugs, security issues
    warning, // potential issues
    suggestion, // improvements
    nitpick, // style preferences
};

pub const ReviewComment = struct {
    file_path: []const u8,
    line: u32,
    severity: ReviewSeverity,
    category: []const u8, // "bug", "security", "performance", "style"
    message: []const u8,
    suggestion: ?[]const u8 = null, // suggested fix

    pub fn deinit(self: *ReviewComment, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.category);
        allocator.free(self.message);
        if (self.suggestion) |s| allocator.free(s);
    }
};

pub const ReviewResult = struct {
    comments: []ReviewComment,
    summary: []const u8,
    overall_score: u8, // 0-100

    pub fn deinit(self: *ReviewResult, allocator: std.mem.Allocator) void {
        for (self.comments) |*c| c.deinit(allocator);
        allocator.free(self.comments);
        allocator.free(self.summary);
    }
};

/// Analyze a diff and generate review comments. This is a heuristic-based
/// analyzer that checks for common issues without requiring an LLM call.
/// For AI-powered review, the agent can use this as a pre-filter and then
/// send relevant chunks to the LLM for deeper analysis.
pub fn analyzeDiff(
    allocator: std.mem.Allocator,
    diff_content: []const u8,
) !ReviewResult {
    var comments: std.ArrayList(ReviewComment) = .empty;
    errdefer {
        for (comments.items) |*c| c.deinit(allocator);
        comments.deinit(allocator);
    }

    var current_file: ?[]const u8 = null;
    var current_line: u32 = 0;

    var lines = std.mem.splitScalar(u8, diff_content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) {
            current_file = line[6..];
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@")) {
            // Parse line number from hunk header
            if (std.mem.indexOf(u8, line, "+")) |pos| {
                const rest = line[pos + 1 ..];
                if (std.mem.indexOfScalar(u8, rest, ',')) |comma| {
                    current_line = std.fmt.parseInt(u32, rest[0..comma], 10) catch 0;
                } else {
                    current_line = std.fmt.parseInt(u32, rest, 10) catch 0;
                }
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
            const added = line[1..];
            const file = current_file orelse "";

            // Check for common issues
            if (checkSecretLeak(added)) {
                try comments.append(allocator, .{
                    .file_path = try allocator.dupe(u8, file),
                    .line = current_line,
                    .severity = .critical,
                    .category = try allocator.dupe(u8, "security"),
                    .message = try allocator.dupe(u8, "Possible secret/credential in code. Avoid hardcoding API keys, passwords, or tokens."),
                });
            }
            if (checkTodoFixme(added)) {
                try comments.append(allocator, .{
                    .file_path = try allocator.dupe(u8, file),
                    .line = current_line,
                    .severity = .suggestion,
                    .category = try allocator.dupe(u8, "style"),
                    .message = try allocator.dupe(u8, "TODO/FIXME left in code. Consider creating an issue or resolving before merge."),
                });
            }
            if (checkDebugPrint(added)) {
                try comments.append(allocator, .{
                    .file_path = try allocator.dupe(u8, file),
                    .line = current_line,
                    .severity = .warning,
                    .category = try allocator.dupe(u8, "style"),
                    .message = try allocator.dupe(u8, "Debug print statement detected. Remove before production."),
                });
            }
            if (checkLongLine(added)) {
                try comments.append(allocator, .{
                    .file_path = try allocator.dupe(u8, file),
                    .line = current_line,
                    .severity = .nitpick,
                    .category = try allocator.dupe(u8, "style"),
                    .message = try allocator.dupe(u8, "Line exceeds 120 characters. Consider wrapping for readability."),
                });
            }
            current_line += 1;
        } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
            // Deleted line — don't increment current_line
        } else if (!std.mem.startsWith(u8, line, "\\") and line.len > 0) {
            current_line += 1;
        }
    }

    const critical_count = countSeverity(comments.items, .critical);
    const warning_count = countSeverity(comments.items, .warning);
    const score: u8 = if (critical_count > 0)
        @min(100, critical_count * 20)
    else
        @max(0, 100 - @as(u8, @intCast(warning_count * 5)));

    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{d} comments: {d} critical, {d} warnings, {d} suggestions", .{
        comments.items.len,
        critical_count,
        warning_count,
        countSeverity(comments.items, .suggestion),
    }) catch "Review complete";

    return .{
        .comments = try comments.toOwnedSlice(allocator),
        .summary = try allocator.dupe(u8, summary),
        .overall_score = score,
    };
}

fn countSeverity(comments: []const ReviewComment, severity: ReviewSeverity) usize {
    var count: usize = 0;
    for (comments) |c| {
        if (c.severity == severity) count += 1;
    }
    return count;
}

fn checkSecretLeak(line: []const u8) bool {
    const patterns = [_][]const u8{
        "api_key",  "apikey",   "API_KEY",
        "password", "PASSWORD", "passwd",
        "secret",   "SECRET",   "token",
        "TOKEN",    "Bearer ",  "sk-",
        "ghp_",
    };
    for (patterns) |p| {
        if (std.mem.indexOf(u8, line, p) != null) return true;
    }
    return false;
}

fn checkTodoFixme(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "TODO") != null or
        std.mem.indexOf(u8, line, "FIXME") != null or
        std.mem.indexOf(u8, line, "HACK") != null;
}

fn checkDebugPrint(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "console.log") != null or
        std.mem.indexOf(u8, line, "print(") != null or
        std.mem.indexOf(u8, line, "debug.print") != null or
        std.mem.indexOf(u8, line, "System.out.print") != null;
}

fn checkLongLine(line: []const u8) bool {
    return line.len > 120;
}

test "analyzeDiff detects secrets" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/main.zig b/main.zig
        \\+++ b/main.zig
        \\@@ -1,3 +1,4 @@
        \\ const std = @import("std");
        \\+const api_key = "sk-test123";
        \\ pub fn main() void {}
    ;
    var result = try analyzeDiff(allocator, diff);
    defer result.deinit(allocator);
    try std.testing.expect(result.comments.len >= 1);
    try std.testing.expectEqual(ReviewSeverity.critical, result.comments[0].severity);
}

test "analyzeDiff detects TODO" {
    const allocator = std.testing.allocator;
    const diff =
        \\diff --git a/main.zig b/main.zig
        \\+++ b/main.zig
        \\@@ -1,3 +1,4 @@
        \\ const std = @import("std");
        \\+// TODO: implement this
        \\ pub fn main() void {}
    ;
    var result = try analyzeDiff(allocator, diff);
    defer result.deinit(allocator);
    try std.testing.expect(result.comments.len >= 1);
    try std.testing.expectEqual(ReviewSeverity.suggestion, result.comments[0].severity);
}

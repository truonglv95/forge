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

/// LLM-powered code review. Uses the heuristic analyzer as a pre-filter
/// to identify suspicious hunks (secret leaks, TODOs, debug prints, long
/// lines), then sends those hunks to the LLM for deeper analysis.
///
/// The LLM is asked to act as a senior code reviewer and identify:
/// - Bugs and logic errors
/// - Security vulnerabilities
/// - Performance issues
/// - Style/maintainability improvements
///
/// Returns a combined ReviewResult with both heuristic and LLM comments.
/// If the LLM call fails, returns only the heuristic comments (graceful
/// degradation).
pub fn reviewWithLlm(
    allocator: std.mem.Allocator,
    io: std.Io,
    diff_content: []const u8,
    provider: anytype,
    cancel_token: ?*const @import("forge-kernel").cancellation.CancellationToken,
) !ReviewResult {
    _ = io; // Reserved for future file I/O (e.g. reading full file context).
    // Step 1: Run heuristic analysis first (fast, no LLM call).
    var heuristic_result = try analyzeDiff(allocator, diff_content);
    errdefer heuristic_result.deinit(allocator);

    // Step 2: Build the LLM prompt with the diff and heuristic findings.
    var prompt_buf: std.ArrayList(u8) = .empty;
    defer prompt_buf.deinit(allocator);
    try prompt_buf.appendSlice(allocator, "You are a senior code reviewer. Analyze the following git diff and provide review comments.\n\n");
    try prompt_buf.appendSlice(allocator, "For each issue found, output a line in this format:\n");
    try prompt_buf.appendSlice(allocator, "[severity] file:line - category: message\n\n");
    try prompt_buf.appendSlice(allocator, "Severities: critical, warning, suggestion, nitpick\n");
    try prompt_buf.appendSlice(allocator, "Categories: bug, security, performance, style, maintainability\n\n");
    try prompt_buf.appendSlice(allocator, "Heuristic pre-filter findings (verify and expand these):\n");
    var findings_buf: [512]u8 = undefined;
    const findings_text = std.fmt.bufPrint(&findings_buf, "  {d} heuristic findings (secrets, TODOs, debug prints, long lines)\n\n", .{heuristic_result.comments.len}) catch "  (heuristic findings below)\n\n";
    try prompt_buf.appendSlice(allocator, findings_text);
    try prompt_buf.appendSlice(allocator, "Diff to review:\n```\n");
    // Truncate very long diffs to avoid token limits.
    const max_diff_bytes = 16 * 1024;
    if (diff_content.len > max_diff_bytes) {
        try prompt_buf.appendSlice(allocator, diff_content[0..max_diff_bytes]);
        try prompt_buf.appendSlice(allocator, "\n... (diff truncated, ");
        var trunc_buf: [32]u8 = undefined;
        const trunc_text = std.fmt.bufPrint(&trunc_buf, "{d}", .{diff_content.len}) catch "?";
        try prompt_buf.appendSlice(allocator, trunc_text);
        try prompt_buf.appendSlice(allocator, " bytes total)\n");
    } else {
        try prompt_buf.appendSlice(allocator, diff_content);
    }
    try prompt_buf.appendSlice(allocator, "\n```\n\nProvide your review comments now.");

    // Step 3: Call the LLM via the provider's streaming ask interface.
    // If cancel_token is null, we still need a non-null pointer for the
    // provider API. Create a dummy token that is never cancelled.
    var dummy_state = std.atomic.Value(bool).init(false);
    var dummy_token: @import("forge-kernel").cancellation.CancellationToken = .{ .shared_state = &dummy_state };
    const token_ptr = cancel_token orelse &dummy_token;

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();
    const images = [_]@import("provider.zig").ImagePart{};
    provider.ask(
        allocator,
        prompt_buf.items,
        &images,
        &response_alloc.writer,
        token_ptr,
    ) catch {
        // LLM call failed — return heuristic-only result (graceful degradation).
        return heuristic_result;
    };
    const llm_output = response_alloc.writer.buffer[0..response_alloc.writer.end];

    // Step 4: Parse LLM output and append comments to the result.
    // We look for lines matching "[severity] file:line - category: message".
    var llm_comments: std.ArrayList(ReviewComment) = .empty;
    errdefer {
        for (llm_comments.items) |*c| c.deinit(allocator);
        llm_comments.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, llm_output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] != '[') continue;
        const close_bracket = std.mem.indexOfScalar(u8, trimmed, ']') orelse continue;
        const severity_str = trimmed[1..close_bracket];
        const rest = std.mem.trim(u8, trimmed[close_bracket + 1 ..], " \t");
        if (rest.len == 0) continue;

        const severity: ReviewSeverity = if (std.mem.eql(u8, severity_str, "critical"))
            .critical
        else if (std.mem.eql(u8, severity_str, "warning"))
            .warning
        else if (std.mem.eql(u8, severity_str, "suggestion"))
            .suggestion
        else if (std.mem.eql(u8, severity_str, "nitpick"))
            .nitpick
        else
            .suggestion;

        // Parse "file:line - category: message"
        const dash_pos = std.mem.indexOf(u8, rest, " - ") orelse continue;
        const file_line = rest[0..dash_pos];
        const msg_part = rest[dash_pos + 3 ..];
        const colon_pos = std.mem.indexOfScalar(u8, file_line, ':') orelse continue;
        const file = file_line[0..colon_pos];
        const line_num = std.fmt.parseInt(u32, file_line[colon_pos + 1 ..], 10) catch 0;

        const cat_colon = std.mem.indexOfScalar(u8, msg_part, ':') orelse continue;
        const category = msg_part[0..cat_colon];
        const message = std.mem.trim(u8, msg_part[cat_colon + 1 ..], " \t");

        try llm_comments.append(allocator, .{
            .file_path = try allocator.dupe(u8, file),
            .line = line_num,
            .severity = severity,
            .category = try allocator.dupe(u8, category),
            .message = try allocator.dupe(u8, message),
        });
    }

    // Merge LLM comments into the heuristic result.
    var merged: std.ArrayList(ReviewComment) = .empty;
    errdefer {
        for (merged.items) |*c| c.deinit(allocator);
        merged.deinit(allocator);
    }
    try merged.appendSlice(allocator, heuristic_result.comments);
    heuristic_result.comments = &.{};
    try merged.appendSlice(allocator, llm_comments.items);
    llm_comments.items = &.{};
    llm_comments.deinit(allocator);

    allocator.free(heuristic_result.comments);
    allocator.free(heuristic_result.summary);
    return .{
        .comments = try merged.toOwnedSlice(allocator),
        .summary = try allocator.dupe(u8, "Heuristic + LLM review completed"),
        .overall_score = heuristic_result.overall_score,
    };
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

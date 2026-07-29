//! AI-Powered Refactoring — extract functions, rename, convert patterns.
const std = @import("std");

pub const RefactorType = enum {
    extract_function,
    extract_variable,
    rename_symbol,
    convert_pattern,
    generate_tests,
    add_error_handling,
    simplify_conditionals,
};

pub const RefactorSuggestion = struct {
    refactor_type: RefactorType,
    description: []const u8,
    diff: []const u8, // unified diff of the proposed change
    confidence: f32,

    pub fn deinit(self: *RefactorSuggestion, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        allocator.free(self.diff);
    }
};

/// Suggest refactoring opportunities for a piece of code.
/// Uses heuristics to detect common anti-patterns.
pub fn suggestRefactors(
    allocator: std.mem.Allocator,
    code: []const u8,
    file_path: []const u8,
) ![]RefactorSuggestion {
    var suggestions: std.ArrayList(RefactorSuggestion) = .empty;
    errdefer {
        for (suggestions.items) |*s| s.deinit(allocator);
        suggestions.deinit(allocator);
    }

    // Check for long functions (extract function candidate)
    const line_count = countLines(code);
    if (line_count > 50) {
        try suggestions.append(allocator, .{
            .refactor_type = .extract_function,
            .description = try std.fmt.allocPrint(allocator, "Function is {d} lines long. Consider extracting sub-functions for readability.", .{line_count}),
            .diff = try allocator.dupe(u8, ""),
            .confidence = 0.6,
        });
    }

    // Check for deep nesting (simplify conditionals candidate)
    const max_depth = maxNestingDepth(code);
    if (max_depth > 4) {
        try suggestions.append(allocator, .{
            .refactor_type = .simplify_conditionals,
            .description = try std.fmt.allocPrint(allocator, "Nesting depth is {d}. Consider early returns or guard clauses.", .{max_depth}),
            .diff = try allocator.dupe(u8, ""),
            .confidence = 0.7,
        });
    }

    // Check for repeated code patterns (extract function candidate)
    const repeated = detectRepeatedPatterns(code);
    if (repeated > 0) {
        try suggestions.append(allocator, .{
            .refactor_type = .extract_function,
            .description = try std.fmt.allocPrint(allocator, "Detected {d} repeated code patterns. Consider extracting to a shared function.", .{repeated}),
            .diff = try allocator.dupe(u8, ""),
            .confidence = 0.5,
        });
    }

    // Check for missing error handling
    const missing_error_handling = detectMissingErrorHandling(code);
    if (missing_error_handling) {
        try suggestions.append(allocator, .{
            .refactor_type = .add_error_handling,
            .description = try allocator.dupe(u8, "Detected operations that may need error handling (file I/O, network, parsing)."),
            .diff = try allocator.dupe(u8, ""),
            .confidence = 0.4,
        });
    }

    _ = file_path; // Used by AI-enhanced version
    return suggestions.toOwnedSlice(allocator);
}

fn countLines(text: []const u8) usize {
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn maxNestingDepth(code: []const u8) usize {
    var depth: usize = 0;
    var max: usize = 0;
    for (code) |c| {
        if (c == '{') {
            depth += 1;
            if (depth > max) max = depth;
        } else if (c == '}') {
            if (depth > 0) depth -= 1;
        }
    }
    return max;
}

fn detectRepeatedPatterns(code: []const u8) usize {
    // Simple heuristic: count duplicate 3-line sequences
    var lines = std.mem.splitScalar(u8, code, '\n');
    var line_list: std.ArrayList([]const u8) = .empty;
    defer line_list.deinit(std.heap.page_allocator);
    while (lines.next()) |line| {
        line_list.append(std.heap.page_allocator, std.mem.trim(u8, line, " \t")) catch {};
    }

    if (line_list.items.len < 6) return 0;

    var repeated: usize = 0;
    var i: usize = 0;
    while (i + 3 < line_list.items.len) : (i += 1) {
        const seq = line_list.items[i .. i + 3];
        var j: usize = i + 3;
        while (j + 3 < line_list.items.len) : (j += 1) {
            const other = line_list.items[j .. j + 3];
            if (seq.len == other.len and
                std.mem.eql(u8, seq[0], other[0]) and
                std.mem.eql(u8, seq[1], other[1]) and
                std.mem.eql(u8, seq[2], other[2]) and
                seq[0].len > 0)
            {
                repeated += 1;
                break;
            }
        }
    }
    return repeated;
}

fn detectMissingErrorHandling(code: []const u8) bool {
    // Check for try/catch/expect patterns vs risky operations
    const has_risky = std.mem.indexOf(u8, code, "openFile") != null or
        std.mem.indexOf(u8, code, "readFile") != null or
        std.mem.indexOf(u8, code, "writeFile") != null or
        std.mem.indexOf(u8, code, "fetch(") != null or
        std.mem.indexOf(u8, code, "http.") != null;

    const has_handling = std.mem.indexOf(u8, code, "try") != null or
        std.mem.indexOf(u8, code, "catch") != null or
        std.mem.indexOf(u8, code, "expectError") != null or
        std.mem.indexOf(u8, code, "if (err") != null;

    return has_risky and !has_handling;
}

test "countLines" {
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
    try std.testing.expectEqual(@as(usize, 1), countLines("single"));
}

test "maxNestingDepth" {
    try std.testing.expectEqual(@as(usize, 3), maxNestingDepth("fn() { if (x) { if (y) { } } }"));
}

test "suggestRefactors detects long function" {
    const allocator = std.testing.allocator;
    var long_code: std.ArrayList(u8) = .empty;
    defer long_code.deinit(allocator);
    for (0..60) |_| {
        try long_code.appendSlice(allocator, "x\n{}\n");
    }
    const suggestions = try suggestRefactors(allocator, long_code.items, "test.zig");
    defer {
        for (suggestions) |*s| s.deinit(allocator);
        allocator.free(suggestions);
    }
    try std.testing.expect(suggestions.len > 0);
}

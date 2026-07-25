//! AI-Powered Debugging — analyzes errors/crashes and suggests fixes.
const std = @import("std");

pub const DebugSuggestion = struct {
    error_type: ErrorType,
    root_cause: []const u8,
    suggested_fix: []const u8,
    confidence: f32, // 0.0 - 1.0

    pub fn deinit(self: *DebugSuggestion, allocator: std.mem.Allocator) void {
        allocator.free(self.root_cause);
        allocator.free(self.suggested_fix);
    }
};

pub const ErrorType = enum {
    null_pointer,
    out_of_bounds,
    type_mismatch,
    stack_overflow,
    memory_leak,
    deadlock,
    assertion_failure,
    segfault,
    timeout,
    unknown,
};

/// Analyze an error message or stack trace and suggest a fix.
/// This uses heuristic pattern matching. For AI-powered analysis,
/// the agent can send the error + relevant code to an LLM.
pub fn analyzeError(
    allocator: std.mem.Allocator,
    error_text: []const u8,
) !DebugSuggestion {
    const error_type = classifyError(error_text);

    return switch (error_type) {
        .null_pointer => .{
            .error_type = .null_pointer,
            .root_cause = try allocator.dupe(u8, "A null or uninitialized pointer was dereferenced."),
            .suggested_fix = try allocator.dupe(u8, "Check for null before dereferencing. Add null checks or use optional types. Verify initialization order."),
            .confidence = 0.7,
        },
        .out_of_bounds => .{
            .error_type = .out_of_bounds,
            .root_cause = try allocator.dupe(u8, "Array/slice access outside valid bounds."),
            .suggested_fix = try allocator.dupe(u8, "Check array length before accessing. Use bounds-checked access. Verify loop conditions."),
            .confidence = 0.8,
        },
        .stack_overflow => .{
            .error_type = .stack_overflow,
            .root_cause = try allocator.dupe(u8, "Infinite recursion or excessively deep call stack."),
            .suggested_fix = try allocator.dupe(u8, "Check for missing base case in recursive functions. Consider iterative approach. Increase stack size if needed."),
            .confidence = 0.9,
        },
        .deadlock => .{
            .error_type = .deadlock,
            .root_cause = try allocator.dupe(u8, "Circular lock dependency between threads."),
            .suggested_fix = try allocator.dupe(u8, "Establish consistent lock ordering. Use timeout on lock acquisition. Consider lock-free data structures."),
            .confidence = 0.6,
        },
        .segfault => .{
            .error_type = .segfault,
            .root_cause = try allocator.dupe(u8, "Invalid memory access — accessing freed/unmapped memory."),
            .suggested_fix = try allocator.dupe(u8, "Check use-after-free. Verify pointer validity. Use memory sanitizer. Check buffer overflows."),
            .confidence = 0.5,
        },
        .timeout => .{
            .error_type = .timeout,
            .root_cause = try allocator.dupe(u8, "Operation exceeded time limit — possible infinite loop or slow I/O."),
            .suggested_fix = try allocator.dupe(u8, "Check for infinite loops. Add progress monitoring. Optimize hot paths. Increase timeout if appropriate."),
            .confidence = 0.6,
        },
        else => .{
            .error_type = .unknown,
            .root_cause = try allocator.dupe(u8, "Unknown error type. Requires manual analysis or AI assistance."),
            .suggested_fix = try allocator.dupe(u8, "Review the stack trace, check recent changes, and use the AI agent for deeper analysis."),
            .confidence = 0.3,
        },
    };
}

fn classifyError(text: []const u8) ErrorType {
    if (std.mem.indexOf(u8, text, "null") != null or
        std.mem.indexOf(u8, text, "nil") != null or
        std.mem.indexOf(u8, text, "NoneType") != null)
        return .null_pointer;

    if (std.mem.indexOf(u8, text, "out of bounds") != null or
        std.mem.indexOf(u8, text, "index out of range") != null or
        std.mem.indexOf(u8, text, "IndexError") != null)
        return .out_of_bounds;

    if (std.mem.indexOf(u8, text, "stack overflow") != null or
        std.mem.indexOf(u8, text, "StackOverflow") != null)
        return .stack_overflow;

    if (std.mem.indexOf(u8, text, "deadlock") != null or
        std.mem.indexOf(u8, text, "Deadlock") != null)
        return .deadlock;

    if (std.mem.indexOf(u8, text, "segfault") != null or
        std.mem.indexOf(u8, text, "SIGSEGV") != null or
        std.mem.indexOf(u8, text, "Segmentation fault") != null)
        return .segfault;

    if (std.mem.indexOf(u8, text, "timeout") != null or
        std.mem.indexOf(u8, text, "timed out") != null)
        return .timeout;

    if (std.mem.indexOf(u8, text, "assert") != null or
        std.mem.indexOf(u8, text, "Assert") != null)
        return .assertion_failure;

    return .unknown;
}

test "classifyError detects null pointer" {
    try std.testing.expectEqual(ErrorType.null_pointer, classifyError("null pointer dereference"));
    try std.testing.expectEqual(ErrorType.null_pointer, classifyError("AttributeError: 'NoneType' object"));
}

test "classifyError detects segfault" {
    try std.testing.expectEqual(ErrorType.segfault, classifyError("Segmentation fault (core dumped)"));
    try std.testing.expectEqual(ErrorType.segfault, classifyError("SIGSEGV at address 0x0"));
}

test "analyzeError returns suggestion" {
    const allocator = std.testing.allocator;
    var suggestion = try analyzeError(allocator, "IndexError: list index out of range");
    defer suggestion.deinit(allocator);
    try std.testing.expectEqual(ErrorType.out_of_bounds, suggestion.error_type);
    try std.testing.expect(suggestion.confidence > 0);
}

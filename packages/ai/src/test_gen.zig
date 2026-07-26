//! AI Test Generation — generates unit test cases for functions.
const std = @import("std");

pub const TestFramework = enum {
    zig_testing,
    pytest,
    jest,
    go_test,
    unknown,
};

pub const GeneratedTest = struct {
    test_code: []const u8,
    framework: TestFramework,
    test_count: usize,

    pub fn deinit(self: *GeneratedTest, allocator: std.mem.Allocator) void {
        allocator.free(self.test_code);
    }
};

/// Detect the test framework from file extension.
pub fn detectFramework(file_path: []const u8) TestFramework {
    if (std.mem.endsWith(u8, file_path, ".zig")) return .zig_testing;
    if (std.mem.endsWith(u8, file_path, ".py")) return .pytest;
    if (std.mem.endsWith(u8, file_path, ".ts") or std.mem.endsWith(u8, file_path, ".js")) return .jest;
    if (std.mem.endsWith(u8, file_path, ".go")) return .go_test;
    return .unknown;
}

/// Generate test stubs for a function. Uses a buffer writer to avoid
/// memory leaks from temporary allocPrint strings.
pub fn generateTestStubs(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    function_body: []const u8,
    framework: TestFramework,
) !GeneratedTest {
    var code: std.ArrayList(u8) = .empty;
    errdefer code.deinit(allocator);
    var test_count: usize = 0;

    // Helper: append formatted string to code, freeing the temp allocation.
    const appendFmt = struct {
        fn append(list: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
            const chunk = try std.fmt.allocPrint(alloc, fmt, args);
            defer alloc.free(chunk);
            try list.appendSlice(alloc, chunk);
        }
    }.append;

    switch (framework) {
        .zig_testing => {
            try appendFmt(&code, allocator, "test \"{s} handles normal input\" {{\n", .{function_name});
            try appendFmt(&code, allocator, "    // TODO: implement test\n", .{});
            try appendFmt(&code, allocator, "    // const result = {s}(...);\n", .{function_name});
            try appendFmt(&code, allocator, "    // try std.testing.expect(...);\n", .{});
            try appendFmt(&code, allocator, "}}\n\n", .{});
            test_count += 1;

            try appendFmt(&code, allocator, "test \"{s} handles empty/zero input\" {{\n", .{function_name});
            try appendFmt(&code, allocator, "    // TODO: test with empty/zero/minimal input\n", .{});
            try appendFmt(&code, allocator, "}}\n\n", .{});
            test_count += 1;

            try appendFmt(&code, allocator, "test \"{s} handles error case\" {{\n", .{function_name});
            try appendFmt(&code, allocator, "    // TODO: test error paths\n", .{});
            try appendFmt(&code, allocator, "    // try std.testing.expectError(..., {s}(...));\n", .{function_name});
            try appendFmt(&code, allocator, "}}\n\n", .{});
            test_count += 1;

            try appendFmt(&code, allocator, "test \"{s} handles edge case\" {{\n", .{function_name});
            try appendFmt(&code, allocator, "    // TODO: test boundary conditions\n", .{});
            try appendFmt(&code, allocator, "    // - max/min values\n", .{});
            try appendFmt(&code, allocator, "    // - null/undefined inputs\n", .{});
            try appendFmt(&code, allocator, "    // - concurrent access\n", .{});
            try appendFmt(&code, allocator, "}}\n\n", .{});
            test_count += 1;
        },
        .pytest => {
            try appendFmt(&code, allocator, "def test_{s}_normal():\n    # TODO: implement test\n    pass\n\n", .{function_name});
            try appendFmt(&code, allocator, "def test_{s}_empty_input():\n    # TODO: test with empty input\n    pass\n\n", .{function_name});
            try appendFmt(&code, allocator, "def test_{s}_error_case():\n    # TODO: test error handling\n    with pytest.raises(...):\n        {s}(...)\n\n", .{ function_name, function_name });
            try appendFmt(&code, allocator, "def test_{s}_edge_case():\n    # TODO: test boundary conditions\n    pass\n\n", .{function_name});
            test_count = 4;
        },
        .jest => {
            try appendFmt(&code, allocator, "describe('{s}', () => {{\n", .{function_name});
            try appendFmt(&code, allocator, "  it('handles normal input', () => {{\n    // TODO: implement test\n  }});\n\n", .{});
            try appendFmt(&code, allocator, "  it('handles empty input', () => {{\n    // TODO: test with empty/null input\n  }});\n\n", .{});
            try appendFmt(&code, allocator, "  it('handles error case', () => {{\n    // TODO: test error paths\n    expect(() => {s}(...)).toThrow();\n  }});\n\n", .{function_name});
            try appendFmt(&code, allocator, "  it('handles edge case', () => {{\n    // TODO: test boundary conditions\n  }});\n}});\n\n", .{});
            test_count = 4;
        },
        else => {
            try appendFmt(&code, allocator, "// TODO: generate tests for {s}\n// Framework: {s}\n\n", .{ function_name, @tagName(framework) });
            test_count = 0;
        },
    }

    _ = function_body; // Used by AI-enhanced version

    return .{
        .test_code = try code.toOwnedSlice(allocator),
        .framework = framework,
        .test_count = test_count,
    };
}

test "generateTestStubs for Zig" {
    const allocator = std.testing.allocator;
    var result = try generateTestStubs(allocator, "add", "return a + b;", .zig_testing);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), result.test_count);
    try std.testing.expect(std.mem.indexOf(u8, result.test_code, "add") != null);
}

test "detectFramework by extension" {
    try std.testing.expectEqual(TestFramework.zig_testing, detectFramework("main.zig"));
    try std.testing.expectEqual(TestFramework.pytest, detectFramework("test.py"));
    try std.testing.expectEqual(TestFramework.jest, detectFramework("app.ts"));
    try std.testing.expectEqual(TestFramework.go_test, detectFramework("main.go"));
}

/// LLM-powered test generation. Takes a function name + body, asks the
/// LLM to generate comprehensive unit tests in the detected framework.
///
/// The LLM is prompted with:
/// - The function signature and body
/// - The target test framework
/// - Instructions to cover normal/edge/error/concurrency cases
///
/// Returns the LLM-generated test code. If the LLM call fails, falls
/// back to the heuristic stub generator (graceful degradation).
pub fn generateTestsWithLlm(
    allocator: std.mem.Allocator,
    function_name: []const u8,
    function_body: []const u8,
    framework: TestFramework,
    provider: anytype,
    cancel_token: ?*const @import("forge-kernel").cancellation.CancellationToken,
) !GeneratedTest {
    // Build the LLM prompt.
    var prompt_buf: std.ArrayList(u8) = .empty;
    defer prompt_buf.deinit(allocator);
    try prompt_buf.appendSlice(allocator, "You are an expert test engineer. Generate comprehensive unit tests for the following function.\n\n");
    try prompt_buf.appendSlice(allocator, "Requirements:\n");
    try prompt_buf.appendSlice(allocator, "- Cover normal cases, edge cases, error cases, and boundary conditions\n");
    try prompt_buf.appendSlice(allocator, "- Use descriptive test names that explain what is being tested\n");
    try prompt_buf.appendSlice(allocator, "- Include assertions that verify the function's behavior\n");
    try prompt_buf.appendSlice(allocator, "- Do NOT include placeholder TODOs — write real, runnable test code\n\n");
    try prompt_buf.appendSlice(allocator, "Test framework: ");
    try prompt_buf.appendSlice(allocator, @tagName(framework));
    try prompt_buf.appendSlice(allocator, "\n\nFunction to test:\n```\n");
    try prompt_buf.appendSlice(allocator, function_body);
    try prompt_buf.appendSlice(allocator, "\n```\n\nGenerate the tests now. Output only the test code, no markdown fences.");

    // Call the LLM.
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
        // LLM call failed — fall back to heuristic stubs.
        return generateTestStubs(allocator, function_name, function_body, framework);
    };
    const llm_output = response_alloc.writer.buffer[0..response_alloc.writer.end];

    // Count test functions in the LLM output (rough heuristic).
    var test_count: usize = 0;
    var lines = std.mem.splitScalar(u8, llm_output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "test ") or
            std.mem.startsWith(u8, trimmed, "def test_") or
            std.mem.startsWith(u8, trimmed, "it(") or
            std.mem.startsWith(u8, trimmed, "func Test"))
        {
            test_count += 1;
        }
    }

    return .{
        .test_code = try allocator.dupe(u8, llm_output),
        .framework = framework,
        .test_count = test_count,
    };
}

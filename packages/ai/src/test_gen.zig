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

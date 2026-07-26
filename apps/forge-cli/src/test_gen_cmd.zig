const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");

const Io = std.Io;

/// `forge test-gen` — AI-powered test generation.
///
/// Takes a file path and function name, generates unit tests in the
/// detected framework (Zig testing, pytest, jest, go test). Uses the
/// LLM to write real, runnable test code; falls back to heuristic
/// stubs if the LLM is unavailable.
///
/// Usage:
///   forge test-gen --file src/main.zig --function add
///   forge test-gen --file src/utils.py --function parse_input --stubs-only
///   forge test-gen --file src/main.zig --function add --output tests/main_test.zig
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    const file_path = parsed.flags.file orelse {
        try writer.writeAll("error: test-gen requires --file <path>\n");
        try writer.writeAll("usage: forge test-gen --file <path> --function <name> [--stubs-only] [--output <path>]\n");
        return 2;
    };
    const function_name = parsed.flags.intent orelse {
        try writer.writeAll("error: test-gen requires --function <name> (use --function flag)\n");
        try writer.writeAll("usage: forge test-gen --file <path> --function <name>\n");
        return 2;
    };

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    // Read the file content so we can extract the function body.
    const content = try readFilePath(allocator, io, opened.root, file_path);
    defer allocator.free(content);

    // Find the function body (rough heuristic: search for "function_name" and
    // extract until the next blank line or closing brace).
    const function_body = extractFunctionBody(content, function_name) orelse {
        try writer.print("error: function '{s}' not found in {s}\n", .{ function_name, file_path });
        return 2;
    };

    // Detect test framework from file extension.
    const framework = ai.test_gen.detectFramework(file_path);
    if (framework == .unknown) {
        try writer.print("error: cannot detect test framework for {s}\n", .{file_path});
        try writer.writeAll("Supported: .zig, .py, .ts/.js, .go\n");
        return 2;
    }

    if (!parsed.flags.json and !parsed.flags.quiet) {
        try writer.print("Generating {s} tests for {s}::{s}...\n\n", .{ @tagName(framework), file_path, function_name });
    }

    // Generate tests: heuristic stubs OR LLM-powered.
    var result: ai.test_gen.GeneratedTest = undefined;
    if (parsed.flags.heuristic_only) {
        result = try ai.test_gen.generateTestStubs(allocator, function_name, function_body, framework);
    } else {
        var scope = try cancel_scope_mod.Scope.init(allocator);
        defer scope.deinit();
        if (!parsed.flags.quiet and !parsed.flags.json) scope.installSigint();
        const cancel_token = scope.token();

        var provider_options = ai_workflow.agentProviderOptionsFromFlags(allocator, parsed.flags, "test generation", io, opened.root);
        defer provider_options.deinit(allocator);

        var provider = ai.provider_factory.create(allocator, io, environ_map, provider_options.options) catch |err| {
            if (!parsed.flags.quiet) {
                try writer.print("Warning: LLM provider unavailable ({}), falling back to stubs.\n\n", .{err});
            }
            result = try ai.test_gen.generateTestStubs(allocator, function_name, function_body, framework);
            try printResult(writer, &result, parsed.flags.json);
            return 0;
        };
        defer provider.deinit(allocator);

        result = ai.test_gen.generateTestsWithLlm(allocator, function_name, function_body, framework, provider, &cancel_token) catch |err| {
            if (!parsed.flags.quiet) {
                try writer.print("Warning: LLM test gen failed ({}), showing stubs.\n\n", .{err});
            }
            result = try ai.test_gen.generateTestStubs(allocator, function_name, function_body, framework);
            return 0;
        };
    }
    defer result.deinit(allocator);

    // Write to output file if --output is specified.
    if (parsed.flags.output) |output_path| {
        try writeFilePath(allocator, io, opened.root, output_path, result.test_code);
        if (!parsed.flags.quiet) {
            try writer.print("Wrote {d} tests to {s}\n", .{ result.test_count, output_path });
        }
    }

    try printResult(writer, &result, parsed.flags.json);
    return 0;
}

fn readFilePath(allocator: std.mem.Allocator, io: Io, root: workspace.WorkspaceRoot, rel_path: []const u8) ![]u8 {
    var dir = std.Io.Dir.openDir(.cwd(), io, root.path, .{}) catch {
        // Try absolute path
        var abs_dir = std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(rel_path) orelse ".", .{}) catch return error.FileNotFound;
        defer abs_dir.close(io);
        var file = abs_dir.openFile(io, std.fs.path.basename(rel_path), .{}) catch return error.FileNotFound;
        defer file.close(io);
        const stat = file.stat(io) catch return error.FileNotFound;
        const size: usize = @intCast(stat.size);
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        const read = file.readPositionalAll(io, buf, 0) catch return error.FileNotFound;
        return buf[0..read];
    };
    defer dir.close(io);
    var file = dir.openFile(io, rel_path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    const stat = file.stat(io) catch return error.FileNotFound;
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const read = file.readPositionalAll(io, buf, 0) catch return error.FileNotFound;
    return buf[0..read];
}

fn writeFilePath(allocator: std.mem.Allocator, io: Io, root: workspace.WorkspaceRoot, rel_path: []const u8, content: []const u8) !void {
    _ = allocator;
    var dir = std.Io.Dir.openDir(.cwd(), io, root.path, .{}) catch return error.FileNotFound;
    defer dir.close(io);
    var file = try dir.createFile(io, rel_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn extractFunctionBody(content: []const u8, function_name: []const u8) ?[]const u8 {
    // Simple heuristic: find "function_name" in the content, then extract
    // from the start of that line to the next blank line or matching close.
    const pos = std.mem.indexOf(u8, content, function_name) orelse return null;
    // Find start of line.
    var start = pos;
    while (start > 0 and content[start - 1] != '\n') start -= 1;
    // Find end: next blank line or 1000 chars max.
    var end = pos;
    var newlines: usize = 0;
    while (end < content.len and newlines < 2) {
        if (content[end] == '\n') newlines += 1 else if (content[end] != ' ' and content[end] != '\t' and content[end] != '\r') newlines = 0;
        end += 1;
        if (end - start > 4000) break;
    }
    return content[start..end];
}

fn printResult(writer: *std.Io.Writer, result: *const ai.test_gen.GeneratedTest, json: bool) !void {
    if (json) {
        try writer.print("{{\"framework\":\"{s}\",\"test_count\":{d},\"test_code\":", .{
            @tagName(result.framework),
            result.test_count,
        });
        // Escape the test code for JSON.
        try writer.writeAll("\"");
        for (result.test_code) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch "\\u0000";
                    try writer.writeAll(s);
                } else {
                    try writer.writeByte(c);
                },
            }
        }
        try writer.writeAll("\"}\n");
        return;
    }

    try writer.print("Generated {d} test(s) for {s}:\n\n", .{ result.test_count, @tagName(result.framework) });
    try writer.writeAll(result.test_code);
    try writer.writeAll("\n");
}

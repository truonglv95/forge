const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");

/// `forge complete` — Inline code completion at a file position.
///
/// RFC-0013: Wire `packages/ai/src/inline_completion.zig` into a CLI command
/// so users can request a completion for a specific file/line/char from the
/// terminal or for scripting. The IDE ghost-text wiring is tracked separately.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    const file_path = parsed.flags.file orelse if (parsed.flags.files.len > 0) parsed.flags.files[0] else null;
    if (file_path == null) {
        try writer.writeAll("error: complete requires --file <path>\n");
        try writer.writeAll("usage: forge complete --file <path> [--line N] [--char N] [--provider auto] [--json]\n");
        return 2;
    }
    const path = file_path.?;

    const line: u32 = parsed.flags.line orelse 1;
    const char: u32 = parsed.flags.character orelse 0;

    // Open workspace (used for provider config lookup too).
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    // Read file content so we can split prefix/suffix at the cursor.
    // Support both absolute and workspace-relative paths.
    var content_owned: ?[]u8 = null;
    defer if (content_owned) |c| allocator.free(c);

    if (std.fs.path.isAbsolute(path)) {
        // Read absolute path directly.
        const abs_dir = std.fs.path.dirname(path) orelse ".";
        const basename = std.fs.path.basename(path);
        var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, abs_dir, .{ .access_sub_paths = true }) catch |err| {
            try writer.print("error: cannot open directory '{s}': {}\n", .{ abs_dir, err });
            return 2;
        };
        defer dir.close(io);
        var file = dir.openFile(io, basename, .{}) catch |err| {
            try writer.print("error: cannot read '{s}': {}\n", .{ path, err });
            return 2;
        };
        defer file.close(io);
        const stat = file.stat(io) catch |err| {
            try writer.print("error: cannot stat '{s}': {}\n", .{ path, err });
            return 2;
        };
        const size: usize = @intCast(stat.size);
        const buf = allocator.alloc(u8, size) catch {
            try writer.writeAll("error: out of memory\n");
            return 2;
        };
        const read_len = file.readPositionalAll(io, buf, 0) catch |err| {
            try writer.print("error: cannot read '{s}': {}\n", .{ path, err });
            return 2;
        };
        if (read_len != size) {
            try writer.writeAll("error: short read\n");
            return 2;
        }
        content_owned = buf;
    } else {
        // Workspace-relative path.
        const root = opened.root;
        const rel_path = workspace.WorkspacePath.parse(path) catch {
            try writer.print("error: invalid workspace path '{s}'\n", .{path});
            return 2;
        };

        var snapshot = workspace.snapshot.FileSnapshot.read(allocator, io, root, rel_path) catch |err| {
            try writer.print("error: cannot read '{s}': {}\n", .{ path, err });
            return 2;
        };
        defer snapshot.deinit();
        // Copy content because snapshot.deinit() frees it.
        content_owned = allocator.dupe(u8, snapshot.content) catch {
            try writer.writeAll("error: out of memory\n");
            return 2;
        };
    }

    const content = content_owned.?;

    // Compute prefix/suffix at (line, char). Lines are 1-indexed, chars 0-indexed.
    var prefix_buf: std.ArrayList(u8) = .empty;
    defer prefix_buf.deinit(allocator);
    var suffix_buf: std.ArrayList(u8) = .empty;
    defer suffix_buf.deinit(allocator);

    var current_line: u32 = 1;
    var line_start: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    var prefix_found = false;
    var cursor_offset: usize = 0;

    while (iter.next()) |line_text| {
        if (current_line == line) {
            // Found target line. Compute cursor offset.
            const clamped_char = @min(char, line_text.len);
            cursor_offset = line_start + clamped_char;
            prefix_found = true;
            break;
        }
        current_line += 1;
        line_start += line_text.len + 1; // +1 for '\n'
    }

    if (!prefix_found) {
        try writer.print("error: line {d} out of range (file has {d} lines)\n", .{ line, current_line - 1 });
        return 2;
    }

    try prefix_buf.appendSlice(allocator, content[0..cursor_offset]);
    if (cursor_offset < content.len) {
        try suffix_buf.appendSlice(allocator, content[cursor_offset..]);
    }

    // Build provider options. For inline completion, we need tool_loop_enabled
    // so the fake provider uses its completeTurn implementation (the non-tool
    // stub returns ProviderInternalError).
    var provider_options = ai_workflow.providerOptionsFromFlags(allocator, .ask, parsed.flags, io, opened.root);
    defer provider_options.deinit(allocator);
    // For inline completion, override the fake response to plain text (not a
    // proposal JSON) and enable tool loop so completeTurn works.
    if (std.mem.eql(u8, provider_options.options.provider_name, "fake")) {
        provider_options.options.fake_response = "fn complete() void {";
        provider_options.options.fake_tool_loop = true;
        provider_options.options.fake_tool_loop_short = true;
    }

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    if (!parsed.flags.quiet and !parsed.flags.json) scope.installSigint();
    var cancel_token = scope.token();

    const request = ai.inline_completion.CompletionRequest{
        .prefix = prefix_buf.items,
        .suffix = suffix_buf.items,
        .file_path = path,
        .max_tokens = parsed.flags.max_tokens,
        .timeout_ms = parsed.flags.timeout_ms,
    };

    const start_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();

    var completion = ai.inline_completion.complete(
        allocator,
        io,
        environ_map,
        request,
        provider_options.options,
        &cancel_token,
    ) catch |err| {
        return writeCompletionError(writer, err);
    };
    defer completion.deinit(allocator);

    const latency_ms = std.Io.Timestamp.now(io, .real).toMilliseconds() - start_ms;

    if (parsed.flags.json) {
        try writer.print(
            "{{\"type\":\"inline_completion\",\"file\":\"{s}\",\"line\":{d},\"character\":{d},\"text\":",
            .{ path, line, char },
        );
        try writeJsonString(writer, completion.text);
        try writer.print(
            ",\"is_multiline\":{},\"latency_ms\":{d},\"provider\":\"{s}\"}}\n",
            .{ completion.is_multiline, latency_ms, provider_options.options.provider_name },
        );
    } else {
        try writer.print("Completion for {s}:{d}:{d}:\n", .{ path, line, char });
        try writer.writeAll(completion.text);
        try writer.writeAll("\n");
        if (!parsed.flags.quiet) {
            try writer.print("[latency] {d}ms | provider: {s}\n", .{ latency_ms, provider_options.options.provider_name });
        }
    }

    return 0;
}

fn writeCompletionError(writer: *std.Io.Writer, err: ai.inline_completion.CompletionError) !u8 {
    switch (err) {
        error.Cancelled => {
            try writer.writeAll("error: completion cancelled\n");
            return 130;
        },
        error.NoCompletion => {
            try writer.writeAll("error: no completion returned\n");
            return 1;
        },
        error.ProviderFailed => {
            try writer.writeAll("error: AI provider failed for completion\n");
            return 2;
        },
        error.OutOfMemory => {
            try writer.writeAll("error: out of memory\n");
            return 2;
        },
        else => {
            try writer.print("error: completion failed: {}\n", .{err});
            return 2;
        },
    }
}

/// Write a JSON-escaped string. Minimal escape for ", \, and control chars.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\"");
}

test "complete requires --file" {
    const allocator = std.testing.allocator;
    var environ = try emptyEnvironMap(allocator);
    defer {
        environ.deinit();
        allocator.destroy(environ);
    }

    var buffer: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);

    // Use a minimal CliArgs with no file flag.
    const parsed = args_mod.CliArgs{
        .flags = .{},
        .command = .complete,
        .positional = &.{},
    };

    const code = try run(allocator, std.testing.io, environ, parsed, &writer);
    try std.testing.expectEqual(@as(u8, 2), code);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "complete requires --file") != null);
}

test "complete with fake provider returns text" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environ = try emptyEnvironMap(allocator);
    defer {
        environ.deinit();
        allocator.destroy(environ);
    }

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.zig"), "pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n");

    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = try std.fmt.bufPrint(&ws_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var buffer: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);

    // Build parsed flags directly.
    var files = [_][]const u8{"sample.zig"};
    const parsed = args_mod.CliArgs{
        .flags = .{
            .workspace = ws,
            .json = true,
            .quiet = true,
            .files = &files,
            .line = 1,
            .character = 0,
            .provider = "fake",
        },
        .command = .complete,
        .positional = &.{},
    };

    const code = try run(allocator, io, environ, parsed, &writer);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"type\":\"inline_completion\"") != null);
}

fn emptyEnvironMap(allocator: std.mem.Allocator) !*std.process.Environ.Map {
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    return map;
}

const Io = std.Io;

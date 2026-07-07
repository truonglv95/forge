const std = @import("std");
const kernel = @import("forge-kernel");

pub const RunError = error{
    TaskFailed,
    OutOfMemory,
};

pub const Result = struct {
    task: []const u8,
    exit_code: i32,
    output: []const u8,
    skipped: bool = false,
};

pub fn runTasks(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    tasks: []const []const u8,
) RunError![]Result {
    var items: std.ArrayList(Result) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.task);
            allocator.free(item.output);
        }
        items.deinit(allocator);
    }

    for (tasks) |task| {
        if (std.mem.startsWith(u8, task, "property:")) {
            const output = try std.fmt.allocPrint(allocator, "(manual) {s}", .{task});
            try items.append(allocator, .{
                .task = try allocator.dupe(u8, task),
                .exit_code = 0,
                .output = output,
                .skipped = true,
            });
            continue;
        }

        if (std.mem.eql(u8, task, "auto:test")) {
            const resolved: ?[]const u8 =
                if (hasBuildZig(io, cwd)) "zig build test" else if (hasNodeProject(io, cwd)) "npm test" else if (hasPythonProject(io, cwd)) "python -m pytest" else null;
            if (resolved) |resolved_task| {
                const nested = try runTasks(allocator, io, cwd, &.{resolved_task});
                defer freeResults(allocator, nested);
                // Flatten single result to keep ordering stable.
                for (nested) |item| {
                    try items.append(allocator, .{
                        .task = try allocator.dupe(u8, task),
                        .exit_code = item.exit_code,
                        .output = try allocator.dupe(u8, item.output),
                        .skipped = item.skipped,
                    });
                }
            } else {
                const output = try allocator.dupe(u8, "(skip) auto:test (no supported test runner detected)");
                try items.append(allocator, .{
                    .task = try allocator.dupe(u8, task),
                    .exit_code = 0,
                    .output = output,
                    .skipped = true,
                });
            }
            continue;
        }

        if (isZigTask(task) and !hasBuildZig(io, cwd)) {
            const output = try std.fmt.allocPrint(allocator, "(skip) {s} (no build.zig in workspace)", .{task});
            try items.append(allocator, .{
                .task = try allocator.dupe(u8, task),
                .exit_code = 0,
                .output = output,
                .skipped = true,
            });
            continue;
        }

        const argv = argvForTask(allocator, task) catch |err| switch (err) {
            error.TaskFailed => {
                try items.append(allocator, .{
                    .task = try allocator.dupe(u8, task),
                    .exit_code = 1,
                    .output = try allocator.dupe(u8, "validation task is not allowlisted"),
                });
                continue;
            },
            else => return error.OutOfMemory,
        };
        defer allocator.free(argv);

        const captured = kernel.process.runCapture(allocator, .{
            .argv = argv,
            .cwd = cwd,
            .max_bytes = 16 * 1024,
        }) catch {
            const output = try allocator.dupe(u8, "failed to run task");
            try items.append(allocator, .{
                .task = try allocator.dupe(u8, task),
                .exit_code = 1,
                .output = output,
            });
            continue;
        };

        try items.append(allocator, .{
            .task = try allocator.dupe(u8, task),
            .exit_code = captured.exit_code,
            .output = captured.output,
        });
    }

    return try items.toOwnedSlice(allocator);
}

fn isZigTask(task: []const u8) bool {
    return std.mem.eql(u8, task, "zig build test") or
        std.mem.eql(u8, task, "zig build") or
        std.mem.eql(u8, task, "zig fmt --check .");
}

fn hasBuildZig(io: std.Io, cwd: []const u8) bool {
    return hasFile(io, cwd, "build.zig");
}

fn hasNodeProject(io: std.Io, cwd: []const u8) bool {
    return hasFile(io, cwd, "package.json");
}

fn hasPythonProject(io: std.Io, cwd: []const u8) bool {
    return hasFile(io, cwd, "pyproject.toml") or hasFile(io, cwd, "pytest.ini") or hasFile(io, cwd, "requirements.txt");
}

fn hasFile(io: std.Io, cwd: []const u8, rel: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cwd, rel }) catch return false;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn freeResults(allocator: std.mem.Allocator, results: []Result) void {
    for (results) |item| {
        allocator.free(item.task);
        allocator.free(item.output);
    }
    allocator.free(results);
}

pub fn formatLines(allocator: std.mem.Allocator, results: []Result) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    for (results) |item| {
        const status = if (item.skipped) "skip" else if (item.exit_code == 0) "ok" else "fail";
        try out.writer.print("validation [{s}] {s} (exit {d})\n", .{ status, item.task, item.exit_code });
        if (item.output.len > 0) {
            try out.writer.writeAll(item.output);
            if (item.output[item.output.len - 1] != '\n') try out.writer.writeAll("\n");
        }
    }
    return try allocator.dupe(u8, out.writer.buffer[0..out.writer.end]);
}

pub fn extractFailureHints(allocator: std.mem.Allocator, results: []const Result, max: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (results) |item| {
        if (item.skipped or item.exit_code == 0) continue;
        try extractPathsFromOutput(allocator, item.output, &out, max);
        if (out.items.len >= max) break;
    }

    return try out.toOwnedSlice(allocator);
}

fn extractPathsFromOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
    out: *std.ArrayList([]const u8),
    max: usize,
) !void {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (out.items.len >= max) return;
        // Heuristic: match `path.ext:line:col` (zig/ts/etc). Keep only the path portion.
        const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (colon1 == 0) continue;
        const path = std.mem.trim(u8, line[0..colon1], &std.ascii.whitespace);
        if (path.len == 0) continue;
        if (std.mem.indexOfScalar(u8, path, ' ') != null) continue;
        if (!endsWithAny(path, &.{ ".zig", ".c", ".h", ".cc", ".cpp", ".hpp", ".js", ".ts", ".tsx" })) continue;
        // De-dupe.
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, path)) break;
        } else {
            try out.append(allocator, try allocator.dupe(u8, path));
        }
    }
}

fn endsWithAny(path: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}

fn argvForTask(allocator: std.mem.Allocator, task: []const u8) ![]const []const u8 {
    if (std.mem.eql(u8, task, "zig build test")) {
        const argv = try allocator.alloc([]const u8, 3);
        argv[0] = "zig";
        argv[1] = "build";
        argv[2] = "test";
        return argv;
    }
    if (std.mem.eql(u8, task, "zig build")) {
        const argv = try allocator.alloc([]const u8, 2);
        argv[0] = "zig";
        argv[1] = "build";
        return argv;
    }
    if (std.mem.eql(u8, task, "zig fmt --check .")) {
        const argv = try allocator.alloc([]const u8, 4);
        argv[0] = "zig";
        argv[1] = "fmt";
        argv[2] = "--check";
        argv[3] = ".";
        return argv;
    }
    if (std.mem.eql(u8, task, "npm test")) {
        const argv = try allocator.alloc([]const u8, 2);
        argv[0] = "npm";
        argv[1] = "test";
        return argv;
    }
    if (std.mem.eql(u8, task, "python -m pytest")) {
        const argv = try allocator.alloc([]const u8, 3);
        argv[0] = "python";
        argv[1] = "-m";
        argv[2] = "pytest";
        return argv;
    }

    return error.TaskFailed;
}

test "argvForTask parses zig build test" {
    const allocator = std.testing.allocator;
    const argv = try argvForTask(allocator, "zig build test");
    defer allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
}

test "validation tasks reject arbitrary process execution" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.TaskFailed, argvForTask(allocator, "rm -rf ."));
    try std.testing.expectError(error.TaskFailed, argvForTask(allocator, "sh -c echo-owned"));
}

test "zig tasks skip when build.zig missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const results = try runTasks(allocator, io, cwd, &.{"zig build test"});
    defer freeResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].skipped);
    try std.testing.expectEqual(@as(i32, 0), results[0].exit_code);
}

test "auto:test skips when no runner detected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const results = try runTasks(allocator, io, cwd, &.{"auto:test"});
    defer freeResults(allocator, results);
    try std.testing.expect(results[0].skipped);
}

test "auto:test selects npm when package.json exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{}\n" });

    const results = try runTasks(allocator, io, cwd, &.{"auto:test"});
    defer freeResults(allocator, results);
    try std.testing.expectEqualStrings("auto:test", results[0].task);
    // We don't assert exit_code (npm may not exist in test env); we only need resolution not skip.
    try std.testing.expect(!results[0].skipped);
}

test "auto:test selects pytest when pyproject exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    try tmp.dir.writeFile(io, .{ .sub_path = "pyproject.toml", .data = "[tool.pytest.ini_options]\n" });

    const results = try runTasks(allocator, io, cwd, &.{"auto:test"});
    defer freeResults(allocator, results);
    try std.testing.expectEqualStrings("auto:test", results[0].task);
    try std.testing.expect(!results[0].skipped);
}

test "extractFailureHints finds zig paths" {
    const allocator = std.testing.allocator;
    const results = [_]Result{
        .{ .task = "auto:test", .exit_code = 1, .output = "src/main.zig:12:3: error: nope\n", .skipped = false },
    };
    const hints = try extractFailureHints(allocator, &results, 4);
    defer {
        for (hints) |h| allocator.free(h);
        allocator.free(hints);
    }
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqualStrings("src/main.zig", hints[0]);
}

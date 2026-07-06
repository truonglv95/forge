const std = @import("std");
const kernel = @import("forge-kernel");
const builtin = @import("builtin");

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

        const argv = try argvForTask(allocator, task);
        defer allocator.free(argv);

        const shell_argv = try shellWrap(allocator, argv);
        defer allocator.free(shell_argv);

        const captured = kernel.process.runCapture(allocator, .{
            .argv = shell_argv,
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

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var split = std.mem.tokenizeScalar(u8, task, ' ');
    while (split.next()) |token| try parts.append(allocator, token);
    if (parts.items.len == 0) return error.TaskFailed;
    return try allocator.dupe([]const u8, parts.items);
}

fn shellWrap(allocator: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    if (argv.len == 0) return error.TaskFailed;
    if (argv.len == 1 and std.mem.indexOfScalar(u8, argv[0], ' ') != null) {
        if (builtin.os.tag == .windows) {
            const out = try allocator.alloc([]const u8, 3);
            out[0] = "cmd";
            out[1] = "/c";
            out[2] = argv[0];
            return out;
        }
        const out = try allocator.alloc([]const u8, 3);
        out[0] = "sh";
        out[1] = "-c";
        out[2] = argv[0];
        return out;
    }
    return try allocator.dupe([]const u8, argv);
}

test "argvForTask parses zig build test" {
    const allocator = std.testing.allocator;
    const argv = try argvForTask(allocator, "zig build test");
    defer allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
}

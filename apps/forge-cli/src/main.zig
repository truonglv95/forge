const std = @import("std");
const core = @import("forge-core");
const kernel = @import("forge-kernel");
const workspace = @import("forge-workspace");

const args_mod = @import("args.zig");
const inspect_cmd = @import("inspect.zig");
const search_cmd = @import("search.zig");
const watch_cmd = @import("watch.zig");
const diff_cmd = @import("diff.zig");
const apply_cmd = @import("apply.zig");
const undo_cmd = @import("undo.zig");
const history_cmd = @import("history.zig");
const task_cmd = @import("task.zig");
const check_cmd = @import("check.zig");
const context_cmd = @import("context_cmd.zig");
const plan_cmd = @import("plan.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const exit_code = run(arena, init.io, args, stdout) catch |err| {
        try stdout.print("error: {}\n", .{err});
        return;
    };
    try stdout.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, writer: *Io.Writer) Io.Writer.Error!u8 {
    const parsed = args_mod.CliArgs.parse(allocator, args) catch |err| {
        try writer.print("error parsing arguments: {}\n", .{err});
        return 2;
    };
    defer allocator.free(parsed.positional);

    switch (parsed.command) {
        .version => {
            try writer.print("forge {s}\n", .{core.version});
            return 0;
        },
        .doctor => {
            try printDoctor(writer);
            return 0;
        },
        .inspect => {
            return inspect_cmd.run(allocator, parsed, writer) catch 2;
        },
        .search => {
            return search_cmd.run(allocator, parsed, writer) catch 2;
        },
        .watch => {
            return watch_cmd.run(allocator, parsed, writer) catch 2;
        },
        .diff => {
            return diff_cmd.run(allocator, parsed, writer) catch 2;
        },
        .apply => {
            return apply_cmd.run(allocator, parsed, writer) catch 2;
        },
        .undo => {
            return undo_cmd.run(allocator, parsed, writer) catch 2;
        },
        .history => {
            return history_cmd.run(allocator, parsed, writer) catch 2;
        },
        .task => {
            return task_cmd.run(allocator, parsed, writer) catch 2;
        },
        .check => {
            return check_cmd.run(allocator, parsed, writer) catch 2;
        },
        .context => {
            return context_cmd.run(allocator, parsed, writer) catch 2;
        },
        .plan => {
            return plan_cmd.run(allocator, io, parsed, writer) catch 2;
        },
        .help => {
            try printHelp(writer);
            return 0;
        },
        .unknown => {
            try writer.print("error: unknown command '{s}'\n\n", .{if (args.len > 1) args[1] else ""});
            try printHelp(writer);
            return 2;
        },
    }
}

fn printDoctor(writer: *Io.Writer) Io.Writer.Error!void {
    var lifecycle = kernel.Lifecycle{};
    lifecycle.transition(.starting) catch unreachable;
    lifecycle.transition(.running) catch unreachable;

    const default_config = workspace.Config{};
    try writer.print(
        \\Forge doctor
        \\  version: {s}
        \\  kernel:  {s}
        \\  config:  valid (tab_width={d}, ai_apply_mode={s})
        \\  status:  ready for M0 development
        \\
    , .{
        core.version,
        @tagName(lifecycle.state),
        default_config.tab_width,
        @tagName(default_config.ai_apply_mode),
    });
}

fn printHelp(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll(
        \\Forge — AI-first native IDE
        \\
        \\Usage:
        \\  forge <command> [options]
        \\
        \\Commands:
        \\  version    Print the Forge version
        \\  doctor     Check the foundation runtime
        \\  inspect    Inspect the workspace root and config
        \\  search     Search across workspace files
        \\  watch      Watch for file changes
        \\  diff       Preview a proposal without mutating
        \\  apply      Apply a proposal
        \\  undo       Undo a specific transaction
        \\  history    Show transaction history
        \\  task       Run a workspace task
        \\  check      Run validation checks
        \\  context    Preview AI context preparation
        \\  plan       Plan a proposal using AI
        \\  help       Show this help
        \\
        \\Options:
        \\  --workspace <path>   Set the workspace root path
        \\  --json               Output machine-readable JSON
        \\  --dry-run            Dry-run flag (used with apply)
        \\
    );
}

test "CLI exposes subcommands" {
    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);

    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, &.{ "forge", "version" }, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), core.version) != null);
}

test "CLI returns error for unknown command" {
    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(@as(u8, 2), try run(std.testing.allocator, std.testing.io, &.{ "forge", "wat" }, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "unknown command") != null);
}

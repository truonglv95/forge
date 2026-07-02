const std = @import("std");
const core = @import("forge-core");
const kernel = @import("forge-kernel");
const workspace = @import("forge-workspace");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const exit_code = try run(args, stdout);
    try stdout.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(args: []const []const u8, writer: *Io.Writer) Io.Writer.Error!u8 {
    const command = if (args.len > 1) args[1] else "help";

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try writer.print("forge {s}\n", .{core.version});
        return 0;
    }
    if (std.mem.eql(u8, command, "doctor")) {
        try printDoctor(writer);
        return 0;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printHelp(writer);
        return 0;
    }

    try writer.print("error: unknown command '{s}'\n\n", .{command});
    try printHelp(writer);
    return 2;
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
        \\  forge <command>
        \\
        \\Commands:
        \\  version    Print the Forge version
        \\  doctor     Check the foundation runtime
        \\  help       Show this help
        \\
    );
}

test "CLI exposes version, doctor, and help" {
    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);

    try std.testing.expectEqual(@as(u8, 0), try run(&.{ "forge", "version" }, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), core.version) != null);

    writer = Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(@as(u8, 0), try run(&.{ "forge", "doctor" }, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "status:  ready") != null);
}

test "CLI returns a usage error for an unknown command" {
    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(@as(u8, 2), try run(&.{ "forge", "wat" }, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "unknown command") != null);
}

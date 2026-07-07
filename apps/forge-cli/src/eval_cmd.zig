const std = @import("std");
const args_mod = @import("args.zig");
const eval_ai_flow = @import("eval_ai_flow.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll(
            "usage: forge eval ai-flow [--provider <fake|gemini|ollama>] [--model <id>] [--max-steps <n>] [--repeat <n>] [--output <path>] [--corpus <path>]\n",
        );
        return 2;
    }

    const suite = parsed.positional[0];
    if (!std.mem.eql(u8, suite, "ai-flow")) {
        try writer.print("error: unknown eval suite '{s}'\n", .{suite});
        try writer.writeAll("usage: forge eval ai-flow\n");
        return 2;
    }

    return eval_ai_flow.run(allocator, io, environ_map, parsed.flags, writer);
}

test "eval command requires a suite" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const args = args_mod.CliArgs{
        .flags = .{},
        .command = .eval,
        .positional = &.{},
    };
    try std.testing.expectEqual(@as(u8, 2), try run(allocator, io, &environ, args, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "usage: forge eval ai-flow") != null);
}

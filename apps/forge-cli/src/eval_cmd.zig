const std = @import("std");
const args_mod = @import("args.zig");
const eval_ai_flow = @import("eval_ai_flow.zig");
const eval_summary = @import("eval_summary.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll(
            "usage: forge eval ai-flow [options]\n\n" ++
                "Run the AI workflow eval suite against one or more providers.\n\n" ++
                "Options:\n" ++
                "  --provider <name>       Single provider (fake|gemini|ollama|openai|anthropic|openrouter|nvidia)\n" ++
                "  --providers <a,b,c>     Multi-provider comparison mode — runs each task against\n" ++
                "                          every provider and reports comparative latency/success\n" ++
                "  --model <id>            Model ID (default: provider default)\n" ++
                "  --max-steps <n>         Max agent steps per task (default: 8)\n" ++
                "  --repeat <n>            Repeat each task N times (default: 1)\n" ++
                "  --output <path>         Output JSONL path (default: .forge/evals/latest.jsonl)\n" ++
                "  --corpus <path>         Corpus path (default: fixtures/eval/agent_reliability.json)\n" ++
                "  --json                  Machine-readable output\n" ++
                "  --quiet                 Suppress progress output\n\n" ++
                "Subcommands:\n" ++
                "  ai-flow                 Run the AI workflow eval suite\n" ++
                "  summary                 Summarize results from a previous eval run\n\n" ++
                "Examples:\n" ++
                "  forge eval ai-flow --provider fake\n" ++
                "  forge eval ai-flow --providers fake,gemini --repeat 3 --json\n" ++
                "  forge eval summary --output .forge/evals/latest.jsonl\n",
        );
        return 2;
    }

    const suite = parsed.positional[0];
    if (std.mem.eql(u8, suite, "summary")) {
        return eval_summary.run(allocator, io, environ_map, parsed.flags, writer);
    }
    if (!std.mem.eql(u8, suite, "ai-flow")) {
        try writer.print("error: unknown eval suite '{s}'\n", .{suite});
        try writer.writeAll("usage: forge eval ai-flow|summary\n");
        return 2;
    }

    return eval_ai_flow.run(allocator, io, environ_map, parsed.flags, writer);
}

test "eval command requires a suite" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const args = args_mod.CliArgs{
        .flags = .{},
        .command = .eval,
        .positional = &.{},
    };
    try std.testing.expectEqual(@as(u8, 2), try run(allocator, io, &environ, args, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "usage: forge eval ai-flow") != null);
}

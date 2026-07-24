const std = @import("std");
const args_mod = @import("args.zig");

/// `forge providers` — List AI providers with capability metadata.
///
/// RFC-0016 (stub for MR #1; full implementation in MR #2).
/// For now, prints the static list of supported providers.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    _ = allocator;
    _ = io;
    return renderProviders(writer, parsed.flags.json);
}

fn renderProviders(writer: *std.Io.Writer, json: bool) !u8 {
    const providers = [_]struct {
        name: []const u8,
        note: []const u8,
    }{
        .{ .name = "auto", .note = "Auto-route based on task and capability" },
        .{ .name = "fake", .note = "Deterministic test provider" },
        .{ .name = "gemini", .note = "Google Gemini (gemini-2.5-pro, gemini-2.5-flash)" },
        .{ .name = "ollama", .note = "Local Ollama models (qwen2.5-coder, llama3.3)" },
        .{ .name = "openrouter", .note = "OpenRouter multi-model gateway" },
        .{ .name = "openai", .note = "OpenAI-compatible (GPT-4o, etc.)" },
        .{ .name = "nvidia", .note = "NVIDIA NIM endpoints" },
    };

    if (json) {
        try writer.writeAll("{\"type\":\"providers\",\"providers\":[");
        for (providers, 0..) |p, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{p.name});
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.writeAll("Available AI providers:\n\n");
        for (providers) |p| {
            try writer.print("  {s: <12} {s}\n", .{ p.name, p.note });
        }
        try writer.writeAll("\nUse --provider <name> with forge ask, forge agent, forge complete.\n");
        try writer.writeAll("Full capability metadata will be added in RFC-0016 (MR #2).\n");
    }
    return 0;
}

/// `forge models` — List AI models or query routing.
///
/// RFC-0016 (stub for MR #1; full implementation in MR #2).
pub fn runModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    _ = allocator;
    _ = io;

    const subcommand = if (parsed.positional.len > 0) parsed.positional[0] else "list";

    if (std.mem.eql(u8, subcommand, "list")) {
        if (parsed.flags.json) {
            try writer.writeAll("{\"type\":\"models\",\"models\":[");
            try writer.writeAll("{\"provider\":\"gemini\",\"model\":\"gemini-2.5-pro\",\"display\":\"Gemini 2.5 Pro\"}");
            try writer.writeAll(",{\"provider\":\"gemini\",\"model\":\"gemini-2.5-flash\",\"display\":\"Gemini 2.5 Flash\"}");
            try writer.writeAll(",{\"provider\":\"ollama\",\"model\":\"qwen2.5-coder:14b\",\"display\":\"Qwen 2.5 Coder 14B (local)\"}");
            try writer.writeAll(",{\"provider\":\"ollama\",\"model\":\"llama3.3:70b\",\"display\":\"Llama 3.3 70B (local)\"}");
            try writer.writeAll(",{\"provider\":\"openrouter\",\"model\":\"auto\",\"display\":\"OpenRouter Auto\"}");
            try writer.writeAll("]}\n");
        } else {
            try writer.writeAll("Available AI models:\n\n");
            try writer.writeAll("  Provider    Model                       Display\n");
            try writer.writeAll("  ----------  --------------------------  -----------------------------\n");
            try writer.writeAll("  gemini      gemini-2.5-pro              Gemini 2.5 Pro\n");
            try writer.writeAll("  gemini      gemini-2.5-flash            Gemini 2.5 Flash\n");
            try writer.writeAll("  ollama      qwen2.5-coder:14b           Qwen 2.5 Coder 14B (local)\n");
            try writer.writeAll("  ollama      llama3.3:70b                Llama 3.3 70B (local)\n");
            try writer.writeAll("  openrouter  auto                        OpenRouter Auto\n");
            try writer.writeAll("\nFull capability metadata + smart router will be added in RFC-0016 (MR #2).\n");
        }
        return 0;
    }

    if (std.mem.eql(u8, subcommand, "route")) {
        try writer.writeAll("Smart model routing (RFC-0016 MR #2):\n");
        try writer.writeAll("  forge models route --intent code_edit --context-bytes 50000\n");
        try writer.writeAll("  forge models route --strengths completion --prefer-local\n");
        try writer.writeAll("\nNot yet implemented. Use --provider <name> --model <id> manually.\n");
        return 0;
    }

    if (std.mem.eql(u8, subcommand, "capability")) {
        try writer.writeAll("Model capability query (RFC-0016 MR #2):\n");
        try writer.writeAll("  forge models capability gemini/gemini-2.5-pro\n");
        try writer.writeAll("\nNot yet implemented.\n");
        return 0;
    }

    try writer.print("Unknown subcommand '{s}'. Use: list | route | capability\n", .{subcommand});
    return 2;
}

test "providers list prints static list" {
    const allocator = std.testing.allocator;
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const parsed = args_mod.CliArgs{
        .flags = .{},
        .command = .providers,
        .positional = &.{},
    };
    _ = try run(allocator, std.testing.io, parsed, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gemini") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ollama") != null);
}

test "models list prints static list" {
    const allocator = std.testing.allocator;
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const parsed = args_mod.CliArgs{
        .flags = .{},
        .command = .models,
        .positional = &.{},
    };
    _ = try runModels(allocator, std.testing.io, parsed, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gemini-2.5-pro") != null);
}

const std = @import("std");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");

/// `forge providers` — List AI providers with capability metadata (RFC-0016).
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
    // Unique providers from the capability table.
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
        try writer.writeAll("Run `forge models list` for full capability metadata.\n");
    }
    return 0;
}

/// `forge models` — List AI models or query routing (RFC-0016).
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
        return listModels(writer, parsed);
    }
    if (std.mem.eql(u8, subcommand, "capability")) {
        return modelCapability(writer, parsed);
    }
    if (std.mem.eql(u8, subcommand, "route")) {
        return routeModel(writer, parsed);
    }

    try writer.print("Unknown subcommand '{s}'. Use: list | capability | route\n", .{subcommand});
    return 2;
}

fn listModels(writer: *std.Io.Writer, parsed: args_mod.CliArgs) !u8 {
    const filter_provider = if (parsed.positional.len > 1) parsed.positional[1] else null;

    if (parsed.flags.json) {
        try writer.writeAll("{\"type\":\"models\",\"models\":[");
        var first = true;
        for (ai.provider_capability.builtin_models) |m| {
            if (filter_provider) |fp| {
                if (!std.mem.eql(u8, m.provider, fp)) continue;
            }
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print(
                "{{\"provider\":\"{s}\",\"model\":\"{s}\",\"display\":\"{s}\",\"max_context_tokens\":{d},\"supports_tools\":{},\"supports_streaming\":{},\"supports_structured_output\":{},\"price_per_mtok_input\":{d},\"price_per_mtok_output\":{d}}}",
                .{
                    m.provider,
                    m.model_id,
                    m.display_name,
                    m.capability.max_context_tokens,
                    m.capability.supports_tools,
                    m.capability.supports_streaming,
                    m.capability.supports_structured_output,
                    m.capability.price_per_mtok_input,
                    m.capability.price_per_mtok_output,
                },
            );
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.writeAll("Available AI models:\n\n");
        try writer.writeAll("  Provider    Model                                  Context    Tools  Stream  Struct  Price (I/O)      Notes\n");
        try writer.writeAll("  ----------  ------------------------------------  ---------  -----  ------  ------  ---------------  -----------------------------\n");
        for (ai.provider_capability.builtin_models) |m| {
            if (filter_provider) |fp| {
                if (!std.mem.eql(u8, m.provider, fp)) continue;
            }
            const tools = if (m.capability.supports_tools) "Y" else "N";
            const stream = if (m.capability.supports_streaming) "Y" else "N";
            const structured = if (m.capability.supports_structured_output) "Y" else "N";
            var price_buf: [64]u8 = undefined;
            const price = if (m.capability.price_per_mtok_input == 0 and m.capability.price_per_mtok_output == 0)
                "free"
            else
                std.fmt.bufPrint(&price_buf, "${d:.2}/${d:.2}", .{
                    @as(f64, @floatFromInt(m.capability.price_per_mtok_input)) / 100.0,
                    @as(f64, @floatFromInt(m.capability.price_per_mtok_output)) / 100.0,
                }) catch "n/a";
            try writer.print("  {s: <10}  {s: <36}  {d: >9}  {s: <5}  {s: <6}  {s: <6}  {s: <15}  {s}\n", .{
                m.provider,
                m.model_id,
                m.capability.max_context_tokens,
                tools,
                stream,
                structured,
                price,
                m.capability.notes,
            });
        }
    }
    return 0;
}

fn modelCapability(writer: *std.Io.Writer, parsed: args_mod.CliArgs) !u8 {
    if (parsed.positional.len < 2) {
        try writer.writeAll("usage: forge models capability <provider>/<model>\n");
        try writer.writeAll("example: forge models capability gemini/gemini-2.5-pro\n");
        return 2;
    }
    const spec = parsed.positional[1];
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse {
        try writer.print("error: expected <provider>/<model>, got '{s}'\n", .{spec});
        return 2;
    };
    const provider = spec[0..slash];
    const model_id = spec[slash + 1 ..];

    const m = ai.provider_capability.findModel(provider, model_id) orelse {
        try writer.print("error: model '{s}/{s}' not found in capability table\n", .{ provider, model_id });
        return 1;
    };

    if (parsed.flags.json) {
        try writer.print(
            "{{\"type\":\"model_capability\",\"provider\":\"{s}\",\"model\":\"{s}\",\"display\":\"{s}\",\"max_context_tokens\":{d},\"effective_context_tokens\":{d},\"supports_tools\":{},\"supports_streaming\":{},\"supports_structured_output\":{},\"returns_usage\":{},\"returns_finish_reason\":{},\"price_per_mtok_input\":{d},\"price_per_mtok_output\":{d},\"strengths\":[",
            .{
                m.provider,
                m.model_id,
                m.display_name,
                m.capability.max_context_tokens,
                m.effective_context_tokens,
                m.capability.supports_tools,
                m.capability.supports_streaming,
                m.capability.supports_structured_output,
                m.capability.returns_usage,
                m.capability.returns_finish_reason,
                m.capability.price_per_mtok_input,
                m.capability.price_per_mtok_output,
            },
        );
        for (m.strengths, 0..) |s, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{s});
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.print("Model: {s}/{s}\n", .{ m.provider, m.model_id });
        try writer.print("  Display: {s}\n", .{m.display_name});
        try writer.print("  Max context: {d} tokens (effective: {d})\n", .{ m.capability.max_context_tokens, m.effective_context_tokens });
        try writer.print("  Supports tools: {}\n", .{m.capability.supports_tools});
        try writer.print("  Supports streaming: {}\n", .{m.capability.supports_streaming});
        try writer.print("  Supports structured output: {}\n", .{m.capability.supports_structured_output});
        try writer.print("  Returns usage: {}\n", .{m.capability.returns_usage});
        try writer.print("  Returns finish_reason: {}\n", .{m.capability.returns_finish_reason});
        if (m.capability.price_per_mtok_input == 0 and m.capability.price_per_mtok_output == 0) {
            try writer.writeAll("  Price: free\n");
        } else {
            try writer.print("  Price: ${d:.2}/${d:.2} per Mtok (input/output)\n", .{
                @as(f64, @floatFromInt(m.capability.price_per_mtok_input)) / 100.0,
                @as(f64, @floatFromInt(m.capability.price_per_mtok_output)) / 100.0,
            });
        }
        try writer.writeAll("  Strengths:");
        for (m.strengths) |s| {
            try writer.print(" {s}", .{s});
        }
        try writer.writeAll("\n");
        try writer.print("  Notes: {s}\n", .{m.capability.notes});
    }
    return 0;
}

fn routeModel(writer: *std.Io.Writer, parsed: args_mod.CliArgs) !u8 {
    const intent = parseIntent(parsed.flags.intent orelse parsed.flags.strengths orelse "code_edit");
    const request = ai.provider_capability.RoutingRequest{
        .intent = intent,
        .require_tools = parsed.flags.require_tools,
        .require_streaming = parsed.flags.require_streaming,
        .context_bytes = parsed.flags.context_bytes orelse 0,
        .max_price_per_mtok = parsed.flags.max_price_per_mtok,
        .prefer_local = parsed.flags.prefer_local,
        .preferred_strengths = parseStrengths(parsed.flags.strengths),
    };

    const decision = ai.provider_capability.route(request) orelse {
        if (parsed.flags.json) {
            try writer.writeAll("{\"type\":\"route\",\"error\":\"no eligible model\"}\n");
        } else {
            try writer.writeAll("error: no eligible model found for the given constraints\n");
        }
        return 1;
    };

    if (parsed.flags.json) {
        try writer.print(
            "{{\"type\":\"route\",\"provider\":\"{s}\",\"model\":\"{s}\",\"display\":\"{s}\",\"reason\":\"{s}\",\"max_context_tokens\":{d}}}\n",
            .{
                decision.provider,
                decision.model_id,
                decision.display_name,
                decision.reason,
                decision.capability.max_context_tokens,
            },
        );
    } else {
        try writer.print("Routed to: {s} ({s}/{s})\n", .{ decision.display_name, decision.provider, decision.model_id });
        try writer.print("  Reason: {s}\n", .{decision.reason});
        try writer.print("  Max context: {d} tokens\n", .{decision.capability.max_context_tokens});
        try writer.print("  Supports tools: {}\n", .{decision.capability.supports_tools});
        if (decision.capability.price_per_mtok_input == 0 and decision.capability.price_per_mtok_output == 0) {
            try writer.writeAll("  Price: free\n");
        } else {
            try writer.print("  Price: ${d:.2}/${d:.2} per Mtok\n", .{
                @as(f64, @floatFromInt(decision.capability.price_per_mtok_input)) / 100.0,
                @as(f64, @floatFromInt(decision.capability.price_per_mtok_output)) / 100.0,
            });
        }
    }
    return 0;
}

fn parseIntent(s: []const u8) ai.provider_capability.TaskIntent {
    if (std.mem.eql(u8, s, "code_edit")) return .code_edit;
    if (std.mem.eql(u8, s, "code_review")) return .code_review;
    if (std.mem.eql(u8, s, "planning")) return .planning;
    if (std.mem.eql(u8, s, "completion")) return .completion;
    if (std.mem.eql(u8, s, "embedding")) return .embedding;
    if (std.mem.eql(u8, s, "agentic")) return .agentic;
    if (std.mem.eql(u8, s, "explore_codebase")) return .explore_codebase;
    return .code_edit;
}

fn parseStrengths(s: ?[]const u8) []const []const u8 {
    // Simple: return empty for now (parsing comma-separated would need allocator).
    _ = s;
    return &.{};
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

test "models list prints capability table" {
    const allocator = std.testing.allocator;
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const parsed = args_mod.CliArgs{
        .flags = .{},
        .command = .models,
        .positional = &.{},
    };
    _ = try runModels(allocator, std.testing.io, parsed, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gemini-2.5-pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "qwen2.5-coder") != null);
}

test "models capability shows single model" {
    const allocator = std.testing.allocator;
    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const positional = [_][]const u8{ "capability", "gemini/gemini-2.5-pro" };
    const parsed = args_mod.CliArgs{
        .flags = .{},
        .command = .models,
        .positional = &positional,
    };
    _ = try runModels(allocator, std.testing.io, parsed, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Gemini 2.5 Pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "2000000") != null);
}

test "models route returns eligible model" {
    const allocator = std.testing.allocator;
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const positional = [_][]const u8{"route"};
    const parsed = args_mod.CliArgs{
        .flags = .{
            .context_bytes = 50000,
            .require_tools = true,
        },
        .command = .models,
        .positional = &positional,
    };
    _ = try runModels(allocator, std.testing.io, parsed, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Routed to:") != null);
}

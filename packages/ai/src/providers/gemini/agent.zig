const std = @import("std");
const kernel = @import("forge-kernel");
const context = @import("../../context.zig");
const tool_executor = @import("../../tool_executor.zig");
const gemini_provider = @import("provider.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const agent_loop = @import("../../agent/loop.zig");
const gemini_transport = @import("tool_transport.zig");

pub const StepCallback = agent_loop.StepCallback;
pub const ExploreConfig = agent_loop.Config;

pub const ExploreError = agent_loop.LoopError;

/// Gemini-backed explore loop. Prefer `agent_loop.run` with a provider transport for new code.
pub fn exploreWithGemini(
    allocator: std.mem.Allocator,
    io: std.Io,
    gemini: *gemini_provider.GeminiProvider,
    intent: []const u8,
    ctx_builder: *const context.ContextBuilder,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    config: ExploreConfig,
) ExploreError!void {
    var transport_state = gemini_transport.GeminiTransport{
        .gemini = gemini,
        .io = io,
        .mcp = mcp,
    };
    const declarations = transport_state.declarationsJson(allocator) catch return error.ProviderFailed;
    defer allocator.free(declarations);

    return agent_loop.run(
        allocator,
        transport_state.transport(),
        declarations,
        intent,
        ctx_builder,
        tool_ctx,
        mcp,
        config,
    );
}

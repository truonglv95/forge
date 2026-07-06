//! AI proposal contracts. Providers and context construction begin in M4.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.ai;

pub const provider = @import("provider.zig");
pub const fake_provider = @import("fake_provider.zig");
pub const gemini_provider = @import("gemini_provider.zig");
pub const ollama_provider = @import("ollama_provider.zig");
pub const ollama_ndjson = @import("ollama_ndjson.zig");
pub const credentials = @import("credentials.zig");
pub const provider_factory = @import("provider_factory.zig");
pub const agent = @import("agent.zig");
pub const tools = @import("tools.zig");
pub const tool_registry = @import("tools/registry.zig");
pub const tool_args = @import("tools/args.zig");
pub const tool_dispatch = @import("tools/dispatch.zig");
pub const agent_loop = @import("agent/loop.zig");
pub const agent_turn = @import("agent/turn.zig");
pub const gemini_tool_transport = @import("providers/gemini/tool_transport.zig");
pub const ollama_tool_transport = @import("providers/ollama/tool_transport.zig");
pub const tool_executor = @import("tool_executor.zig");
pub const progress = @import("progress.zig");
pub const streaming = @import("streaming.zig");
pub const retry = @import("retry.zig");
pub const secret_scanner = @import("secret_scanner.zig");
pub const context = @import("context.zig");
pub const context_loader = @import("context_loader.zig");
pub const context_supplement = @import("context_supplement.zig");
pub const context_retrieval = @import("context_retrieval.zig");
pub const import_graph = @import("import_graph.zig");
pub const gemini_embedder = @import("gemini_embedder.zig");
pub const codebase_search = @import("codebase_search.zig");
pub const agent_memory = @import("agent_memory.zig");
pub const web_fetcher = @import("web_fetcher.zig");
pub const context_rerank = @import("context_rerank.zig");
pub const context_rank = @import("context_rank.zig");
pub const docs_loader = @import("docs_loader.zig");
pub const scope_resolver = @import("scope_resolver.zig");
pub const local_vector = @import("local_vector.zig");
pub const planner = @import("planner.zig");
pub const run_record = @import("run_record.zig");
pub const conversation = @import("conversation.zig");
pub const multimodal = @import("multimodal.zig");
pub const gemini_tools = @import("gemini_tools.zig");
pub const gemini_agent = @import("gemini_agent.zig");
pub const gemini_sse = @import("gemini_sse.zig");
pub const proposal_workflow = @import("proposal_workflow.zig");
pub const subagent = @import("subagent.zig");
pub const spec_writer = @import("spec_writer.zig");
pub const validation_hints = @import("validation_hints.zig");
pub const validation_runner = @import("validation_runner.zig");
pub const repair_loop = @import("repair_loop.zig");
pub const mcp_config = @import("mcp_config.zig");
pub const mcp_client = @import("mcp_client.zig");
pub const mcp_http = @import("mcp_http.zig");
pub const mcp_registry = @import("mcp_registry.zig");

pub const ProposalStatus = enum {
    draft,
    ready_for_review,
    approved,
    rejected,
    applied,
    stale,
};

pub fn mayApply(status: ProposalStatus) bool {
    return status == .approved;
}

test "only approved proposals may be applied" {
    try std.testing.expect(mayApply(.approved));
    try std.testing.expect(!mayApply(.draft));
    try std.testing.expect(!mayApply(.stale));
}

test {
    // Keep every exported AI subsystem in the package test graph. Without this,
    // Zig's lazy analysis can report a green package while most module tests
    // were never compiled or executed.
    std.testing.refAllDecls(@This());
}

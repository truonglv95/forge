//! AI proposal contracts. Providers and context construction begin in M4.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.ai;

pub const provider = @import("provider.zig");
pub const providers = @import("providers/root.zig");

// Aliases for backwards compatibility or common use
pub const fake_provider = providers.fake;
pub const gemini_provider = providers.gemini;
pub const ollama_provider = providers.ollama;
pub const openrouter_provider = providers.openrouter;
pub const credentials = @import("credentials.zig");
pub const ollama_embedder = providers.ollama_embedder;
pub const ollama_ndjson = providers.ollama_ndjson;
pub const openai_sse = providers.openai_sse;
pub const openai_compat = providers.openai_compat;
pub const provider_factory = @import("provider_factory.zig");
pub const config = @import("config.zig");
pub const agent = @import("agent.zig");
pub const agent_event = @import("agent_event.zig");
pub const agent_context_phase = @import("agent/context_phase.zig");
pub const agent_tool_phase = @import("agent/tool_phase.zig");
pub const agent_compaction = @import("agent/compaction.zig");
pub const tools = @import("tools.zig");
pub const tool_registry = @import("tools/registry.zig");
pub const tool_args = @import("tools/args.zig");
pub const tool_dispatch = @import("tools/dispatch.zig");
pub const agent_loop = @import("agent/loop.zig");
pub const agent_turn = @import("agent/turn.zig");
pub const gemini_tool_transport = providers.gemini_tool_transport;
pub const ollama_tool_transport = providers.ollama_tool_transport;
pub const openrouter_tool_transport = providers.openrouter_tool_transport;
pub const fake_tool_transport = providers.fake_tool_transport;
pub const tool_executor = @import("tool_executor.zig");
pub const progress = @import("progress.zig");
pub const trace = @import("trace.zig");
pub const streaming = @import("streaming.zig");
pub const retry = @import("retry.zig");
pub const secret_scanner = @import("secret_scanner.zig");
pub const context = @import("context.zig");
pub const context_cache = @import("context_cache.zig");
pub const context_loader = @import("context_loader.zig");
pub const context_budget = @import("context_budget.zig");
pub const context_query = @import("context_query.zig");
pub const context_plan = @import("context_plan.zig");
pub const context_supplement = @import("context_supplement.zig");
pub const context_retrieval = @import("context_retrieval.zig");
pub const context_expander = @import("context_expander.zig");
pub const import_graph = @import("import_graph.zig");
pub const gemini_embedder = providers.gemini_embedder;
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
pub const gemini_tools = providers.gemini_tools;
pub const gemini_agent = providers.gemini_agent;
pub const gemini_sse = providers.gemini_sse;
pub const proposal_workflow = @import("proposal_workflow.zig");
pub const subagent = @import("subagent.zig");
pub const spec_writer = @import("spec_writer.zig");
pub const mcp_capability = @import("mcp_capability.zig");
pub const provider_failover = @import("provider_failover.zig");
pub const provider_capability = @import("provider_capability.zig");
pub const mention_parser = @import("mention_parser.zig");
pub const mention_resolver = @import("mention_resolver.zig");
pub const usage_tracker = @import("usage_tracker.zig");
pub const diff_tool = @import("diff_tool.zig");
pub const adaptive_budget = @import("adaptive_budget.zig");
pub const inline_completion = @import("inline_completion.zig");
pub const validation_hints = @import("validation_hints.zig");
pub const validation_runner = @import("validation_runner.zig");
pub const repair_loop = @import("repair_loop.zig");
pub const mcp_config = @import("mcp_config.zig");
pub const mcp_client = @import("mcp_client.zig");
pub const mcp_http = @import("mcp_http.zig");
pub const mcp_registry = @import("mcp_registry.zig");
pub const routing = @import("routing.zig");
pub const intent_classifier = @import("intent_classifier.zig");
pub const route_resolver = @import("route_resolver.zig");
pub const prompt_pack = @import("prompt_pack.zig");
pub const index_warm = @import("index_warm.zig");
pub const ecosystem = @import("ecosystem.zig");
pub const task_ledger = @import("task_ledger.zig");
pub const session_grant = @import("session_grant.zig");

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

// Pull in verification tests.
comptime {
    _ = providers.fake;
    _ = providers.fake_tool_transport;
    _ = providers.gemini;
    _ = providers.gemini_embedder;
    _ = providers.ollama;
    _ = providers.openrouter;
    _ = providers.openai_sse;
    _ = providers.openai_compat;
    _ = route_resolver;
    _ = @import("providers/fake/provider_test.zig");
}

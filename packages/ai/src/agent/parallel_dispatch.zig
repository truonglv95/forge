//! Parallel tool dispatch — execute multiple independent tool calls concurrently.
//!
//! When the model returns `Completion.tool_calls` (multiple tool calls in one
//! turn), the agent loop currently executes them sequentially. This module
//! provides a parallel execution path: read-only tools (search, read_file,
//! codebase_search, lsp_*, list_tree, find_files, git_diff, etc.) are
//! dispatched on background threads, while mutation tools (replace_file_content,
//! multi_edit, run_command, etc.) are kept sequential for safety.
//!
//! Thread safety:
//!   - tool_executor.Context has a mutex-protected tool_cache, so cache
//!     access is safe. However, the edit_callback and lsp_request_callback
//!     may not be thread-safe — we only parallelize tools that don't use them.
//!   - Each parallel tool gets its own result buffer; results are collected
//!     and appended to the conversation sequentially after all threads join.
//!
//! This is the P3.15 parallel tool execution primitive.

const std = @import("std");
const tool_args = @import("../tools/args.zig");
const tool_dispatch = @import("../tools/dispatch.zig");
const tool_executor = @import("../tool_executor.zig");
const tool_registry = @import("../tools/registry.zig");
const mcp_registry = @import("../mcp_registry.zig");
const turn = @import("turn.zig");

/// Maximum number of concurrent tool executions. Capped to avoid overwhelming
/// the system with too many threads (each tool may spawn subprocesses or make
/// network requests).
pub const max_concurrent: usize = 4;

/// Classify a tool as safe for parallel execution (read-only, no side effects,
/// no callback dependencies). Mutation tools and tools that use
/// edit_callback/lsp_request_callback must run sequentially.
pub fn isParallelSafe(tool_name: []const u8) bool {
    // Read-only observation tools — safe to run in parallel.
    if (std.mem.eql(u8, tool_name, "search")) return true;
    if (std.mem.eql(u8, tool_name, "codebase_search")) return true;
    if (std.mem.eql(u8, tool_name, "read_file")) return true;
    if (std.mem.eql(u8, tool_name, "read_many_files")) return true;
    if (std.mem.eql(u8, tool_name, "list_tree")) return true;
    if (std.mem.eql(u8, tool_name, "find_files")) return true;
    if (std.mem.eql(u8, tool_name, "git_diff")) return true;
    if (std.mem.eql(u8, tool_name, "diff_preview")) return true;
    if (std.mem.eql(u8, tool_name, "get_editor_context")) return true;

    // LSP tools — these use lsp_request_callback which may not be thread-safe.
    // Keep sequential for now.
    // if (std.mem.eql(u8, tool_name, "lsp_workspace_symbol")) return true;
    // if (std.mem.eql(u8, tool_name, "lsp_find_references")) return true;
    // if (std.mem.eql(u8, tool_name, "lsp_definition")) return true;
    // if (std.mem.eql(u8, tool_name, "lsp_hover")) return true;
    // if (std.mem.eql(u8, tool_name, "lsp_document_symbols")) return true;
    // if (std.mem.eql(u8, tool_name, "lsp_diagnostics")) return true;

    // Mutation tools — NEVER parallel.
    // replace_file_content, multi_edit, run_command, run_task, git_stage,
    // git_commit, apply_proposal, spawn_subagent, remember, fetch_url — all
    // have side effects or use non-thread-safe callbacks.
    return false;
}

/// Result of a single tool execution in a parallel batch.
pub const ParallelResult = struct {
    call: turn.ToolCall,
    result: tool_dispatch.ExecutionResult,
    err: ?anyerror = null,
};

/// Worker context for each parallel tool thread.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    call: turn.ToolCall,
    result: ?tool_dispatch.ExecutionResult = null,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = .{ .raw = false },
};

/// Execute a batch of tool calls in parallel (up to max_concurrent at a time).
/// Returns results in the SAME ORDER as the input calls. Tools that are not
/// parallel-safe are executed sequentially within this function (still returns
/// results in order).
///
/// The caller is responsible for:
///   - Appending tool_call + tool_result to the conversation AFTER this
///     function returns (sequential, to maintain conversation order).
///   - Handling approval callbacks (this function does NOT call approval —
///     it assumes the caller already approved, or the tools are read-only).
pub fn executeBatch(
    allocator: std.mem.Allocator,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    calls: []const turn.ToolCall,
) ![]ParallelResult {
    if (calls.len == 0) return &.{};

    var results = try allocator.alloc(ParallelResult, calls.len);
    errdefer allocator.free(results);

    // Initialize results.
    for (calls, 0..) |call, i| {
        results[i] = .{
            .call = .{
                .name = try allocator.dupe(u8, call.name),
                .args_json = try allocator.dupe(u8, call.args_json),
            },
            .result = .{ .text = "", .images = &.{} },
        };
    }

    // Partition calls into parallel-safe and sequential.
    // Execute parallel-safe calls in batches of max_concurrent.
    // Execute sequential calls one at a time.
    //
    // For simplicity, we process all calls in order but dispatch
    // parallel-safe ones to threads when possible. This keeps the result
    // order correct.

    var i: usize = 0;
    while (i < calls.len) {
        // Collect a batch of parallel-safe calls.
        var batch_end = i;
        while (batch_end < calls.len and
            batch_end - i < max_concurrent and
            isParallelSafe(calls[batch_end].name))
        {
            batch_end += 1;
        }

        if (batch_end > i) {
            // Parallel batch.
            try executeParallelBatch(allocator, tool_ctx, mcp, calls[i..batch_end], results[i..batch_end]);
            i = batch_end;
        } else {
            // Sequential call (not parallel-safe).
            try executeSequential(allocator, tool_ctx, mcp, calls[i], &results[i]);
            i += 1;
        }
    }

    return results;
}

fn executeParallelBatch(
    allocator: std.mem.Allocator,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    calls: []const turn.ToolCall,
    results: []ParallelResult,
) !void {
    if (calls.len == 1) {
        // Single call — no need for threads.
        return executeSequential(allocator, tool_ctx, mcp, calls[0], &results[0]);
    }

    // Spawn worker contexts.
    var workers = try allocator.alloc(WorkerCtx, calls.len);
    defer allocator.free(workers);

    for (calls, 0..) |call, i| {
        workers[i] = .{
            .allocator = allocator,
            .tool_ctx = tool_ctx,
            .mcp = mcp,
            .call = .{
                .name = @constCast(call.name),
                .args_json = @constCast(call.args_json),
            },
        };
    }

    // Spawn threads.
    var threads = try allocator.alloc(std.Thread, calls.len);
    defer allocator.free(threads);

    var spawned: usize = 0;
    errdefer {
        for (workers[0..spawned]) |*w| w.done.store(true, .release);
        for (threads[0..spawned]) |t| t.join();
    }

    for (workers, 0..) |*w, i| {
        threads[i] = try std.Thread.spawn(.{}, workerFn, .{w});
        spawned += 1;
    }

    // Join all threads.
    for (threads) |t| t.join();

    // Collect results.
    for (workers, 0..) |w, i| {
        if (w.err) |err| {
            results[i].err = err;
        } else if (w.result) |res| {
            // Transfer ownership of result text to results[i].
            results[i].result.deinit(allocator);
            results[i].result = res;
        }
    }
}

fn workerFn(ctx: *WorkerCtx) void {
    const result = tool_dispatch.execute(
        ctx.allocator,
        ctx.tool_ctx,
        ctx.mcp,
        ctx.call,
    ) catch |err| {
        ctx.err = err;
        ctx.done.store(true, .release);
        return;
    };
    ctx.result = result;
    ctx.done.store(true, .release);
}

fn executeSequential(
    allocator: std.mem.Allocator,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    call: turn.ToolCall,
    result: *ParallelResult,
) !void {
    const exec = tool_dispatch.execute(allocator, tool_ctx, mcp, call) catch |err| {
        result.err = err;
        return;
    };
    result.result.deinit(allocator);
    result.result = exec;
}

/// Free an array of ParallelResult returned by executeBatch.
pub fn freeBatch(allocator: std.mem.Allocator, results: []ParallelResult) void {
    for (results) |*r| {
        allocator.free(r.call.name);
        allocator.free(r.call.args_json);
        r.result.deinit(allocator);
    }
    allocator.free(results);
}

// =============================================================================
// Tests
// =============================================================================

test "isParallelSafe identifies read-only tools" {
    try std.testing.expect(isParallelSafe("search"));
    try std.testing.expect(isParallelSafe("read_file"));
    try std.testing.expect(isParallelSafe("codebase_search"));
    try std.testing.expect(isParallelSafe("list_tree"));
    try std.testing.expect(isParallelSafe("find_files"));
    try std.testing.expect(isParallelSafe("git_diff"));
    try std.testing.expect(isParallelSafe("read_many_files"));
    try std.testing.expect(isParallelSafe("diff_preview"));
    try std.testing.expect(isParallelSafe("get_editor_context"));
}

test "isParallelSafe rejects mutation tools" {
    try std.testing.expect(!isParallelSafe("replace_file_content"));
    try std.testing.expect(!isParallelSafe("multi_edit"));
    try std.testing.expect(!isParallelSafe("run_command"));
    try std.testing.expect(!isParallelSafe("run_task"));
    try std.testing.expect(!isParallelSafe("git_stage"));
    try std.testing.expect(!isParallelSafe("git_commit"));
    try std.testing.expect(!isParallelSafe("spawn_subagent"));
    try std.testing.expect(!isParallelSafe("remember"));
    try std.testing.expect(!isParallelSafe("fetch_url"));
    try std.testing.expect(!isParallelSafe("apply_proposal"));
}

test "isParallelSafe rejects LSP tools (callback not thread-safe)" {
    try std.testing.expect(!isParallelSafe("lsp_workspace_symbol"));
    try std.testing.expect(!isParallelSafe("lsp_find_references"));
    try std.testing.expect(!isParallelSafe("lsp_definition"));
    try std.testing.expect(!isParallelSafe("lsp_hover"));
}

test "executeBatch handles empty input" {
    const allocator = std.testing.allocator;
    const results = try executeBatch(allocator, undefined, null, &.{});
    defer freeBatch(allocator, results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

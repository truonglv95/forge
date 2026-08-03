const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const forge_util = @import("forge-util");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");

const Io = std.Io;

/// `forge review` — AI-powered code review of git diff.
///
/// Runs heuristic checks (secrets, TODOs, debug prints, long lines) first,
/// then sends the diff to the LLM for deeper analysis (bugs, security,
/// performance, style). Outputs a structured review report.
///
/// Usage:
///   forge review                              # review unstaged changes
///   forge review --staged                     # review staged changes
///   forge review --base main --head feature   # review branch diff
///   forge review --heuristic-only             # skip LLM, heuristic only
///   forge review --json                       # JSON output
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    // Get the diff to review. Default: unstaged changes (git diff).
    // --staged: staged changes (git diff --staged).
    // --base/--head: branch diff (git diff base...head).
    const diff = try getDiff(allocator, io, opened.root, parsed);
    defer allocator.free(diff);

    if (diff.len == 0) {
        if (!parsed.flags.quiet) {
            try writer.writeAll("No changes to review.\n");
        }
        return 0;
    }

    if (!parsed.flags.json and !parsed.flags.quiet) {
        try writer.print("Reviewing {d} bytes of diff...\n\n", .{diff.len});
    }

    // Step 1: Run heuristic analysis (always — fast, no LLM call).
    var result = try ai.code_review.analyzeDiff(allocator, diff);
    defer result.deinit(allocator);

    // Step 2: If --heuristic-only is NOT set, run LLM review.
    const heuristic_only = parsed.flags.heuristic_only;
    if (!heuristic_only) {
        var scope = try cancel_scope_mod.Scope.init(allocator);
        defer scope.deinit();
        if (!parsed.flags.quiet and !parsed.flags.json) scope.installSigint();
        const cancel_token = scope.token();

        var provider_options = ai_workflow.agentProviderOptionsFromFlags(allocator, parsed.flags, "code review", io, opened.root);
        defer provider_options.deinit(allocator);

        // Get a provider for the LLM call.
        var provider = ai.provider_factory.create(allocator, io, environ_map, provider_options.options) catch |err| {
            if (!parsed.flags.quiet) {
                try writer.print("Warning: LLM provider unavailable ({}), falling back to heuristic-only.\n\n", .{err});
            }
            // Fall back to heuristic-only result (already computed).
            try printResult(writer, &result, parsed.flags.json);
            return 0;
        };
        defer provider.deinit(allocator);

        // Replace result with LLM-augmented result.
        const llm_result = ai.code_review.reviewWithLlm(allocator, io, diff, provider, &cancel_token) catch |err| {
            if (!parsed.flags.quiet) {
                try writer.print("Warning: LLM review failed ({}), showing heuristic-only results.\n\n", .{err});
            }
            try printResult(writer, &result, parsed.flags.json);
            return 0;
        };
        result.deinit(allocator);
        result = llm_result;
    }

    try printResult(writer, &result, parsed.flags.json);
    return 0;
}

fn getDiff(allocator: std.mem.Allocator, io: Io, root: workspace.WorkspaceRoot, parsed: args_mod.CliArgs) ![]u8 {
    _ = io;
    // Build git diff command based on flags.
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "git");
    try args.append(allocator, "diff");
    if (parsed.flags.staged) {
        try args.append(allocator, "--staged");
    }
    if (parsed.flags.base) |base| {
        if (parsed.flags.head) |head| {
            // base...head syntax (three dots for merge-base diff)
            const range = std.fmt.allocPrint(allocator, "{s}...{s}", .{ base, head }) catch return error.OutOfMemory;
            defer allocator.free(range);
            try args.append(allocator, range);
        } else {
            try args.append(allocator, base);
        }
    }

    // Run git diff via forge_util.process_spawn (handles subprocess I/O).
    const result = forge_util.process_spawn.runCapture(allocator, args.items, .{
        .cwd = root.path,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SpawnFailed;
    if (result.exit_code != 0) {
        allocator.free(result.output);
        return error.GitDiffFailed;
    }
    return result.output;
}

fn printResult(writer: *std.Io.Writer, result: *const ai.code_review.ReviewResult, json: bool) !void {
    if (json) {
        try writer.print("{{\"overall_score\":{d},\"comment_count\":{d},\"summary\":\"{s}\",\"comments\":[", .{
            result.overall_score,
            result.comments.len,
            result.summary,
        });
        for (result.comments, 0..) |c, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"file\":\"{s}\",\"line\":{d},\"severity\":\"{s}\",\"category\":\"{s}\",\"message\":\"{s}\"}}", .{
                c.file_path,
                c.line,
                @tagName(c.severity),
                c.category,
                c.message,
            });
        }
        try writer.writeAll("]}\n");
        return;
    }

    try writer.print("Code Review — Score: {d}/100\n", .{result.overall_score});
    try writer.print("Summary: {s}\n\n", .{result.summary});
    if (result.comments.len == 0) {
        try writer.writeAll("No issues found. Clean diff!\n");
        return;
    }
    try writer.print("Comments ({d}):\n", .{result.comments.len});
    for (result.comments) |c| {
        const sev_icon = switch (c.severity) {
            .critical => "🔴",
            .warning => "🟡",
            .suggestion => "🔵",
            .nitpick => "⚪",
        };
        _ = sev_icon; // Emoji may not render in all terminals — use text label.
        const sev_label = switch (c.severity) {
            .critical => "CRITICAL",
            .warning => "WARNING",
            .suggestion => "SUGGESTION",
            .nitpick => "NITPICK",
        };
        try writer.print("  [{s}] {s}:{d} ({s}) — {s}\n", .{
            sev_label,
            c.file_path,
            c.line,
            c.category,
            c.message,
        });
        if (c.suggestion) |s| {
            try writer.print("    Suggestion: {s}\n", .{s});
        }
    }
}

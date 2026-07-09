const std = @import("std");
const context = @import("../context.zig");
const context_manifest = @import("../context_manifest.zig");
const routing = @import("../routing.zig");

pub const Options = struct {
    task_intent: routing.TaskIntent = .explore_codebase,
    preloaded_retrieval: bool = false,
};

pub fn buildExplorePrompt(
    allocator: std.mem.Allocator,
    intent: []const u8,
    builder: *const context.ContextBuilder,
    options: Options,
) ![]u8 {
    var summary = try context_manifest.summarize(allocator, builder);
    defer context_manifest.freeSummary(allocator, &summary);

    const manifest = try context_manifest.formatManifest(allocator, builder, summary);
    defer allocator.free(manifest);

    var prompt = std.Io.Writer.Allocating.init(allocator);
    defer prompt.deinit();
    const writer = &prompt.writer;

    try writer.print("You are a coding agent working inside a Forge workspace.\n", .{});
    try writer.writeAll(
        \\Tool loop contract:
        \\- If the current context is insufficient, call exactly one focused tool to get the missing fact.
        \\- Prefer grep/search for exact symbols, filenames, and short keywords; use codebase_search only when grep is insufficient.
        \\- Grep accepts pattern, optional path/glob, and a|b alternation. Example: {"pattern":"engine|tensor","glob":"*.py"}.
        \\- Prefer codebase_search for unknown symbols/concepts, grep for exact text, list_tree for structure, and read_file for line-level evidence.
        \\- For "where is X" / Vietnamese "ở đâu"/"tới đâu"/"đâu rồi" questions: start with list_tree on `.`, then read_file on likely paths.
        \\- Use short English keywords in search/codebase_search (e.g. "tiny engine"), never paste the full user sentence.
        \\- If codebase_search says the index is not ready, use list_tree and read_file instead of repeating semantic search.
        \\- If an imports/import-graph block is present, prefer read_file on those neighbor files when chasing definitions or call sites.
        \\- After each tool result, decide whether you have enough evidence; continue only when another specific fact is missing.
        \\- Do not repeat equivalent tool calls unless the previous observation was insufficient or stale.
        \\- Finish with a concise answer once the task is complete.
        \\
    );
    try writer.writeAll(context_manifest.intentGuidance(options.task_intent));
    if (options.task_intent == .answer_question or options.task_intent == .explore_codebase) {
        try writer.writeAll(
            \\Read-only policy:
            \\- Use tools only to inspect the workspace; do not propose or apply edits.
            \\- Finish with a natural-language answer grounded in the files/tool results you inspected.
            \\- Do not output WorkspaceEdit JSON, schema_version, or workspace_edit for read-only questions.
            \\- If the user asks whether something is missing or OK, assess the current implementation and name concrete gaps or say none were found.
            \\
        );
    }
    if (options.task_intent == .edit_code) {
        try writer.writeAll(
            \\Implementation policy:
            \\- Prefer *.py / *.zig / *.ts source files; skip __pycache__, .pyc, and build artifacts.
            \\- After one or two read_file calls, use replace_file_content to implement the requested change.
            \\- replace_file_content directly edits the user's editor buffer. Do not output WorkspaceEdit JSON or proposal JSON.
            \\- Finish with a short summary of the concrete edits, not a generic framework explanation.
            \\
        );
    }
    try writer.print("\nUser intent: {s}\n\n", .{intent});

    if (options.preloaded_retrieval) {
        try writer.writeAll(
            \\Retrieval policy: fused semantic + keyword context is pre-loaded below.
            \\Do not call codebase_search for the same intent unless you need different symbols.
            \\
        );
    } else {
        try writer.writeAll(
            \\Use search, codebase_search, list_tree, and read_file to gather facts before answering.
            \\Do not guess file contents.
            \\
        );
    }

    try writer.writeAll(manifest);
    try writer.writeAll("\nContext blocks loaded:\n");

    for (builder.blocks.items) |block| {
        try writer.print("[{s}] {s}\n", .{ @tagName(block.block_type), block.name });
    }

    return prompt.toOwnedSlice();
}

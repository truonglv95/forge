//! Tool selector — picks a minimal subset of the 22 native tools for a
//! given intent. Sending fewer tool declarations to the LLM reduces token
//! usage and improves tool-call accuracy (the LLM has fewer options to
//! confuse).
//!
//! Phase B: the backend agent-prepare endpoint suggests tools, but when
//! it's unavailable (used_llm=false), this module provides the native
//! fallback selection.

const std = @import("std");
const tools = @import("../tools.zig");
const intent_taxonomy = @import("intent_taxonomy.zig");

/// A tool selection result: the recommended tools + the capability profile
/// that allows them.
pub const ToolSelection = struct {
    tools: []const tools.ToolId,
    profile: tools.CapabilityProfile,
};

/// Select the minimal tool set for an intent.
/// Returns a static slice — no allocation needed.
pub fn selectForIntent(intent: intent_taxonomy.Intent) ToolSelection {
    return switch (intent) {
        // Questions: read + search only.
        .answer_question => .{
            .tools = &.{
                .read_file, .search, .codebase_search, .list_tree, .find_files,
            },
            .profile = .read_only,
        },
        // Exploration: read + search + LSP + tree.
        .explore_codebase => .{
            .tools = &.{
                .read_file,          .read_many_files, .search,               .codebase_search,
                .list_tree,          .find_files,      .lsp_workspace_symbol, .lsp_document_symbols,
                .get_editor_context,
            },
            .profile = .read_only,
        },
        // Code review: read + search + git diff + LSP diagnostics.
        .code_review => .{
            .tools = &.{
                .read_file, .read_many_files, .search,              .codebase_search,
                .git_diff,  .lsp_diagnostics, .lsp_find_references, .show_context,
            },
            .profile = .read_only,
        },
        // Plan: read + search, no mutations.
        .plan_change => .{
            .tools = &.{
                .read_file, .search, .codebase_search, .list_tree, .find_files,
            },
            .profile = .read_only,
        },
        // Edit code: read + search + edit + run command for validation.
        .edit_code => .{
            .tools = &.{
                .read_file,   .search,          .codebase_search, .propose_edit, .multi_edit,
                .run_command, .lsp_diagnostics,
            },
            .profile = .propose_and_task,
        },
        // Refactor: read + search + LSP refs + multi-edit (span multiple files).
        .refactor => .{
            .tools = &.{
                .read_file,           .read_many_files, .search,     .codebase_search,
                .lsp_find_references, .lsp_definition,  .multi_edit, .run_command,
            },
            .profile = .propose_and_task,
        },
        // Add test: read + edit + run command (to run the test).
        .add_test => .{
            .tools = &.{
                .read_file, .search, .propose_edit, .run_command,
            },
            .profile = .propose,
        },
        // Add feature: read + search + edit + maybe multi-file.
        .add_feature => .{
            .tools = &.{
                .read_file,   .search,          .codebase_search, .propose_edit, .multi_edit,
                .run_command, .lsp_diagnostics,
            },
            .profile = .propose_and_task,
        },
        // Add doc: read + edit (simple single-file usually).
        .add_doc => .{
            .tools = &.{
                .read_file, .search, .propose_edit,
            },
            .profile = .propose,
        },
        // Debug: read + search + run command + edit + LSP diagnostics.
        .debug_failure => .{
            .tools = &.{
                .read_file,   .read_many_files, .search,       .codebase_search,
                .run_command, .lsp_diagnostics, .propose_edit, .multi_edit,
                .git_diff,
            },
            .profile = .propose_and_task,
        },
        // Fix compile error: read + run command (to see errors) + edit.
        .fix_compile_error => .{
            .tools = &.{
                .read_file, .run_command, .lsp_diagnostics, .propose_edit, .multi_edit,
            },
            .profile = .propose_and_task,
        },
    };
}

/// Check if a tool is in the selection.
pub fn isSelected(selection: ToolSelection, tool: tools.ToolId) bool {
    for (selection.tools) |t| {
        if (t == tool) return true;
    }
    return false;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "answer_question gets read-only tools only" {
    const sel = selectForIntent(.answer_question);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, sel.profile);
    try std.testing.expect(isSelected(sel, .read_file));
    try std.testing.expect(isSelected(sel, .search));
    try std.testing.expect(!isSelected(sel, .propose_edit));
    try std.testing.expect(!isSelected(sel, .run_command));
}

test "edit_code gets propose_edit + run_command" {
    const sel = selectForIntent(.edit_code);
    try std.testing.expectEqual(tools.CapabilityProfile.propose_and_task, sel.profile);
    try std.testing.expect(isSelected(sel, .propose_edit));
    try std.testing.expect(isSelected(sel, .run_command));
    try std.testing.expect(isSelected(sel, .multi_edit));
}

test "refactor gets lsp_find_references + multi_edit" {
    const sel = selectForIntent(.refactor);
    try std.testing.expect(isSelected(sel, .lsp_find_references));
    try std.testing.expect(isSelected(sel, .multi_edit));
    try std.testing.expect(isSelected(sel, .read_many_files));
}

test "debug_failure gets run_command + git_diff" {
    const sel = selectForIntent(.debug_failure);
    try std.testing.expect(isSelected(sel, .run_command));
    try std.testing.expect(isSelected(sel, .git_diff));
    try std.testing.expect(isSelected(sel, .lsp_diagnostics));
}

test "code_review gets git_diff but no edit tools" {
    const sel = selectForIntent(.code_review);
    try std.testing.expectEqual(tools.CapabilityProfile.read_only, sel.profile);
    try std.testing.expect(isSelected(sel, .git_diff));
    try std.testing.expect(!isSelected(sel, .propose_edit));
}

test "all selected tools are allowed by the capability profile" {
    const all = [_]intent_taxonomy.Intent{
        .answer_question, .explore_codebase,  .code_review, .edit_code,
        .refactor,        .add_test,          .add_feature, .add_doc,
        .debug_failure,   .fix_compile_error, .plan_change,
    };
    for (all) |intent| {
        const sel = selectForIntent(intent);
        for (sel.tools) |tool| {
            try std.testing.expect(
                tools.isAllowed(sel.profile, tool),
            );
        }
    }
}

test "tool selection is non-empty for all intents" {
    const all = [_]intent_taxonomy.Intent{
        .answer_question, .explore_codebase,  .code_review, .edit_code,
        .refactor,        .add_test,          .add_feature, .add_doc,
        .debug_failure,   .fix_compile_error, .plan_change,
    };
    for (all) |intent| {
        const sel = selectForIntent(intent);
        try std.testing.expect(sel.tools.len >= 3);
    }
}

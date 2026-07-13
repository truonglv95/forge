const std = @import("std");

/// Capability profiles gate which tools an agent session may invoke.
pub const CapabilityProfile = enum {
    read_only,
    propose,
    propose_and_task,
};

pub const Mode = enum { ask, plan, agent };

pub fn profileForMode(mode: Mode) CapabilityProfile {
    return switch (mode) {
        .ask, .plan => .read_only,
        .agent => .propose_and_task,
    };
}

pub const ToolId = enum {
    read_file,
    git_diff,
    search,
    codebase_search,
    lsp_workspace_symbol,
    lsp_find_references,
    find_files,
    remember,
    fetch_url,
    list_tree,
    run_task,
    run_command,
    propose_edit,
    multi_edit,
    apply_proposal,
    undo,
    show_context,
    spawn_subagent,
    diff_preview,
};

pub fn isAllowed(profile: CapabilityProfile, tool: ToolId) bool {
    return switch (profile) {
        .read_only => switch (tool) {
            .read_file, .git_diff, .search, .codebase_search, .lsp_workspace_symbol, .lsp_find_references, .find_files, .fetch_url, .list_tree, .show_context, .diff_preview => true,
            else => false,
        },
        .propose => switch (tool) {
            .read_file, .git_diff, .search, .codebase_search, .lsp_workspace_symbol, .lsp_find_references, .find_files, .fetch_url, .list_tree, .show_context, .propose_edit, .multi_edit, .remember, .run_command, .diff_preview => true,
            else => false,
        },
        .propose_and_task => switch (tool) {
            .apply_proposal => false,
            else => true,
        },
    };
}

pub fn name(tool: ToolId) []const u8 {
    return switch (tool) {
        .read_file => "read_file",
        .git_diff => "git_diff",
        .search => "search",
        .codebase_search => "codebase_search",
        .lsp_workspace_symbol => "lsp_workspace_symbol",
        .lsp_find_references => "lsp_find_references",
        .find_files => "find_files",
        .remember => "remember",
        .fetch_url => "fetch_url",
        .list_tree => "list_tree",
        .run_task => "run_task",
        .run_command => "run_command",
        .propose_edit => "propose_edit",
        .multi_edit => "multi_edit",
        .apply_proposal => "apply_proposal",
        .undo => "undo",
        .show_context => "show_context",
        .spawn_subagent => "spawn_subagent",
        .diff_preview => "diff_preview",
    };
}

/// Wire name exposed to LLM function-calling APIs (may differ from internal ToolId).
pub fn wireName(tool: ToolId) []const u8 {
    return switch (tool) {
        .propose_edit => "replace_file_content",
        .multi_edit => "multi_edit",
        .spawn_subagent => "spawn_subagent",
        .diff_preview => "diff_preview",
        else => name(tool),
    };
}

pub fn idFromWire(wire_name: []const u8) ?ToolId {
    if (std.mem.eql(u8, wire_name, "replace_file_content")) return .propose_edit;
    if (std.mem.eql(u8, wire_name, "multi_edit")) return .multi_edit;
    if (std.mem.eql(u8, wire_name, "spawn_subagent")) return .spawn_subagent;
    if (std.mem.eql(u8, wire_name, "diff_preview")) return .diff_preview;
    inline for (@typeInfo(ToolId).@"enum".fields) |field| {
        const id: ToolId = @enumFromInt(@intFromEnum(@field(ToolId, field.name)));
        if (std.mem.eql(u8, wire_name, name(id))) return id;
    }
    return null;
}

pub fn isAllowedWire(profile: CapabilityProfile, wire_name: []const u8) bool {
    const id = idFromWire(wire_name) orelse return false;
    return isAllowed(profile, id);
}

test "capability profiles gate destructive tools" {
    try std.testing.expect(isAllowed(.read_only, .search));
    try std.testing.expect(!isAllowed(.read_only, .propose_edit));
    try std.testing.expect(isAllowed(.propose, .propose_edit));
    try std.testing.expect(!isAllowed(.propose, .apply_proposal));
    try std.testing.expect(isAllowed(.propose_and_task, .run_task));
    try std.testing.expect(!isAllowed(.propose_and_task, .apply_proposal));
}

test "AI modes map to least-privilege tool profiles" {
    try std.testing.expectEqual(CapabilityProfile.read_only, profileForMode(.ask));
    try std.testing.expectEqual(CapabilityProfile.read_only, profileForMode(.plan));
    try std.testing.expectEqual(CapabilityProfile.propose_and_task, profileForMode(.agent));
}

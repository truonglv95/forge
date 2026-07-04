const std = @import("std");

/// Capability profiles gate which tools an agent session may invoke.
pub const CapabilityProfile = enum {
    read_only,
    propose,
    propose_and_task,
};

pub const ToolId = enum {
    read_file,
    search,
    codebase_search,
    remember,
    fetch_url,
    list_tree,
    run_task,
    propose_edit,
    apply_proposal,
    undo,
    show_context,
};

pub fn isAllowed(profile: CapabilityProfile, tool: ToolId) bool {
    return switch (profile) {
        .read_only => switch (tool) {
            .read_file, .search, .codebase_search, .fetch_url, .list_tree, .show_context => true,
            else => false,
        },
        .propose => switch (tool) {
            .read_file, .search, .codebase_search, .fetch_url, .list_tree, .show_context, .propose_edit, .remember => true,
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
        .search => "search",
        .codebase_search => "codebase_search",
        .remember => "remember",
        .fetch_url => "fetch_url",
        .list_tree => "list_tree",
        .run_task => "run_task",
        .propose_edit => "propose_edit",
        .apply_proposal => "apply_proposal",
        .undo => "undo",
        .show_context => "show_context",
    };
}

test "capability profiles gate destructive tools" {
    try std.testing.expect(isAllowed(.read_only, .search));
    try std.testing.expect(!isAllowed(.read_only, .propose_edit));
    try std.testing.expect(isAllowed(.propose, .propose_edit));
    try std.testing.expect(!isAllowed(.propose, .apply_proposal));
    try std.testing.expect(isAllowed(.propose_and_task, .run_task));
    try std.testing.expect(!isAllowed(.propose_and_task, .apply_proposal));
}

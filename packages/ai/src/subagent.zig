const std = @import("std");

/// Maps native tool names to subagent channel labels shown in the agent UI.
pub const Kind = enum {
    explore,
    bash,
    memory,
    web,
    mcp,
    propose,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .explore => "explore",
            .bash => "bash",
            .memory => "remember",
            .web => "web",
            .mcp => "mcp",
            .propose => "propose",
        };
    }
};

pub fn toolActionLabel(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "search") or std.mem.eql(u8, tool_name, "codebase_search"))
        return "Searching codebase...";
    if (std.mem.eql(u8, tool_name, "list_tree")) return "Listing workspace tree...";
    if (std.mem.eql(u8, tool_name, "read_file")) return "Reading file...";
    if (std.mem.eql(u8, tool_name, "grep")) return "Searching files...";
    if (std.mem.eql(u8, tool_name, "run_command") or std.mem.eql(u8, tool_name, "run_task"))
        return "Running command...";
    if (std.mem.eql(u8, tool_name, "remember")) return "Saving memory...";
    if (std.mem.eql(u8, tool_name, "fetch_url")) return "Fetching URL...";
    if (std.mem.eql(u8, tool_name, "propose") or std.mem.eql(u8, tool_name, "replace_file_content"))
        return "Proposing edit...";
    if (std.mem.startsWith(u8, tool_name, "mcp_")) return "Calling MCP tool...";
    return "Running tool...";
}

pub fn classifyTool(tool_name: []const u8) Kind {
    if (std.mem.startsWith(u8, tool_name, "mcp_")) return .mcp;
    if (std.mem.eql(u8, tool_name, "run_command") or std.mem.eql(u8, tool_name, "run_task"))
        return .bash;
    if (std.mem.eql(u8, tool_name, "remember")) return .memory;
    if (std.mem.eql(u8, tool_name, "fetch_url")) return .web;
    if (std.mem.eql(u8, tool_name, "propose") or std.mem.eql(u8, tool_name, "replace_file_content"))
        return .propose;
    return .explore;
}

test "classify explore tools" {
    try std.testing.expectEqual(Kind.explore, classifyTool("search"));
    try std.testing.expectEqual(Kind.explore, classifyTool("codebase_search"));
    try std.testing.expectEqual(Kind.bash, classifyTool("run_command"));
}

test "tool action labels" {
    try std.testing.expectEqualStrings("Searching codebase...", toolActionLabel("search"));
    try std.testing.expectEqualStrings("Listing workspace tree...", toolActionLabel("list_tree"));
}

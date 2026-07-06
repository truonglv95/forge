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

pub fn classifyTool(tool_name: []const u8) Kind {
    if (std.mem.startsWith(u8, tool_name, "mcp_")) return .mcp;
    if (std.mem.eql(u8, tool_name, "run_command") or std.mem.eql(u8, tool_name, "run_task"))
        return .bash;
    if (std.mem.eql(u8, tool_name, "remember")) return .memory;
    if (std.mem.eql(u8, tool_name, "fetch_url")) return .web;
    if (std.mem.eql(u8, tool_name, "propose")) return .propose;
    return .explore;
}

test "classify explore tools" {
    try std.testing.expectEqual(Kind.explore, classifyTool("search"));
    try std.testing.expectEqual(Kind.explore, classifyTool("codebase_search"));
    try std.testing.expectEqual(Kind.bash, classifyTool("run_command"));
}

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

/// Roles for parallel helper agents (sub-agents) spawned by `forge agent`.
pub const Role = enum {
    repair_log_reader,
    repair_test_writer,
    planner,
    reviewer,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .repair_log_reader => "repair_log_reader",
            .repair_test_writer => "repair_test_writer",
            .planner => "planner",
            .reviewer => "reviewer",
        };
    }
};

pub const Spec = struct {
    role: Role,
    /// Short label shown in events/manifest blocks.
    label: []const u8,
    /// Prompt prefix injected into the sub-agent intent.
    prompt: []const u8,
    /// Sub-agent step budget.
    max_steps: u32 = 3,
    /// Sub-agent context budget.
    max_bytes: usize = 256 * 1024,
};

pub fn repairSpecs() []const Spec {
    return &.{
        .{
            .role = .repair_log_reader,
            .label = "subagent:log",
            .prompt =
            \\You are a focused helper agent. Read the provided validation report and propose:
            \\- 3 likely root causes
            \\- the most likely files/areas involved (paths/symbols if possible)
            \\- a minimal reproduction / next diagnostic step (no destructive commands)
            \\Output as short bullet points.
            ,
            .max_steps = 3,
            .max_bytes = 256 * 1024,
        },
        .{
            .role = .repair_test_writer,
            .label = "subagent:test",
            .prompt =
            \\You are a focused helper agent. Based on the validation report, propose:
            \\- a minimal test case or assertion that would catch the bug
            \\- where the test should live (path) and why
            \\Keep it short and actionable.
            ,
            .max_steps = 3,
            .max_bytes = 256 * 1024,
        },
    };
}

pub fn plannerSpec() Spec {
    return .{
        .role = .planner,
        .label = "subagent:plan",
        .prompt =
        \\You are a planning specialist. Produce a short implementation plan in Markdown.
        \\Focus on: goal, key files, steps, risks, and validation.
        \\Be concise (max ~20 lines).
        ,
        .max_steps = 1,
        .max_bytes = 256 * 1024,
    };
}

pub fn reviewerSpec() Spec {
    return .{
        .role = .reviewer,
        .label = "subagent:review",
        .prompt =
        \\You are a senior code reviewer. Review the proposed change for correctness, safety, and project conventions.
        \\Output a short checklist of issues to fix, or 'LGTM' if none.
        ,
        .max_steps = 1,
        .max_bytes = 256 * 1024,
    };
}

pub fn toolActionLabel(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "search") or std.mem.eql(u8, tool_name, "codebase_search"))
        return "Searching codebase...";
    if (std.mem.eql(u8, tool_name, "list_tree")) return "Listing workspace tree...";
    if (std.mem.eql(u8, tool_name, "read_file")) return "Reading file...";
    if (std.mem.eql(u8, tool_name, "git_diff")) return "Inspecting git diff...";
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

const std = @import("std");
const capabilities = @import("../tools.zig");
const mcp_registry = @import("../mcp_registry.zig");

pub const Risk = enum { low, medium, high };
pub const Approval = enum { automatic, review, every_time };

pub const Policy = struct {
    risk: Risk,
    approval: Approval,
};

/// UI- and provider-independent policy metadata. Capability profiles still
/// decide whether a tool is available; this describes how an allowed call is
/// presented and approved.
pub fn policyFor(wire_name: []const u8) Policy {
    if (std.mem.eql(u8, wire_name, "replace_file_content")) return .{ .risk = .high, .approval = .review };
    if (std.mem.eql(u8, wire_name, "run_command") or std.mem.eql(u8, wire_name, "run_task")) {
        return .{ .risk = .high, .approval = .every_time };
    }
    if (std.mem.eql(u8, wire_name, "fetch_url") or std.mem.eql(u8, wire_name, "remember")) {
        return .{ .risk = .medium, .approval = .every_time };
    }
    if (capabilities.idFromWire(wire_name) != null) return .{ .risk = .low, .approval = .automatic };
    // MCP tools do not yet carry a trusted local policy declaration.
    return .{ .risk = .high, .approval = .every_time };
}

/// Canonical JSON array of native tool declarations (Gemini functionDeclarations shape).
pub const native_declarations_json =
    \\[{"name":"search","description":"Grep workspace files for literal text. Use short keywords or a|b alternation; never paste the full user sentence. Prefer grep before semantic search.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Literal text or a|b|c alternation"},"term":{"type":"string","description":"Alias for pattern"},"path":{"type":"string","description":"Workspace-relative directory scope, default ."},"glob":{"type":"string","description":"Optional filename glob such as *.py"},"case_sensitive":{"type":"boolean","description":"Default false"},"head_limit":{"type":"integer","description":"Max matches, default 50"}}}},{"name":"codebase_search","description":"Semantic search across the indexed codebase using embeddings","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Natural language search query"}},"required":["query"]}},{"name":"remember","description":"Persist a project memory (preference, decision, fact, or note) for future agent sessions","parameters":{"type":"object","properties":{"content":{"type":"string","description":"Memory text to store"},"kind":{"type":"string","description":"preference, decision, fact, or note"},"tags":{"type":"array","items":{"type":"string"},"description":"Optional tags"}},"required":["content"]}},{"name":"fetch_url","description":"Fetch external web documentation from an http(s) URL","parameters":{"type":"object","properties":{"url":{"type":"string","description":"Public http or https URL"}},"required":["url"]}},{"name":"list_tree","description":"List a bounded workspace subtree","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative directory, default ."},"depth":{"type":"integer","description":"Maximum depth, capped at 8"}}}},{"name":"read_file","description":"Read a bounded line range with line numbers and snapshot hash","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"start_line":{"type":"integer","description":"Optional 1-indexed first line"},"end_line":{"type":"integer","description":"Optional 1-indexed last line"}},"required":["path"]}},{"name":"run_command","description":"Run one exact allowlisted validation or read-only command without a shell","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Exact allowlisted command"}},"required":["command"]}},{"name":"replace_file_content","description":"Directly replace a contiguous line range in the editor buffer. Use this to implement requested code changes after reading the relevant file.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"start_line":{"type":"integer","description":"1-indexed start line (inclusive); use 0 with end_line 0 to create/replace the whole file"},"end_line":{"type":"integer","description":"1-indexed end line (inclusive); use 0 with start_line 0 to create/replace the whole file"},"replacement":{"type":"string","description":"The exact replacement content"}},"required":["path","start_line","end_line","replacement"]}}]
;

pub fn allowedNativeTool(wire_name: []const u8, profile: capabilities.CapabilityProfile) bool {
    return capabilities.isAllowedWire(profile, wire_name);
}

pub fn isToolAllowed(
    wire_name: []const u8,
    profile: capabilities.CapabilityProfile,
    mcp: ?*const mcp_registry.Registry,
) bool {
    if (allowedNativeTool(wire_name, profile)) return true;
    if (profile == .propose_and_task) {
        if (mcp) |reg| return reg.hasTool(wire_name);
    }
    return false;
}

pub fn filterDeclarationsForProfile(
    allocator: std.mem.Allocator,
    declarations_json: []const u8,
    profile: capabilities.CapabilityProfile,
) ![]u8 {
    const Decl = struct {
        name: []const u8,
        description: []const u8 = "",
        parameters: std.json.Value,
    };
    var parsed = try std.json.parseFromSlice([]const Decl, allocator, declarations_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var allowed: std.ArrayList(Decl) = .empty;
    defer allowed.deinit(allocator);
    for (parsed.value) |decl| {
        const native_allowed = allowedNativeTool(decl.name, profile);
        const mcp_allowed = capabilities.idFromWire(decl.name) == null and profile == .propose_and_task;
        if (native_allowed or mcp_allowed) try allowed.append(allocator, decl);
    }
    return std.json.Stringify.valueAlloc(allocator, allowed.items, .{});
}

test "allowedNativeTool gates read_file" {
    try std.testing.expect(allowedNativeTool("search", .propose));
    try std.testing.expect(allowedNativeTool("read_file", .read_only));
    try std.testing.expect(!allowedNativeTool("replace_file_content", .read_only));
}

test "tool policy distinguishes observation, mutation, and execution" {
    try std.testing.expectEqual(Approval.automatic, policyFor("read_file").approval);
    try std.testing.expectEqual(Approval.review, policyFor("replace_file_content").approval);
    try std.testing.expectEqual(Approval.every_time, policyFor("run_command").approval);
    try std.testing.expectEqual(Approval.every_time, policyFor("mcp_unknown_tool").approval);
}

test "declarations are filtered before reaching each mode" {
    const allocator = std.testing.allocator;
    const ask = try filterDeclarationsForProfile(allocator, native_declarations_json, .read_only);
    defer allocator.free(ask);
    try std.testing.expect(std.mem.indexOf(u8, ask, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask, "replace_file_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, ask, "run_command") == null);

    const agent = try filterDeclarationsForProfile(allocator, native_declarations_json, .propose_and_task);
    defer allocator.free(agent);
    try std.testing.expect(std.mem.indexOf(u8, agent, "replace_file_content") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent, "run_command") != null);

    const with_mcp =
        \\[{"name":"read_file","description":"read","parameters":{"type":"object"}},{"name":"mcp_issue_create","description":"external mutation","parameters":{"type":"object"}}]
    ;
    const plan = try filterDeclarationsForProfile(allocator, with_mcp, .read_only);
    defer allocator.free(plan);
    try std.testing.expect(std.mem.indexOf(u8, plan, "mcp_issue_create") == null);
    const agent_mcp = try filterDeclarationsForProfile(allocator, with_mcp, .propose_and_task);
    defer allocator.free(agent_mcp);
    try std.testing.expect(std.mem.indexOf(u8, agent_mcp, "mcp_issue_create") != null);
}

/// Convert Gemini-style functionDeclarations JSON to Ollama `tools` array entries.
pub fn geminiDeclarationsToOllama(allocator: std.mem.Allocator, gemini_declarations: []const u8) ![]u8 {
    const Decl = struct {
        name: []const u8,
        description: []const u8,
        parameters: std.json.Value,
    };
    var parsed = try std.json.parseFromSlice([]const Decl, allocator, gemini_declarations, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (parsed.value, 0..) |decl, i| {
        if (i > 0) try out.append(allocator, ',');
        const params_json = try std.json.Stringify.valueAlloc(allocator, decl.parameters, .{});
        defer allocator.free(params_json);
        const desc_escaped = try jsonEscape(allocator, decl.description);
        defer allocator.free(desc_escaped);
        const piece = try std.fmt.allocPrint(allocator,
            \\{{"type":"function","function":{{"name":"{s}","description":{s},"parameters":{s}}}}}
        , .{ decl.name, desc_escaped, params_json });
        defer allocator.free(piece);
        try out.appendSlice(allocator, piece);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn jsonEscape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

test "geminiDeclarationsToOllama wraps native tools" {
    const allocator = std.testing.allocator;
    const ollama = try geminiDeclarationsToOllama(allocator, native_declarations_json);
    defer allocator.free(ollama);
    try std.testing.expect(std.mem.startsWith(u8, ollama, "[{\"type\":\"function\""));
    try std.testing.expect(std.mem.indexOf(u8, ollama, "\"name\":\"search\"") != null);
}

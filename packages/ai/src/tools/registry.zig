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
    if (std.mem.eql(u8, wire_name, "multi_edit")) return .{ .risk = .high, .approval = .review };
    if (std.mem.eql(u8, wire_name, "run_command") or std.mem.eql(u8, wire_name, "run_task") or std.mem.eql(u8, wire_name, "git_stage") or std.mem.eql(u8, wire_name, "git_commit")) {
        return .{ .risk = .high, .approval = .every_time };
    }
    if (std.mem.eql(u8, wire_name, "fetch_url") or std.mem.eql(u8, wire_name, "remember")) {
        return .{ .risk = .medium, .approval = .every_time };
    }
    if (std.mem.eql(u8, wire_name, "spawn_subagent")) return .{ .risk = .medium, .approval = .automatic };
    if (capabilities.idFromWire(wire_name) != null) return .{ .risk = .low, .approval = .automatic };
    // MCP tools: check annotations for readOnly hint via mcp_capability.
    return .{ .risk = .high, .approval = .every_time };
}

/// Like policyFor but checks MCP tool annotations for capability hints.
/// When annotations indicate readOnly=true, returns low/automatic instead
/// of high/every_time. This reduces approval noise for read-only MCP tools.
pub fn policyForMcp(wire_name: []const u8, annotations_json: ?[]const u8) Policy {
    // Check native tools first.
    const native = policyFor(wire_name);
    if (capabilities.idFromWire(wire_name) != null) return native;

    // For MCP tools, check annotations.
    if (annotations_json) |annotations| {
        const mcp_policy = @import("../mcp_capability.zig").inferPolicy(annotations);
        return switch (mcp_policy.capability) {
            .read_only => .{ .risk = .low, .approval = .automatic },
            .mutate => .{ .risk = .high, .approval = .every_time },
            .unknown => native,
        };
    }
    return native;
}

/// Canonical JSON array of native tool declarations (Gemini functionDeclarations shape).
pub const native_declarations_json =
    \\[{"name":"search","description":"Grep workspace files for literal text. Use short keywords or a|b alternation; never paste the full user sentence. Prefer grep before semantic search.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Literal text or a|b|c alternation"},"term":{"type":"string","description":"Alias for pattern"},"path":{"type":"string","description":"Workspace-relative directory scope, default ."},"glob":{"type":"string","description":"Optional filename glob such as *.py"},"case_sensitive":{"type":"boolean","description":"Default false"},"head_limit":{"type":"integer","description":"Max matches, default 50"},"context_lines":{"type":"integer","description":"Lines of context before and after each match (like grep -C N), default 0, max 10"}}}},{"name":"codebase_search","description":"Semantic search across the indexed codebase using embeddings","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Natural language search query"}},"required":["query"]}},{"name":"lsp_workspace_symbol","description":"Query the Language Server (LSP) for workspace symbols (types, functions, classes).","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Symbol name to search for"}},"required":["query"]}},{"name":"lsp_find_references","description":"Query the Language Server (LSP) for references to a symbol at a specific file and position. Use this after finding a symbol's definition using lsp_workspace_symbol to see where it is used.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file containing the symbol"},"line":{"type":"integer","description":"0-indexed line number of the symbol"},"character":{"type":"integer","description":"0-indexed character position of the symbol"}},"required":["path","line","character"]}},{"name":"remember","description":"Persist a project memory (preference, decision, fact, or note) for future agent sessions","parameters":{"type":"object","properties":{"content":{"type":"string","description":"Memory text to store"},"kind":{"type":"string","description":"preference, decision, fact, or note"},"tags":{"type":"array","items":{"type":"string"},"description":"Optional tags"}},"required":["content"]}},{"name":"fetch_url","description":"Fetch external web documentation from an http(s) URL","parameters":{"type":"object","properties":{"url":{"type":"string","description":"Public http or https URL"}},"required":["url"]}},{"name":"list_tree","description":"List a bounded workspace subtree","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative directory, default ."},"depth":{"type":"integer","description":"Maximum depth, capped at 8"}}}},{"name":"find_files","description":"Find files by name substring or glob pattern without reading content. Much faster than search for locating files. Use before read_file when you need to find a file path.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Filename substring, glob (*.zig), or path glob (src/**/*.ts)"},"path":{"type":"string","description":"Workspace-relative root directory, default ."},"head_limit":{"type":"integer","description":"Max results, default 50"}},"required":["pattern"]}},{"name":"read_file","description":"Read a bounded line range with line numbers and snapshot hash. Do not use this for git diff; use git_diff instead.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"start_line":{"type":"integer","description":"Optional 1-indexed first line"},"end_line":{"type":"integer","description":"Optional 1-indexed last line"}},"required":["path"]}},{"name":"git_diff","description":"Show the current working tree git diff. Use this to inspect local changes; do not call read_file with path git_diff.","parameters":{"type":"object","properties":{"stat":{"type":"boolean","description":"When true, return only git diff --stat. Default false"}}}},{"name":"run_command","description":"Run one exact allowlisted validation or read-only command without a shell","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Exact allowlisted command"}},"required":["command"]}},{"name":"replace_file_content","description":"Directly replace blocks of code in a single file using exact or fuzzy search matching. Use multi_edit instead when you need to change multiple files atomically (e.g. rename a symbol across callers).","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"edits":{"type":"array","items":{"type":"object","properties":{"search":{"type":"string","description":"The exact original code block to replace (including whitespace)."},"replace":{"type":"string","description":"The new code block."}},"required":["search","replace"]}}},"required":["path","edits"]}},{"name":"multi_edit","description":"Atomically edit multiple files in a single proposal. Use for cross-file refactors: rename a symbol and update all callers, change a function signature + its uses, update a type + all references. All edits apply together or none do (transactional).","parameters":{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"edits":{"type":"array","items":{"type":"object","properties":{"search":{"type":"string","description":"The exact original code block to replace (including whitespace)."},"replace":{"type":"string","description":"The new code block."}},"required":["search","replace"]}}},"required":["path","edits"]}}},"required":["files"]}},{"name":"diff_preview","description":"Preview the unified diff of a search/replace operation before applying it. Use this to verify your search block matches the actual file content.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"search":{"type":"string","description":"The exact original code block to search for."},"replace":{"type":"string","description":"The new code block."}},"required":["path","search","replace"]}},{"name":"spawn_subagent","description":"Spawn a focused sub-agent for a sub-task (e.g. read logs and propose fixes, write a test, review a change). The sub-agent runs in its own context with a smaller budget and returns a short text result. Use for parallelizable sub-tasks that don't need the full main-agent context.","parameters":{"type":"object","properties":{"role":{"type":"string","description":"Sub-agent role: repair_log_reader | repair_test_writer | planner | reviewer | custom"},"prompt":{"type":"string","description":"Task instruction for the sub-agent"}},"required":["role","prompt"]}},{"name":"get_editor_context","description":"Get the user's active editor context: the file they are looking at, their cursor position, and any selected text. Use this to understand what the user is currently focused on when they ask questions like 'what does this do?' or 'fix this'.","parameters":{"type":"object","properties":{}}},{"name":"read_many_files","description":"Read multiple files simultaneously. Use this to read the context of multiple files efficiently in a single step instead of calling read_file multiple times.","parameters":{"type":"object","properties":{"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"start_line":{"type":"integer","description":"Optional 1-indexed first line"},"end_line":{"type":"integer","description":"Optional 1-indexed last line"}},"required":["path"]}}},"required":["files"]}},{"name":"lsp_definition","description":"Query the Language Server (LSP) for the definition of a symbol at a specific file and position.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file"},"line":{"type":"integer","description":"0-indexed line number"},"character":{"type":"integer","description":"0-indexed character position"}},"required":["path","line","character"]}},{"name":"lsp_hover","description":"Query the Language Server (LSP) for hover information (type, documentation) of a symbol at a specific file and position.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file"},"line":{"type":"integer","description":"0-indexed line number"},"character":{"type":"integer","description":"0-indexed character position"}},"required":["path","line","character"]}},{"name":"lsp_document_symbols","description":"Query the Language Server (LSP) for the document symbols (outline) of a specific file.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file"}},"required":["path"]}},{"name":"lsp_diagnostics","description":"Query the IDE for compiler/language diagnostics (errors, warnings) in a specific file. Use this to find compilation errors before proposing fixes.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file"}},"required":["path"]}},{"name":"git_stage","description":"Stage files for git commit.","parameters":{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"},"description":"Relative paths to the files to stage"}},"required":["paths"]}},{"name":"git_commit","description":"Commit staged files.","parameters":{"type":"object","properties":{"message":{"type":"string","description":"Commit message"}},"required":["message"]}}]
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
    try std.testing.expect(allowedNativeTool("git_diff", .read_only));
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

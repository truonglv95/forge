const std = @import("std");
const capabilities = @import("../tools.zig");
const mcp_registry = @import("../mcp_registry.zig");

/// Canonical JSON array of native tool declarations (Gemini functionDeclarations shape).
pub const native_declarations_json =
    \\[{"name":"search","description":"Search workspace file contents for a term","parameters":{"type":"object","properties":{"term":{"type":"string","description":"Search term"}},"required":["term"]}},{"name":"codebase_search","description":"Semantic search across the indexed codebase using embeddings","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Natural language search query"}},"required":["query"]}},{"name":"remember","description":"Persist a project memory (preference, decision, fact, or note) for future agent sessions","parameters":{"type":"object","properties":{"content":{"type":"string","description":"Memory text to store"},"kind":{"type":"string","description":"preference, decision, fact, or note"},"tags":{"type":"array","items":{"type":"string"},"description":"Optional tags"}},"required":["content"]}},{"name":"fetch_url","description":"Fetch external web documentation from an http(s) URL","parameters":{"type":"object","properties":{"url":{"type":"string","description":"Public http or https URL"}},"required":["url"]}},{"name":"list_tree","description":"List files and directories in the workspace","parameters":{"type":"object","properties":{}}},{"name":"read_file","description":"Read a workspace file by relative path","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"}},"required":["path"]}},{"name":"run_command","description":"Run one exact allowlisted validation or read-only command without a shell","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Exact allowlisted command"}},"required":["command"]}},{"name":"replace_file_content","description":"Replace a contiguous block of lines in a file. The IDE will stream this edit inline to the user. Use 1-indexed lines.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"start_line":{"type":"integer","description":"1-indexed start line (inclusive)"},"end_line":{"type":"integer","description":"1-indexed end line (inclusive)"},"replacement":{"type":"string","description":"The new content"}},"required":["path","start_line","end_line","replacement"]}}]
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
    if (mcp) |reg| return reg.hasTool(wire_name);
    return false;
}

test "allowedNativeTool gates read_file" {
    try std.testing.expect(allowedNativeTool("search", .propose));
    try std.testing.expect(allowedNativeTool("read_file", .read_only));
    try std.testing.expect(!allowedNativeTool("replace_file_content", .read_only));
}

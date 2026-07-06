const std = @import("std");
const tools = @import("tools.zig");

/// Static JSON fragment for Gemini functionDeclarations (propose profile).
pub const function_declarations_json =
    \\[{"name":"search","description":"Search workspace file contents for a term","parameters":{"type":"object","properties":{"term":{"type":"string","description":"Search term"}},"required":["term"]}},{"name":"codebase_search","description":"Semantic search across the indexed codebase using embeddings","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Natural language search query"}},"required":["query"]}},{"name":"remember","description":"Persist a project memory (preference, decision, fact, or note) for future agent sessions","parameters":{"type":"object","properties":{"content":{"type":"string","description":"Memory text to store"},"kind":{"type":"string","description":"preference, decision, fact, or note"},"tags":{"type":"array","items":{"type":"string"},"description":"Optional tags"}},"required":["content"]}},{"name":"fetch_url","description":"Fetch external web documentation from an http(s) URL","parameters":{"type":"object","properties":{"url":{"type":"string","description":"Public http or https URL"}},"required":["url"]}},{"name":"list_tree","description":"List files and directories in the workspace","parameters":{"type":"object","properties":{}}},{"name":"read_file","description":"Read a workspace file by relative path","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"}},"required":["path"]}},{"name":"run_command","description":"Run a read-only shell command in the workspace (zig build, git status/diff, ls, find)","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Shell command"}},"required":["command"]}},{"name":"replace_file_content","description":"Replace a contiguous block of lines in a file. The IDE will stream this edit inline to the user. Use 1-indexed lines.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Relative file path"},"start_line":{"type":"integer","description":"1-indexed start line (inclusive)"},"end_line":{"type":"integer","description":"1-indexed end line (inclusive)"},"replacement":{"type":"string","description":"The new content"}},"required":["path","start_line","end_line","replacement"]}}]
;

pub const FunctionCall = struct {
    name: []const u8,
    args_json: []const u8,

    pub fn deinit(self: *FunctionCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.args_json);
        self.* = undefined;
    }
};

pub fn isToolAllowed(name: []const u8, profile: tools.CapabilityProfile, mcp: ?*const @import("mcp_registry.zig").Registry) bool {
    if (allowedNativeTool(name, profile)) return true;
    if (mcp) |reg| return reg.hasTool(name);
    return false;
}

pub fn allowedNativeTool(name: []const u8, profile: tools.CapabilityProfile) bool {
    if (std.mem.eql(u8, name, "search")) return tools.isAllowed(profile, .search);
    if (std.mem.eql(u8, name, "codebase_search")) return tools.isAllowed(profile, .codebase_search);
    if (std.mem.eql(u8, name, "remember")) return tools.isAllowed(profile, .remember);
    if (std.mem.eql(u8, name, "fetch_url")) return tools.isAllowed(profile, .fetch_url);
    if (std.mem.eql(u8, name, "list_tree")) return tools.isAllowed(profile, .list_tree);
    if (std.mem.eql(u8, name, "read_file")) return tools.isAllowed(profile, .read_file);
    if (std.mem.eql(u8, name, "run_command")) return tools.isAllowed(profile, .run_command);
    if (std.mem.eql(u8, name, "replace_file_content")) return tools.isAllowed(profile, .propose_edit);
    return false;
}

pub fn parseSearchTerm(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const Args = struct { term: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const term = parsed.value.term orelse return error.MissingArg;
    return try allocator.dupe(u8, term);
}

pub fn parseCodebaseQuery(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const Args = struct { query: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const query = parsed.value.query orelse return error.MissingArg;
    return try allocator.dupe(u8, query);
}

pub fn parseReadPath(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const Args = struct { path: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const path = parsed.value.path orelse return error.MissingArg;
    return try allocator.dupe(u8, path);
}

pub fn parseFetchUrl(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const Args = struct { url: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const url = parsed.value.url orelse return error.MissingArg;
    return try allocator.dupe(u8, url);
}

pub fn parseRunCommand(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const Args = struct { command: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const command = parsed.value.command orelse return error.MissingArg;
    return try allocator.dupe(u8, command);
}

pub const ReplaceFileContentArgs = struct {
    path: []const u8,
    start_line: usize,
    end_line: usize,
    replacement: []const u8,
};

pub fn parseReplaceFileContentArgs(allocator: std.mem.Allocator, args_json: []const u8) !ReplaceFileContentArgs {
    const Args = struct {
        path: ?[]const u8 = null,
        start_line: ?usize = null,
        end_line: ?usize = null,
        replacement: ?[]const u8 = null,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const path = parsed.value.path orelse return error.MissingArg;
    const start_line = parsed.value.start_line orelse return error.MissingArg;
    const end_line = parsed.value.end_line orelse return error.MissingArg;
    const replacement = parsed.value.replacement orelse return error.MissingArg;

    return .{
        .path = try allocator.dupe(u8, path),
        .start_line = start_line,
        .end_line = end_line,
        .replacement = try allocator.dupe(u8, replacement),
    };
}

pub const RememberArgs = struct {
    content: []const u8,
    kind: []const u8,
    tags: []const []const u8,
};

pub fn parseRememberArgs(allocator: std.mem.Allocator, args_json: []const u8) !RememberArgs {
    const Args = struct {
        content: ?[]const u8 = null,
        kind: ?[]const u8 = null,
        tags: ?[]const []const u8 = null,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const content = parsed.value.content orelse return error.MissingArg;
    const kind = parsed.value.kind orelse "note";
    const tags = parsed.value.tags orelse &[_][]const u8{};

    var owned_tags: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned_tags.items) |tag| allocator.free(tag);
        owned_tags.deinit(allocator);
    }
    for (tags) |tag| try owned_tags.append(allocator, try allocator.dupe(u8, tag));

    return .{
        .content = try allocator.dupe(u8, content),
        .kind = try allocator.dupe(u8, kind),
        .tags = try owned_tags.toOwnedSlice(allocator),
    };
}

pub fn freeRememberArgs(allocator: std.mem.Allocator, args: RememberArgs) void {
    allocator.free(args.content);
    allocator.free(args.kind);
    for (args.tags) |tag| allocator.free(tag);
    allocator.free(args.tags);
}

test "allowedNativeTool gates read_file" {
    try std.testing.expect(allowedNativeTool("search", .propose));
    try std.testing.expect(!allowedNativeTool("read_file", .read_only));
}

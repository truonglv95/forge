const std = @import("std");

fn cleanJson(input: []const u8) []const u8 {
    var s = std.mem.trim(u8, input, " \n\r\t");
    if (std.mem.startsWith(u8, s, "```json")) {
        s = s[7..];
        s = std.mem.trim(u8, s, " \n\r\t");
    } else if (std.mem.startsWith(u8, s, "```")) {
        s = s[3..];
        s = std.mem.trim(u8, s, " \n\r\t");
    }
    if (std.mem.endsWith(u8, s, "```")) {
        s = s[0 .. s.len - 3];
        s = std.mem.trim(u8, s, " \n\r\t");
    }
    if (s.len == 0) return "{}";
    return s;
}

pub const ToolCall = struct {
    name: []const u8,
    args_json: []const u8,

    pub fn deinit(self: *ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.args_json);
        self.* = undefined;
    }
};

pub const ReplaceFileContentArgs = struct {
    path: []const u8,
    edits: []const Edit,

    pub const Edit = struct {
        search: []const u8,
        replace: []const u8,
    };
};

pub const ReadFileArgs = struct {
    path: []const u8,
    start_line: ?usize,
    end_line: ?usize,
};

pub const ListTreeArgs = struct {
    path: []const u8,
    depth: usize,
};

pub const RememberArgs = struct {
    content: []const u8,
    kind: []const u8,
    tags: []const []const u8,
};

pub const LspWorkspaceSymbolArgs = struct {
    query: []const u8,
};

pub fn parseLspWorkspaceSymbolArgs(allocator: std.mem.Allocator, args_json: []const u8) !LspWorkspaceSymbolArgs {
    const Json = struct { query: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Json, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const query = parsed.value.query orelse return error.MissingArgument;
    return LspWorkspaceSymbolArgs{ .query = try allocator.dupe(u8, query) };
}

pub const LspFindReferencesArgs = struct {
    path: []const u8,
    line: usize,
    character: usize,
};

pub fn parseLspFindReferencesArgs(allocator: std.mem.Allocator, args_json: []const u8) !LspFindReferencesArgs {
    const Json = struct { path: ?[]const u8 = null, line: ?usize = null, character: ?usize = null };
    var parsed = try std.json.parseFromSlice(Json, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const path = parsed.value.path orelse return error.MissingArgument;
    const line = parsed.value.line orelse return error.MissingArgument;
    const character = parsed.value.character orelse return error.MissingArgument;
    return LspFindReferencesArgs{
        .path = try allocator.dupe(u8, path),
        .line = line,
        .character = character,
    };
}

pub const SearchArgs = struct {
    pattern: []const u8,
    path: []const u8,
    glob: ?[]const u8 = null,
    case_sensitive: bool = false,
    head_limit: usize = 50,
    context_lines: usize = 0,
};

pub fn parseSearchArgs(allocator: std.mem.Allocator, args_json: []const u8) !SearchArgs {
    const Json = struct {
        pattern: ?[]const u8 = null,
        term: ?[]const u8 = null,
        path: ?[]const u8 = null,
        glob: ?[]const u8 = null,
        case_sensitive: ?bool = null,
        head_limit: ?usize = null,
        context_lines: ?usize = null,
    };
    var parsed = try std.json.parseFromSlice(Json, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const raw_pattern = parsed.value.pattern orelse parsed.value.term orelse return error.MissingArg;
    const glob = if (parsed.value.glob) |g| try allocator.dupe(u8, g) else null;
    return .{
        .pattern = try allocator.dupe(u8, raw_pattern),
        .path = try allocator.dupe(u8, parsed.value.path orelse "."),
        .glob = glob,
        .case_sensitive = parsed.value.case_sensitive orelse false,
        .head_limit = @min(parsed.value.head_limit orelse 50, 200),
        .context_lines = @min(parsed.value.context_lines orelse 0, 10),
    };
}

pub fn freeSearchArgs(allocator: std.mem.Allocator, args: SearchArgs) void {
    allocator.free(args.pattern);
    allocator.free(args.path);
    if (args.glob) |glob| allocator.free(glob);
}

pub const FindFilesArgs = struct {
    pattern: []const u8,
    path: []const u8,
    head_limit: usize = 50,
};

pub fn parseFindFilesArgs(allocator: std.mem.Allocator, args_json: []const u8) !FindFilesArgs {
    const Json = struct {
        pattern: ?[]const u8 = null,
        path: ?[]const u8 = null,
        head_limit: ?usize = null,
    };
    var parsed = try std.json.parseFromSlice(Json, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const raw_pattern = parsed.value.pattern orelse return error.MissingArg;
    return .{
        .pattern = try allocator.dupe(u8, raw_pattern),
        .path = try allocator.dupe(u8, parsed.value.path orelse "."),
        .head_limit = @min(parsed.value.head_limit orelse 50, 200),
    };
}

pub fn freeFindFilesArgs(allocator: std.mem.Allocator, args: FindFilesArgs) void {
    allocator.free(args.pattern);
    allocator.free(args.path);
}

pub fn parseSearchTerm(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const args = try parseSearchArgs(allocator, args_json);
    defer freeSearchArgs(allocator, args);
    return try allocator.dupe(u8, args.pattern);
}

pub fn parseCodebaseQuery(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const Args = struct { query: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const query = parsed.value.query orelse return error.MissingArg;
    return try allocator.dupe(u8, query);
}

pub fn parseReadFileArgs(allocator: std.mem.Allocator, args_json: []const u8) !ReadFileArgs {
    const Args = struct {
        path: ?[]const u8 = null,
        start_line: ?usize = null,
        end_line: ?usize = null,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const path = parsed.value.path orelse return error.MissingArg;
    if (parsed.value.start_line != null and parsed.value.end_line != null and parsed.value.start_line.? > parsed.value.end_line.?) return error.InvalidRange;
    return .{
        .path = try allocator.dupe(u8, path),
        .start_line = parsed.value.start_line,
        .end_line = parsed.value.end_line,
    };
}

pub fn parseListTreeArgs(allocator: std.mem.Allocator, args_json: []const u8) !ListTreeArgs {
    const Args = struct { path: ?[]const u8 = null, depth: ?usize = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .path = try allocator.dupe(u8, parsed.value.path orelse "."),
        .depth = @min(parsed.value.depth orelse 3, 8),
    };
}

pub fn parseFetchUrl(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const Args = struct { url: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const url = parsed.value.url orelse return error.MissingArg;
    return try allocator.dupe(u8, url);
}

pub fn parseRunCommand(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const Args = struct { command: ?[]const u8 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const command = parsed.value.command orelse return error.MissingArg;
    return try allocator.dupe(u8, command);
}

pub fn parseReplaceFileContentArgs(allocator: std.mem.Allocator, args_json: []const u8) !ReplaceFileContentArgs {
    const JsonEdit = struct {
        search: ?[]const u8 = null,
        replace: ?[]const u8 = null,
    };
    const Args = struct {
        path: ?[]const u8 = null,
        edits: ?[]JsonEdit = null,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const path = parsed.value.path orelse return error.MissingArg;
    const json_edits = parsed.value.edits orelse return error.MissingArg;

    const edits = try allocator.alloc(ReplaceFileContentArgs.Edit, json_edits.len);
    errdefer allocator.free(edits);

    for (json_edits, 0..) |je, i| {
        edits[i] = .{
            .search = try allocator.dupe(u8, je.search orelse return error.MissingArg),
            .replace = try allocator.dupe(u8, je.replace orelse return error.MissingArg),
        };
    }

    return .{
        .path = try allocator.dupe(u8, path),
        .edits = edits,
    };
}

pub fn parseRememberArgs(allocator: std.mem.Allocator, args_json: []const u8) !RememberArgs {
    const Args = struct {
        content: ?[]const u8 = null,
        kind: ?[]const u8 = null,
        tags: ?[]const []const u8 = null,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, cleanJson(args_json), .{ .ignore_unknown_fields = true });
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

const std = @import("std");

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
    start_line: usize,
    end_line: usize,
    replacement: []const u8,
};

pub const RememberArgs = struct {
    content: []const u8,
    kind: []const u8,
    tags: []const []const u8,
};

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

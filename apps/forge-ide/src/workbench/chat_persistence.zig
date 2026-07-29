const std = @import("std");
const workspace = @import("forge-workspace");

pub const max_messages: usize = 200;
pub const max_tool_summary_bytes: usize = 180;
pub const legacy_chat_rel = ".forge/chat_history.jsonl";

pub const StoredMessage = struct {
    role: []const u8,
    content: []const u8,
    tool_index: u32 = 0,
    tool_kind: ?[]const u8 = null,
    tool_content: ?[]const u8 = null,
    tool_running: bool = false,
};

fn roleAllowed(role: []const u8) bool {
    return std.mem.eql(u8, role, "user") or
        std.mem.eql(u8, role, "agent") or
        std.mem.eql(u8, role, "tool");
}

fn utf8SafePrefixLen(text: []const u8, max_len: usize) usize {
    if (text.len <= max_len) return text.len;
    var len = max_len;
    while (len > 0 and (text[len] & 0xc0) == 0x80) : (len -= 1) {}
    return len;
}

pub fn compactToolSummaryAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return try allocator.dupe(u8, "Tool");
    const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const first_line = std.mem.trim(u8, trimmed[0..line_end], &std.ascii.whitespace);

    if (std.mem.startsWith(u8, first_line, "File `")) {
        if (std.mem.indexOfPos(u8, first_line, "File `".len, "`")) |close| {
            return try std.fmt.allocPrint(allocator, "Read {s}", .{first_line["File ".len .. close + 1]});
        }
    }
    if (std.mem.startsWith(u8, first_line, "Tree `")) {
        if (std.mem.indexOfPos(u8, first_line, "Tree `".len, "`")) |close| {
            const suffix = if (std.mem.indexOfPos(u8, first_line, close + 1, "(")) |paren|
                first_line[paren..]
            else
                "";
            return try std.fmt.allocPrint(allocator, "List {s} {s}", .{ first_line["Tree ".len .. close + 1], suffix });
        }
    }
    if (std.mem.startsWith(u8, first_line, "Edited ")) {
        const rest = first_line["Edited ".len..];
        const path_end = std.mem.indexOf(u8, rest, " (lines") orelse rest.len;
        return try std.fmt.allocPrint(allocator, "Write `{s}`", .{rest[0..path_end]});
    }
    if (std.mem.startsWith(u8, first_line, "run_command exit ")) {
        return try allocator.dupe(u8, "Run command");
    }

    const prefix_len = utf8SafePrefixLen(first_line, max_tool_summary_bytes);
    if (prefix_len < first_line.len) {
        return try std.fmt.allocPrint(allocator, "{s}...", .{first_line[0..prefix_len]});
    }
    return try allocator.dupe(u8, first_line);
}

pub fn fallbackToolSummary(kind: ?[]const u8) []const u8 {
    const k = kind orelse return "Running tool...";
    if (std.mem.eql(u8, k, "explore")) return "Explore workspace";
    if (std.mem.eql(u8, k, "bash")) return "Running command...";
    if (std.mem.eql(u8, k, "mcp")) return "Calling MCP tool...";
    if (std.mem.eql(u8, k, "web")) return "Fetching URL...";
    if (std.mem.eql(u8, k, "remember") or std.mem.eql(u8, k, "memory")) return "Saving memory...";
    if (std.mem.eql(u8, k, "propose")) return "Edit workspace";
    return "Running tool...";
}

pub fn saveMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    messages: []const StoredMessage,
) !void {
    try workspace.history.ensureLayout(allocator, io, root);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const start = if (messages.len > max_messages) messages.len - max_messages else 0;
    for (messages[start..]) |msg| {
        if (!roleAllowed(msg.role)) continue;
        const line = try std.json.Stringify.valueAlloc(allocator, .{
            .role = msg.role,
            .content = msg.content,
            .tool_index = msg.tool_index,
            .tool_kind = msg.tool_kind,
            .tool_content = msg.tool_content,
            .tool_running = msg.tool_running,
        }, .{});
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    const session_dir = try workspace.global_store.getSessionDir(allocator, io, root);
    defer allocator.free(session_dir);
    const chat_abs = try std.fmt.allocPrint(allocator, "{s}/chat_history.jsonl", .{session_dir});
    defer allocator.free(chat_abs);
    try workspace.global_store.replaceAbsoluteFile(io, chat_abs, out.items);
}

fn readLegacyWorkspaceChat(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !?[]u8 {
    var file = root.dir.openFile(io, legacy_chat_rel, .{}) catch return null;
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    if (size == 0) return null;
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

fn readChatAtSessionDir(allocator: std.mem.Allocator, io: std.Io, session_dir: []const u8) !?[]u8 {
    const chat_abs = std.fmt.allocPrint(allocator, "{s}/chat_history.jsonl", .{session_dir}) catch return null;
    defer allocator.free(chat_abs);
    return workspace.global_store.readAbsoluteFile(allocator, io, chat_abs) catch null;
}

fn loadChatContent(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !?[]u8 {
    const canonical_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return null;
    defer allocator.free(canonical_dir);

    if (try readChatAtSessionDir(allocator, io, canonical_dir)) |content| {
        return content;
    }

    const raw_dir = workspace.global_store.getSessionDirForStorageKey(allocator, root.path) catch return null;
    defer allocator.free(raw_dir);
    if (!std.mem.eql(u8, raw_dir, canonical_dir)) {
        if (try readChatAtSessionDir(allocator, io, raw_dir)) |content| {
            const chat_abs = try std.fmt.allocPrint(allocator, "{s}/chat_history.jsonl", .{canonical_dir});
            defer allocator.free(chat_abs);
            workspace.global_store.replaceAbsoluteFile(io, chat_abs, content) catch {};
            return content;
        }
    }

    if (try readLegacyWorkspaceChat(allocator, io, root)) |content| {
        const chat_abs = try std.fmt.allocPrint(allocator, "{s}/chat_history.jsonl", .{canonical_dir});
        defer allocator.free(chat_abs);
        workspace.global_store.replaceAbsoluteFile(io, chat_abs, content) catch {};
        return content;
    }

    const home_chat = workspace.global_store.joinHome(allocator, "chat_history.jsonl") catch return null;
    defer allocator.free(home_chat);
    return workspace.global_store.readAbsoluteFile(allocator, io, home_chat) catch null;
}

pub fn loadMessages(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) ![]StoredMessage {
    const read_content = loadChatContent(allocator, io, root) catch return &.{};
    defer if (read_content) |bytes| allocator.free(bytes);
    const content = read_content orelse return &.{};
    if (content.len == 0) return &.{};

    var list: std.ArrayList(StoredMessage) = .empty;
    errdefer {
        for (list.items) |msg| {
            allocator.free(msg.role);
            allocator.free(msg.content);
        }
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const JsonLine = struct {
            role: []const u8,
            content: []const u8,
            tool_index: u32 = 0,
            tool_kind: ?[]const u8 = null,
            tool_content: ?[]const u8 = null,
            tool_running: bool = false,
        };
        var parsed = std.json.parseFromSlice(JsonLine, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (parsed.value.content.len == 0) continue;
        if (!roleAllowed(parsed.value.role)) continue;
        const owned_kind = if (parsed.value.tool_kind) |kind| try allocator.dupe(u8, kind) else null;
        errdefer if (owned_kind) |kind| allocator.free(kind);
        const owned_tool_content = if (parsed.value.tool_content) |tool_text| try allocator.dupe(u8, tool_text) else null;
        errdefer if (owned_tool_content) |tool_text| allocator.free(tool_text);
        try list.append(allocator, .{
            .role = try allocator.dupe(u8, parsed.value.role),
            .content = try allocator.dupe(u8, parsed.value.content),
            .tool_index = parsed.value.tool_index,
            .tool_kind = owned_kind,
            .tool_content = owned_tool_content,
            .tool_running = parsed.value.tool_running,
        });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn freeLoadedMessages(allocator: std.mem.Allocator, messages: []const StoredMessage) void {
    for (messages) |msg| {
        allocator.free(msg.role);
        allocator.free(msg.content);
        if (msg.tool_kind) |kind| allocator.free(kind);
        if (msg.tool_content) |content| allocator.free(content);
    }
    allocator.free(messages);
}

test "save and load roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    const sample = [_]StoredMessage{
        .{ .role = "user", .content = "hello" },
        .{ .role = "agent", .content = "hi there" },
        .{ .role = "tool", .content = "Read src/main.zig", .tool_index = 1, .tool_kind = "explore", .tool_content = "```json\n{}\n```" },
    };
    try saveMessages(allocator, io, root, &sample);

    const loaded = try loadMessages(allocator, io, root);
    defer freeLoadedMessages(allocator, loaded);
    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expectEqualStrings("user", loaded[0].role);
    try std.testing.expectEqualStrings("hello", loaded[0].content);
    try std.testing.expectEqualStrings("tool", loaded[2].role);
    try std.testing.expectEqualStrings("explore", loaded[2].tool_kind.?);
    try std.testing.expectEqualStrings("```json\n{}\n```", loaded[2].tool_content.?);
}

test "compact tool summary keeps useful title" {
    const allocator = std.testing.allocator;
    const summary = "File `docs/ROADMAP.md` hash=abc bytes=120 lines=1-400\n     1 | # Roadmap";
    const compact = try compactToolSummaryAlloc(allocator, summary);
    defer allocator.free(compact);
    try std.testing.expectEqualStrings("Read `docs/ROADMAP.md`", compact);
}

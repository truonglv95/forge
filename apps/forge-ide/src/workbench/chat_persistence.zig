const std = @import("std");
const workspace = @import("forge-workspace");

pub const chat_path = ".forge/chat_history.jsonl";
pub const max_messages: usize = 200;

pub const StoredMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub fn saveMessages(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    messages: []const StoredMessage,
) !void {
    try workspace.history.ensureLayout(io, root);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const start = if (messages.len > max_messages) messages.len - max_messages else 0;
    for (messages[start..]) |msg| {
        if (!std.mem.eql(u8, msg.role, "user") and !std.mem.eql(u8, msg.role, "agent")) continue;
        const line = try std.json.Stringify.valueAlloc(allocator, .{
            .role = msg.role,
            .content = msg.content,
        }, .{});
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    const wp = try workspace.WorkspacePath.parse(chat_path);
    try workspace.atomic.replaceFile(io, root, wp, out.items);
}

pub fn loadMessages(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) ![]StoredMessage {
    const wp = workspace.WorkspacePath.parse(chat_path) catch return &.{};
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return &.{};
    defer snap.deinit();
    if (snap.content.len == 0) return &.{};

    var list: std.ArrayList(StoredMessage) = .empty;
    errdefer {
        for (list.items) |msg| {
            allocator.free(msg.role);
            allocator.free(msg.content);
        }
        list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, snap.content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const JsonLine = struct { role: []const u8, content: []const u8 };
        var parsed = std.json.parseFromSlice(JsonLine, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (parsed.value.content.len == 0) continue;
        const role_ok = std.mem.eql(u8, parsed.value.role, "user") or std.mem.eql(u8, parsed.value.role, "agent");
        if (!role_ok) continue;
        try list.append(allocator, .{
            .role = try allocator.dupe(u8, parsed.value.role),
            .content = try allocator.dupe(u8, parsed.value.content),
        });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn freeLoadedMessages(allocator: std.mem.Allocator, messages: []const StoredMessage) void {
    for (messages) |msg| {
        allocator.free(msg.role);
        allocator.free(msg.content);
    }
    allocator.free(messages);
}

test "save and load roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);

    const sample = [_]StoredMessage{
        .{ .role = "user", .content = "hello" },
        .{ .role = "agent", .content = "hi there" },
    };
    try saveMessages(allocator, io, root, &sample);

    const loaded = try loadMessages(allocator, io, root);
    defer freeLoadedMessages(allocator, loaded);
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("user", loaded[0].role);
    try std.testing.expectEqualStrings("hello", loaded[0].content);
}

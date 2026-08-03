const std = @import("std");

pub const max_turns: usize = 12;
pub const max_turn_chars: usize = 4096;

pub const Role = enum {
    user,
    agent,
};

pub const Turn = struct {
    role: Role,
    content: []const u8,
};

pub fn truncateContent(content: []const u8) []const u8 {
    if (content.len <= max_turn_chars) return content;
    return content[0..max_turn_chars];
}

pub fn appendHistory(writer: *std.Io.Writer, history: []const Turn) !void {
    if (history.len == 0) return;
    try writer.writeAll("--- CONVERSATION ---\n");
    const start = if (history.len > max_turns) history.len - max_turns else 0;
    if (start > 0) {
        try writer.print("Earlier conversation compacted: {d} turn(s). Use fresh code retrieval for file facts instead of relying on old chat text.\n\n", .{start});
    }
    for (history[start..]) |turn| {
        const label: []const u8 = switch (turn.role) {
            .user => "User",
            .agent => "Assistant",
        };
        const content = truncateContent(turn.content);
        try writer.print("{s}: {s}\n\n", .{ label, content });
    }
    try writer.writeAll("\n");
}

pub fn freeTurns(allocator: std.mem.Allocator, turns: []const Turn) void {
    for (turns) |turn| allocator.free(turn.content);
    allocator.free(turns);
}

test "appendHistory renders prior turns" {
    const turns = [_]Turn{
        .{ .role = .user, .content = "hello" },
        .{ .role = .agent, .content = "hi there" },
    };

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try appendHistory(&writer, &turns);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "User: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Assistant: hi there") != null);
}

test "appendHistory compacts older turns" {
    var turns: [max_turns + 2]Turn = undefined;
    for (&turns, 0..) |*turn, index| {
        turn.* = .{
            .role = if (index % 2 == 0) .user else .agent,
            .content = "old message",
        };
    }

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try appendHistory(&writer, &turns);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Earlier conversation compacted: 2 turn(s)") != null);
}

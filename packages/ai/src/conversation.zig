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
    for (history) |turn| {
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

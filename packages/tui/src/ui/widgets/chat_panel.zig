//! Chat Panel widget for AI conversations

const std = @import("std");
const layouts = @import("../layouts/layouts.zig");

pub const Message = struct {
    role: enum { user, assistant, system },
    content: []const u8,
    timestamp: u64,
};

pub const ChatPanel = struct {
    rect: layouts.Rect,
    messages: std.ArrayList(Message),
    input_buffer: std.ArrayList(u8),
    scroll_offset: usize = 0,
    is_typing: bool = false,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ChatPanel {
        return .{
            .rect = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .messages = std.ArrayList(Message).init(allocator),
            .input_buffer = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChatPanel) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit();
        self.input_buffer.deinit();
    }

    pub fn addMessage(self: *ChatPanel, role: Message.role, content: []const u8) !void {
        const copy = try self.allocator.dupe(u8, content);
        try self.messages.append(.{
            .role = role,
            .content = copy,
            .timestamp = std.time.timestamp(),
        });
    }

    pub fn render(self: *const ChatPanel, writer: anytype) !void {
        try writer.writeAll("\x1b[1m=== AI Chat ===\x1b[0m\n\n");

        for (self.messages.items) |msg| {
            const prefix = switch (msg.role) {
                .user => "\x1b[32mYou:\x1b[0m",
                .assistant => "\x1b[36mAI:\x1b[0m",
                .system => "\x1b[90mSystem:\x1b[0m",
            };
            try writer.writeAll(prefix);
            try writer.writeAll(" ");
            try writer.writeAll(msg.content);
            try writer.writeAll("\n\n");
        }

        if (self.is_typing) {
            try writer.writeAll("\x1b[36mAI is typing...\x1b[0m\n");
        }

        try writer.writeAll("> ");
        try writer.writeAll(self.input_buffer.items);
        try writer.writeAll("\x1b[K");
    }
};

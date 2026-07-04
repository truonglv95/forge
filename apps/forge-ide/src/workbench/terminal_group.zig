const std = @import("std");
const terminal_session = @import("terminal_session.zig");

pub const Group = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    sessions: std.ArrayList(terminal_session.TerminalSession),
    active: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8) !Group {
        var group: Group = .{
            .allocator = allocator,
            .io = io,
            .workspace_path = try allocator.dupe(u8, workspace_path),
            .sessions = .empty,
        };
        errdefer group.deinit();
        try group.sessions.append(allocator, try terminal_session.TerminalSession.init(allocator, io, workspace_path));
        return group;
    }

    pub fn deinit(self: *Group) void {
        for (self.sessions.items) |*session| session.deinit();
        self.sessions.deinit(self.allocator);
        self.allocator.free(self.workspace_path);
    }

    pub fn activeSession(self: *Group) *terminal_session.TerminalSession {
        if (self.sessions.items.len == 0) {
            self.sessions.append(self.allocator, terminal_session.TerminalSession.init(
                self.allocator,
                self.io,
                self.workspace_path,
            ) catch unreachable) catch unreachable;
            self.active = 0;
        }
        if (self.active >= self.sessions.items.len) self.active = self.sessions.items.len - 1;
        return &self.sessions.items[self.active];
    }

    pub fn addSession(self: *Group) !void {
        try self.sessions.append(self.allocator, try terminal_session.TerminalSession.init(
            self.allocator,
            self.io,
            self.workspace_path,
        ));
        self.active = self.sessions.items.len - 1;
    }

    pub fn closeActive(self: *Group) bool {
        if (self.sessions.items.len <= 1) return false;
        self.sessions.items[self.active].deinit();
        _ = self.sessions.orderedRemove(self.active);
        if (self.active >= self.sessions.items.len) self.active = self.sessions.items.len - 1;
        return true;
    }

    pub fn activate(self: *Group, index: usize) void {
        if (index >= self.sessions.items.len) return;
        self.active = index;
    }

    pub fn next(self: *Group) void {
        if (self.sessions.items.len <= 1) return;
        self.active = (self.active + 1) % self.sessions.items.len;
    }

    pub fn prev(self: *Group) void {
        if (self.sessions.items.len <= 1) return;
        if (self.active == 0) self.active = self.sessions.items.len - 1 else self.active -= 1;
    }
};

test "terminal group keeps at least one session" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var group = try Group.init(allocator, io, ".");
    defer group.deinit();

    try std.testing.expectEqual(@as(usize, 1), group.sessions.items.len);
    try group.addSession();
    try std.testing.expectEqual(@as(usize, 2), group.sessions.items.len);
    try std.testing.expect(group.closeActive());
    try std.testing.expectEqual(@as(usize, 1), group.sessions.items.len);
    try std.testing.expect(!group.closeActive());
}

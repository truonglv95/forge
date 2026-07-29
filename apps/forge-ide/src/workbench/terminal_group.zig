const std = @import("std");
const terminal_session = @import("terminal_session.zig");

pub const Group = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    sessions: std.ArrayList(terminal_session.TerminalSession),
    active: usize = 0,
    /// Split mode: when true, two terminals are shown side by side.
    /// The second visible terminal is at index `active + 1` (or wraps).
    split_enabled: bool = false,
    /// Index of the split (second) terminal. When split_enabled is true,
    /// both `active` and `split_active` are rendered side by side.
    split_active: usize = 0,
    /// Which pane is focused: 0 = primary, 1 = split.
    split_focus: u8 = 0,

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

    /// Returns the split (second) terminal session, or null if split
    /// is not enabled or there's only one session.
    pub fn splitSession(self: *Group) ?*terminal_session.TerminalSession {
        if (!self.split_enabled) return null;
        if (self.sessions.items.len < 2) return null;
        if (self.split_active >= self.sessions.items.len) self.split_active = 0;
        if (self.split_active == self.active) {
            // Don't show the same terminal in both panes — pick next.
            self.split_active = (self.active + 1) % self.sessions.items.len;
        }
        return &self.sessions.items[self.split_active];
    }

    /// Returns the focused session — either primary or split depending
    /// on split_focus. Used for keyboard input routing.
    pub fn focusedSession(self: *Group) *terminal_session.TerminalSession {
        if (self.split_enabled and self.split_focus == 1) {
            if (self.splitSession()) |split| return split;
        }
        return self.activeSession();
    }

    pub fn addSession(self: *Group) !void {
        try self.sessions.append(self.allocator, try terminal_session.TerminalSession.init(
            self.allocator,
            self.io,
            self.workspace_path,
        ));
        self.active = self.sessions.items.len - 1;
    }

    /// Toggle split mode. When enabling, creates a second session if
    /// there's only one, and sets split_active to the next session.
    pub fn toggleSplit(self: *Group) !void {
        if (self.split_enabled) {
            self.split_enabled = false;
            self.split_focus = 0;
        } else {
            if (self.sessions.items.len < 2) {
                try self.addSession();
                self.active = 0;
            }
            self.split_active = if (self.sessions.items.len > 1) 1 else 0;
            self.split_enabled = true;
            self.split_focus = 0;
        }
    }

    /// Switch focus between primary and split panes.
    pub fn switchSplitFocus(self: *Group) void {
        if (!self.split_enabled) return;
        self.split_focus = if (self.split_focus == 0) 1 else 0;
    }

    pub fn closeActive(self: *Group) bool {
        if (self.sessions.items.len <= 1) return false;
        self.sessions.items[self.active].deinit();
        _ = self.sessions.orderedRemove(self.active);
        if (self.active >= self.sessions.items.len) self.active = self.sessions.items.len - 1;
        if (self.split_enabled) {
            if (self.sessions.items.len < 2) {
                self.split_enabled = false;
                self.split_focus = 0;
            } else if (self.split_active >= self.sessions.items.len) {
                self.split_active = self.sessions.items.len - 1;
            }
        }
        return true;
    }

    pub fn activate(self: *Group, index: usize) void {
        if (index >= self.sessions.items.len) return;
        if (self.split_focus == 0) {
            self.active = index;
        } else {
            self.split_active = index;
        }
    }

    pub fn next(self: *Group) void {
        if (self.sessions.items.len <= 1) return;
        if (self.split_focus == 0) {
            self.active = (self.active + 1) % self.sessions.items.len;
        } else {
            self.split_active = (self.split_active + 1) % self.sessions.items.len;
        }
    }

    pub fn prev(self: *Group) void {
        if (self.sessions.items.len <= 1) return;
        if (self.split_focus == 0) {
            if (self.active == 0) self.active = self.sessions.items.len - 1 else self.active -= 1;
        } else {
            if (self.split_active == 0) self.split_active = self.sessions.items.len - 1 else self.split_active -= 1;
        }
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

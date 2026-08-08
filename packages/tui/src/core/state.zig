//! State management for Forge TUI
//! Handles app state, focus, and user preferences

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Application modes
pub const AppMode = enum {
    normal,
    insert,
    command,
    search,
    help,
    chat,
    file_picker,
};

/// Focus state with history
pub const FocusState = struct {
    current: usize = 0,
    history: std.ArrayList(usize),
    allocator: Allocator,

    pub fn init(allocator: Allocator) FocusState {
        return .{
            .history = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FocusState) void {
        self.history.deinit();
    }

    pub fn push(self: *FocusState, index: usize) !void {
        try self.history.append(index);
        self.current = index;
    }

    pub fn pop(self: *FocusState) ?usize {
        if (self.history.items.len > 1) {
            _ = self.history.orderedRemove(self.history.items.len - 1);
            self.current = self.history.items[self.history.items.len - 1];
            return self.current;
        }
        return null;
    }

    pub fn set(self: *FocusState, index: usize) void {
        self.current = index;
        if (self.history.items.len == 0 or self.history.items[self.history.items.len - 1] != index) {
            self.history.append(index) catch {};
        } else {
            self.history.items[self.history.items.len - 1] = index;
        }
    }
};

/// User preferences
pub const Preferences = struct {
    theme: enum { dark, light, monokai, dracula, nord, gruvbox } = .dark,
    auto_save: bool = true,
    vim_mode: bool = false,
    mouse_enabled: bool = true,
    line_numbers: bool = true,
    word_wrap: bool = false,
    tab_size: u8 = 4,
    font_size: u8 = 12,
    show_hidden_files: bool = false,
    confirm_exit: bool = true,
    max_history: usize = 100,
};

/// Command history
pub const HistoryManager = struct {
    entries: std.ArrayList([]const u8),
    max_entries: usize,
    current_index: ?usize = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, max: usize) HistoryManager {
        return .{
            .entries = std.ArrayList([]const u8).init(allocator),
            .max_entries = max,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HistoryManager) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit();
    }

    pub fn add(self: *HistoryManager, entry: []const u8) !void {
        // Remove duplicate if exists
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e, entry)) {
                _ = self.entries.orderedRemove(i);
                break;
            }
        }

        const copy = try self.allocator.dupe(u8, entry);
        try self.entries.append(copy);

        // Trim to max
        while (self.entries.items.len > self.max_entries) {
            const removed = self.entries.orderedRemove(0);
            self.allocator.free(removed);
        }

        self.current_index = null;
    }

    pub fn previous(self: *HistoryManager) ?[]const u8 {
        if (self.entries.items.len == 0) return null;

        if (self.current_index == null) {
            self.current_index = self.entries.items.len - 1;
        } else if (self.current_index.? > 0) {
            self.current_index.? -= 1;
        }

        return self.entries.items[self.current_index.?];
    }

    pub fn next(self: *HistoryManager) ?[]const u8 {
        if (self.entries.items.len == 0 or self.current_index == null) return null;

        if (self.current_index.? < self.entries.items.len - 1) {
            self.current_index.? += 1;
            return self.entries.items[self.current_index.?];
        }

        self.current_index = null;
        return null;
    }

    pub fn reset(self: *HistoryManager) void {
        self.current_index = null;
    }
};

/// Search state
pub const SearchState = struct {
    query: []const u8,
    case_sensitive: bool = false,
    regex: bool = false,
    match_index: usize = 0,
    total_matches: usize = 0,

    pub fn matches(self: SearchState, text: []const u8) bool {
        if (self.query.len == 0) return true;

        if (self.case_sensitive) {
            return std.mem.indexOf(u8, text, self.query) != null;
        } else {
            // Case-insensitive search
            var buf: [1024]u8 = undefined;
            const lower_query = std.ascii.lowerString(&buf, self.query);
            var text_buf: [1024]u8 = undefined;
            const lower_text = std.ascii.lowerString(&text_buf, text[0..@min(text.len, 1024)]);
            return std.mem.indexOf(u8, lower_text, lower_query) != null;
        }
    }
};

/// Main application state
pub const AppState = struct {
    mode: AppMode = .normal,
    focus: FocusState,
    preferences: Preferences,
    command_history: HistoryManager,
    search_history: HistoryManager,
    search_state: ?SearchState = null,
    dirty: bool = false,
    quit_pending: bool = false,
    message: ?struct { text: []const u8, level: enum { info, warning, error } } = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) AppState {
        return .{
            .focus = FocusState.init(allocator),
            .command_history = HistoryManager.init(allocator, 100),
            .search_history = HistoryManager.init(allocator, 100),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AppState) void {
        self.focus.deinit();
        self.command_history.deinit();
        self.search_history.deinit();
        if (self.message) |msg| {
            self.allocator.free(msg.text);
        }
    }

    pub fn setMode(self: *AppState, mode: AppMode) void {
        self.mode = mode;
        self.dirty = true;
    }

    pub fn showMessage(self: *AppState, text: []const u8, level: enum { info, warning, error }) !void {
        if (self.message) |msg| {
            self.allocator.free(msg.text);
        }
        const copy = try self.allocator.dupe(u8, text);
        self.message = .{ .text = copy, .level = level };
        self.dirty = true;
    }

    pub fn clearMessage(self: *AppState) void {
        if (self.message) |msg| {
            self.allocator.free(msg.text);
            self.message = null;
        }
        self.dirty = true;
    }
};

test "history manager" {
    var hm = HistoryManager.init(std.testing.allocator, 10);
    defer hm.deinit();

    try hm.add("command1");
    try hm.add("command2");
    try hm.add("command3");

    try std.testing.expectEqualStrings("command3", hm.previous().?);
    try std.testing.expectEqualStrings("command2", hm.previous().?);
    try std.testing.expectEqualStrings("command3", hm.next().?);
}

test "app state" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.showMessage("Test message", .info);
    try std.testing.expect(state.message != null);
    try std.testing.expectEqualStrings("Test message", state.message.?.text);

    state.clearMessage();
    try std.testing.expect(state.message == null);
}

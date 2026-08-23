//! State Management for Forge TUI
//! 
//! Provides application state, focus management, and state persistence.

const std = @import("std");
const theme = @import("../theme/theme.zig");
const layouts = @import("../layouts/layouts.zig");

/// Focus tracking for keyboard navigation
pub const FocusState = struct {
    /// Currently focused component ID
    focused_id: ?[]const u8 = null,
    /// Focus history for back navigation
    history: std.ArrayList([]const u8),
    /// Focus trap (modal dialogs)
    trapped: bool = false,
    trap_bounds: ?layouts.Rect = null,

    pub fn init(allocator: std.mem.Allocator) FocusState {
        return .{
            .history = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FocusState) void {
        self.history.deinit();
    }

    pub fn focus(self: *FocusState, id: []const u8) void {
        if (self.focused_id) |current| {
            // Don't push same ID twice
            if (self.history.items.len == 0 or 
                !std.mem.eql(u8, self.history.items[self.history.items.len - 1], current)) {
                self.history.append(current) catch return;
            }
        }
        self.focused_id = id;
    }

    pub fn back(self: *FocusState) ?[]const u8 {
        if (self.history.popOrNull()) |prev| {
            self.focused_id = prev;
            return prev;
        }
        self.focused_id = null;
        return null;
    }

    pub fn clearHistory(self: *FocusState) void {
        self.history.clearRetainingCapacity();
    }
};

/// Application mode
pub const AppMode = enum {
    normal,
    insert,
    command,
    search,
    help,
    confirmation,
};

/// Global application state
pub const AppState = struct {
    allocator: std.mem.Allocator,
    
    // UI State
    mode: AppMode = .normal,
    focus: FocusState,
    theme: theme.Theme,
    
    // Layout state
    screen_size: layouts.Rect,
    is_fullscreen: bool = false,
    
    // Feature flags
    vim_mode_enabled: bool = true,
    mouse_enabled: bool = true,
    animations_enabled: bool = true,
    
    // Performance
    fps_current: u32 = 0,
    fps_target: u32 = 60,
    frame_count: u64 = 0,
    last_fps_update: u64 = 0,
    
    // User preferences
    auto_save: bool = true,
    confirm_exit: bool = true,
    show_line_numbers: bool = true,
    tab_width: u8 = 4,
    
    // Session data
    recent_files: std.ArrayList([]const u8),
    command_history: std.ArrayList([]const u8),
    search_history: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, initial_theme: theme.Theme) AppState {
        return .{
            .allocator = allocator,
            .focus = FocusState.init(allocator),
            .theme = initial_theme,
            .screen_size = .{ .x = 0, .y = 0, .width = 80, .height = 24 },
            .recent_files = std.ArrayList([]const u8).init(allocator),
            .command_history = std.ArrayList([]const u8).init(allocator),
            .search_history = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *AppState) void {
        self.focus.deinit();
        self.recent_files.deinit();
        self.command_history.deinit();
        self.search_history.deinit();
    }

    pub fn setMode(self: *AppState, new_mode: AppMode) void {
        self.mode = new_mode;
    }

    pub fn toggleFullscreen(self: *AppState) void {
        self.is_fullscreen = !self.is_fullscreen;
    }

    pub fn updateScreenSize(self: *AppState, width: u16, height: u16) void {
        self.screen_size = .{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        };
    }

    pub fn addCommandToHistory(self: *AppState, cmd: []const u8) !void {
        // Limit history size
        if (self.command_history.items.len >= 100) {
            _ = self.command_history.orderedRemove(0);
        }
        try self.command_history.append(cmd);
    }

    pub fn addSearchToHistory(self: *AppState, query: []const u8) !void {
        if (self.search_history.items.len >= 50) {
            _ = self.search_history.orderedRemove(0);
        }
        try self.search_history.append(query);
    }

    pub fn addRecentFile(self: *AppState, path: []const u8) !void {
        // Remove if already exists
        for (self.recent_files.items, 0..) |file, i| {
            if (std.mem.eql(u8, file, path)) {
                _ = self.recent_files.orderedRemove(i);
                break;
            }
        }
        
        // Add to front
        if (self.recent_files.items.len >= 20) {
            _ = self.recent_files.orderedRemove(0);
        }
        try self.recent_files.insert(0, path);
    }

    pub fn updateFPS(self: *AppState, timestamp: u64) void {
        self.frame_count += 1;
        
        if (timestamp - self.last_fps_update >= 1000) { // Every second
            self.fps_current = self.frame_count;
            self.frame_count = 0;
            self.last_fps_update = timestamp;
        }
    }
};

/// Component lifecycle events
pub const LifecycleEvent = union(enum) {
    mount,
    unmount,
    focus,
    blur,
    resize: layouts.Rect,
    theme_changed: theme.Theme,
};

/// State change notification
pub const StateChange = struct {
    path: []const u8,
    old_value: anytype,
    new_value: anytype,
    timestamp: u64,
};

/// State store for reactive updates
pub const StateStore = struct {
    allocator: std.mem.Allocator,
    state: std.StringHashMap([]const u8),
    subscribers: std.ArrayList(*const fn ([]const u8) void),

    pub fn init(allocator: std.mem.Allocator) StateStore {
        return .{
            .allocator = allocator,
            .state = std.StringHashMap([]const u8).init(allocator),
            .subscribers = std.ArrayList(*const fn ([]const u8) void).init(allocator),
        };
    }

    pub fn deinit(self: *StateStore) void {
        var it = self.state.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.state.deinit();
        self.subscribers.deinit();
    }

    pub fn set(self: *StateStore, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        
        errdefer {
            self.allocator.free(key_copy);
            self.allocator.free(value_copy);
        }
        
        if (self.state.fetchPut(key_copy, value_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        
        // Notify subscribers
        for (self.subscribers.items) |callback| {
            callback(key);
        }
    }

    pub fn get(self: *StateStore, key: []const u8) ?[]const u8 {
        return self.state.get(key);
    }

    pub fn subscribe(self: *StateStore, callback: *const fn ([]const u8) void) !void {
        try self.subscribers.append(callback);
    }
};

test "FocusState navigation" {
    const allocator = std.testing.allocator;
    var focus = FocusState.init(allocator);
    defer focus.deinit();
    
    focus.focus("panel1");
    try std.testing.expect(focus.focused_id != null);
    
    focus.focus("panel2");
    focus.back();
    try std.testing.expectEqualStrings("panel1", focus.focused_id.?);
}

test "AppState mode switching" {
    const allocator = std.testing.allocator;
    var state = AppState.init(allocator, theme.Theme.dark());
    defer state.deinit();
    
    try std.testing.expectEqual(AppMode.normal, state.mode);
    
    state.setMode(.insert);
    try std.testing.expectEqual(AppMode.insert, state.mode);
}

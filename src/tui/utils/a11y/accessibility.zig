//! Accessibility Module - Screen Reader, High Contrast, Keyboard Nav
const std = @import("std");

pub const AccessibilityConfig = struct {
    screen_reader_enabled: bool = false,
    high_contrast_mode: bool = false,
    reduced_motion: bool = false,
    focus_indicator: bool = true,
    tab_navigation: bool = true,

    pub fn init() AccessibilityConfig {
        return .{};
    }
};

pub const ScreenReader = struct {
    enabled: bool,
    announcements: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) ScreenReader {
        return .{
            .enabled = enabled,
            .announcements = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScreenReader) void {
        for (self.announcements.items) |item| {
            self.allocator.free(item);
        }
        self.announcements.deinit();
    }

    pub fn announce(self: *ScreenReader, text: []const u8) !void {
        if (!self.enabled) return;
        const copy = try self.allocator.dupe(u8, text);
        try self.announcements.append(copy);
        
        // In real implementation, this would send to screen reader API
        std.debug.print("[SCREEN READER]: {s}\n", .{text});
    }

    pub fn announceElement(self: *ScreenReader, element_type: []const u8, label: []const u8, state: []const u8) !void {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s} '{s}' {s}", .{ element_type, label, state });
        try self.announce(msg);
    }
};

pub const HighContrastTheme = struct {
    fg: []const u8,
    bg: []const u8,
    accent: []const u8,

    pub fn default() HighContrastTheme {
        return .{
            .fg = "#FFFFFF",
            .bg = "#000000",
            .accent = "#FFFF00",
        };
    }

    pub fn apply(self: *HighContrastTheme, writer: anytype) !void {
        try writer.print("\x1b[38;2;255;255;255m\x1b[48;2;0;0;0m", .{});
    }
};

pub const FocusRing = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    visible: bool,

    pub fn render(self: *FocusRing, writer: anytype) !void {
        if (!self.visible) return;
        
        // Render border around focused element
        try writer.print("\x1b[{d};{d}H┌", .{ self.y + 1, self.x + 1 });
        try writer.print("\x1b[{d};{d}H─", .{ self.y + 1, self.x + self.width });
        try writer.print("\x1b[{d};{d}H┐", .{ self.y + 1, self.x + self.width + 1 });
        
        for (0..self.height) |i| {
            try writer.print("\x1b[{d};{d}H│", .{ self.y + i + 1, self.x + 1 });
            try writer.print("\x1b[{d};{d}H│", .{ self.y + i + 1, self.x + self.width + 1 });
        }
        
        try writer.print("\x1b[{d};{d}H└", .{ self.y + self.height + 1, self.x + 1 });
        try writer.print("\x1b[{d};{d}H─", .{ self.y + self.height + 1, self.x + self.width });
        try writer.print("\x1b[{d};{d}H┘", .{ self.y + self.height + 1, self.x + self.width + 1 });
    }
};

pub const TabNavigator = struct {
    elements: std.ArrayList(TabElement),
    current_index: usize,
    allocator: std.mem.Allocator,

    pub const TabElement = struct {
        id: []const u8,
        x: usize,
        y: usize,
        focusable: bool,
    };

    pub fn init(allocator: std.mem.Allocator) TabNavigator {
        return .{
            .elements = std.ArrayList(TabElement).init(allocator),
            .current_index = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TabNavigator) void {
        self.elements.deinit();
    }

    pub fn addElement(self: *TabNavigator, id: []const u8, x: usize, y: usize, focusable: bool) !void {
        try self.elements.append(.{
            .id = id,
            .x = x,
            .y = y,
            .focusable = focusable,
        });
    }

    pub fn next(self: *TabNavigator) void {
        if (self.elements.items.len == 0) return;
        self.current_index = (self.current_index + 1) % self.elements.items.len;
        while (!self.elements.items[self.current_index].focusable) {
            self.current_index = (self.current_index + 1) % self.elements.items.len;
        }
    }

    pub fn previous(self: *TabNavigator) void {
        if (self.elements.items.len == 0) return;
        if (self.current_index == 0) {
            self.current_index = self.elements.items.len - 1;
        } else {
            self.current_index -= 1;
        }
        while (!self.elements.items[self.current_index].focusable) {
            if (self.current_index == 0) {
                self.current_index = self.elements.items.len - 1;
            } else {
                self.current_index -= 1;
            }
        }
    }

    pub fn getCurrentElement(self: *TabNavigator) ?TabElement {
        if (self.elements.items.len == 0) return null;
        return self.elements.items[self.current_index];
    }
};

test "TabNavigator cycles through elements" {
    var nav = TabNavigator.init(std.testing.allocator);
    defer nav.deinit();
    
    try nav.addElement("btn1", 0, 0, true);
    try nav.addElement("btn2", 0, 1, true);
    try nav.addElement("btn3", 0, 2, false);
    
    try std.testing.expectEqual(@as(usize, 0), nav.current_index);
    nav.next();
    try std.testing.expectEqual(@as(usize, 1), nav.current_index);
    nav.next();
    try std.testing.expectEqual(@as(usize, 1), nav.current_index); // Skip non-focusable
}

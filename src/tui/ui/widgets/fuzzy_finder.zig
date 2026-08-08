//! Fuzzy Finder widget for quick file/command search

const std = @import("std");
const layouts = @import("../layouts/layouts.zig");
const components = @import("../components/components.zig");
const theme = @import("../theme/theme.zig");

pub const FuzzyFinder = struct {
    rect: layouts.Rect,
    query: std.ArrayList(u8),
    items: std.ArrayList([]const u8),
    filtered: std.ArrayList(usize),
    selected: usize = 0,
    scroll_offset: usize = 0,
    focused: bool = false,
    placeholder: []const u8 = "Type to search...",
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .rect = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .query = std.ArrayList(u8).init(allocator),
            .items = std.ArrayList([]const u8).init(allocator),
            .filtered = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.query.deinit();
        self.items.deinit();
        self.filtered.deinit();
    }

    pub fn addItem(self: *Self, item: []const u8) !void {
        try self.items.append(item);
        try self.updateFiltered();
    }

    pub fn setItems(self: *Self, items: [][]const u8) !void {
        self.items.clearRetainingCapacity();
        for (items) |item| {
            try self.items.append(item);
        }
        try self.updateFiltered();
    }

    fn updateFiltered(self: *Self) !void {
        self.filtered.clearRetainingCapacity();
        
        if (self.query.items.len == 0) {
            for (0..self.items.items.len) |i| {
                try self.filtered.append(i);
            }
            return;
        }

        for (self.items.items, 0..) |item, i| {
            if (fuzzyMatch(item, self.query.items)) {
                try self.filtered.append(i);
            }
        }
    }

    fn fuzzyMatch(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len == 0) return false;

        var h_idx: usize = 0;
        for (needle) |n| {
            var found = false;
            while (h_idx < haystack.len) : (h_idx += 1) {
                if (std.ascii.toLower(n) == std.ascii.toLower(haystack[h_idx])) {
                    found = true;
                    h_idx += 1;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    pub fn handleEvent(self: *Self, event: components.InputEvent) components.ComponentResult {
        switch (event) {
            .key => |key| {
                switch (key) {
                    .char => |c| {
                        try self.query.append(c);
                        try self.updateFiltered();
                        self.selected = 0;
                        return .consumed;
                    },
                    .ctrl => |c| {
                        if (c == 'H' or c == 8) { // Backspace
                            if (self.query.items.len > 0) {
                                _ = self.query.pop();
                                try self.updateFiltered();
                                self.selected = 0;
                            }
                            return .consumed;
                        }
                    },
                    .special => |sp| {
                        switch (sp) {
                            .up => {
                                if (self.selected > 0) self.selected -= 1;
                                return .consumed;
                            },
                            .down => {
                                if (self.selected < self.filtered.items.len -| 1) {
                                    self.selected += 1;
                                }
                                return .consumed;
                            },
                            .enter => {
                                return .consumed;
                            },
                            .escape => {
                                self.query.clearRetainingCapacity();
                                try self.updateFiltered();
                                return .consumed;
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
        return .propagate;
    }

    pub fn render(self: *const Self, writer: anytype) !void {
        // Render background
        try writer.writeAll("\x1b[2J\x1b[H");
        
        // Render header
        try writer.writeAll("\x1b[1mFuzzy Finder\x1b[0m\n");
        try writer.writeAll("─────────────────────────────────────\n");
        
        // Render input box
        try writer.writeAll("> ");
        try writer.writeAll(self.query.items);
        if (self.query.items.len == 0) {
            try writer.writeAll("\x1b[90m");
            try writer.writeAll(self.placeholder);
            try writer.writeAll("\x1b[0m");
        }
        try writer.writeAll("\n\n");
        
        // Render results
        const visible_items = @min(self.filtered.items.len, 10);
        for (0..visible_items) |i| {
            const idx = self.filtered.items[i];
            if (i == self.selected) {
                try writer.writeAll("\x1b[7m> \x1b[0m");
            } else {
                try writer.writeAll("  ");
            }
            try writer.writeAll(self.items.items[idx]);
            try writer.writeAll("\n");
        }
        
        if (self.filtered.items.len == 0) {
            try writer.writeAll("\x1b[90mNo matches found\x1b[0m\n");
        }
    }

    pub fn getSelected(self: *const Self) ?[]const u8 {
        if (self.filtered.items.len == 0) return null;
        if (self.selected >= self.filtered.items.len) return null;
        return self.items.items[self.filtered.items[self.selected]];
    }
};

test "fuzzy match" {
    try std.testing.expect(fuzzyMatch("hello world", "hw"));
    try std.testing.expect(!fuzzyMatch("hello", "x"));
    try std.testing.expect(fuzzyMatch("hello", ""));
}

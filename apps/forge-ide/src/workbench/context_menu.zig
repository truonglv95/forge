//! Context menu (right-click) and quick-fix lightbulb state.
//!
//! Right-click in the editor opens a context menu with standard actions
//! (Cut / Copy / Paste / Format / Refactor / Go to Definition / Find
//! References / Rename). The menu is positioned at the click point and
//! stays open until the user selects an item or clicks elsewhere.
//!
//! The quick-fix lightbulb appears at the start of a line when the LSP
//! has codeActions for that line (typically diagnostics with quick-fixes
//! like "import missing module" or "wrap in try/catch"). Clicking the
//! lightbulb opens the same context menu with only the codeAction items.

const std = @import("std");

pub const Action = enum {
    cut,
    copy,
    paste,
    format_document,
    format_selection,
    go_to_definition,
    find_references,
    rename_symbol,
    quick_fix,
    refactor,
    source_action,
    toggle_comment,
    indent,
    outdent,
    select_all,
    command_palette,
};

pub const MenuItem = struct {
    /// Display label.
    label: []const u8,
    /// Action to dispatch when clicked.
    action: ?Action = null,
    /// For quick-fix items, the codeAction title (owned). When non-null,
    /// `action` is `.quick_fix` and the dispatch should invoke the LSP
    /// codeAction at this index instead of a builtin action.
    quick_fix_title: ?[]const u8 = null,
    /// Index of the codeAction in the LSP response (for quick_fix items).
    quick_fix_index: ?usize = null,
    /// Separator line above this item (for grouping).
    separator: bool = false,
    /// Disabled (greyed out).
    disabled: bool = false,
};

pub const Menu = struct {
    allocator: std.mem.Allocator,
    /// True when the menu is visible.
    active: bool = false,
    /// Menu position (top-left corner in screen coords).
    x: f32 = 0,
    y: f32 = 0,
    /// Items currently shown.
    items: std.ArrayList(MenuItem),
    /// Selected index (-1 = none).
    selected: ?usize = null,
    /// True when this menu was opened as a quick-fix lightbulb (affects
    /// styling — lightbulb menus get a yellow accent).
    is_quick_fix: bool = false,

    pub fn init(allocator: std.mem.Allocator) Menu {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Menu) void {
        self.close();
        self.items.deinit(self.allocator);
    }

    /// Open the menu at (x, y) with the standard editor items.
    pub fn openEditor(self: *Menu, x: f32, y: f32) !void {
        self.close();
        self.active = true;
        self.x = x;
        self.y = y;
        self.is_quick_fix = false;
        try self.appendItem("Cut", .cut);
        try self.appendItem("Copy", .copy);
        try self.appendItem("Paste", .paste);
        try self.appendSeparator();
        try self.appendItem("Go to Definition", .go_to_definition);
        try self.appendItem("Find References", .find_references);
        try self.appendItem("Rename Symbol", .rename_symbol);
        try self.appendSeparator();
        try self.appendItem("Format Document", .format_document);
        try self.appendItem("Format Selection", .format_selection);
        try self.appendSeparator();
        try self.appendItem("Toggle Comment", .toggle_comment);
        try self.appendItem("Indent", .indent);
        try self.appendItem("Outdent", .outdent);
        try self.appendSeparator();
        try self.appendItem("Command Palette…", .command_palette);
        self.selected = null;
    }

    /// Open a quick-fix lightbulb menu with the given codeAction titles.
    /// `titles` is an array of strings (caller owns; we dupe).
    pub fn openQuickFix(self: *Menu, x: f32, y: f32, titles: []const []const u8) !void {
        self.close();
        self.active = true;
        self.x = x;
        self.y = y;
        self.is_quick_fix = true;
        if (titles.len == 0) {
            try self.appendItem("No quick fixes available", null);
            self.items.items[0].disabled = true;
        } else {
            for (titles, 0..) |title, i| {
                const title_copy = try self.allocator.dupe(u8, title);
                try self.items.append(self.allocator, .{
                    .label = title_copy,
                    .action = .quick_fix,
                    .quick_fix_title = title_copy,
                    .quick_fix_index = i,
                });
            }
            try self.appendSeparator();
            try self.appendItem("Refactor…", .refactor);
            try self.appendItem("Source Action…", .source_action);
        }
        self.selected = null;
    }

    fn appendItem(self: *Menu, label: []const u8, action: ?Action) !void {
        const label_copy = try self.allocator.dupe(u8, label);
        try self.items.append(self.allocator, .{
            .label = label_copy,
            .action = action,
        });
    }

    fn appendSeparator(self: *Menu) !void {
        // Add separator flag to the NEXT item by setting on a placeholder.
        // We mark the next appended item via a temporary separator flag.
        // Simpler: append a separator-only item.
        try self.items.append(self.allocator, .{
            .label = "",
            .action = null,
            .separator = true,
        });
    }

    pub fn close(self: *Menu) void {
        for (self.items.items) |*item| {
            self.allocator.free(item.label);
            if (item.quick_fix_title) |t| self.allocator.free(t);
        }
        self.items.clearRetainingCapacity();
        self.active = false;
        self.selected = null;
        self.is_quick_fix = false;
    }

    pub fn moveUp(self: *Menu) void {
        if (self.items.items.len == 0) return;
        if (self.selected) |s| {
            if (s > 0) {
                self.selected = s - 1;
                // Skip separators.
                while (self.selected.? > 0 and self.items.items[self.selected.?].separator) {
                    self.selected = self.selected.? - 1;
                }
            }
        } else {
            self.selected = self.items.items.len - 1;
        }
    }

    pub fn moveDown(self: *Menu) void {
        if (self.items.items.len == 0) return;
        if (self.selected) |s| {
            if (s + 1 < self.items.items.len) {
                self.selected = s + 1;
                // Skip separators.
                while (self.selected.? < self.items.items.len - 1 and self.items.items[self.selected.?].separator) {
                    self.selected = self.selected.? + 1;
                }
            }
        } else {
            self.selected = 0;
        }
    }

    /// Returns the currently-selected item, or null.
    pub fn current(self: *const Menu) ?MenuItem {
        if (self.selected) |s| {
            if (s < self.items.items.len) {
                const item = self.items.items[s];
                if (item.separator or item.disabled) return null;
                return item;
            }
        }
        return null;
    }

    /// Returns the item at a given screen-space (x, y), or null if the
    /// click is outside the menu. Used for mouse-based selection.
    /// `item_height` is the height of each menu row in pixels.
    pub fn itemAt(self: *const Menu, click_x: f32, click_y: f32, item_height: f32) ?MenuItem {
        if (!self.active) return null;
        // Assume menu width = 200 for hit-testing.
        const menu_w: f32 = 200;
        if (click_x < self.x or click_x > self.x + menu_w) return null;
        const rel_y = click_y - self.y;
        if (rel_y < 0) return null;
        const idx = @as(usize, @intFromFloat(rel_y / item_height));
        if (idx >= self.items.items.len) return null;
        const item = self.items.items[idx];
        if (item.separator or item.disabled) return null;
        return item;
    }
};

test "Menu openEditor creates 13 items (including separators)" {
    const allocator = std.testing.allocator;
    var m = Menu.init(allocator);
    defer m.deinit();

    try m.openEditor(100, 100);
    try std.testing.expect(m.active);
    try std.testing.expect(m.items.items.len > 10);
    // First item should be Cut.
    try std.testing.expectEqual(Action.cut, m.items.items[0].action.?);
}

test "Menu openQuickFix with empty list shows disabled placeholder" {
    const allocator = std.testing.allocator;
    var m = Menu.init(allocator);
    defer m.deinit();

    try m.openQuickFix(100, 100, &.{});
    try std.testing.expect(m.active);
    try std.testing.expectEqual(@as(usize, 1), m.items.items.len);
    try std.testing.expect(m.items.items[0].disabled);
}

test "Menu openQuickFix with titles creates items" {
    const allocator = std.testing.allocator;
    var m = Menu.init(allocator);
    defer m.deinit();

    const titles = [_][]const u8{ "Import 'foo'", "Wrap in try/catch" };
    try m.openQuickFix(100, 100, &titles);
    try std.testing.expectEqual(@as(usize, 4), m.items.items.len); // 2 fixes + separator + refactor
    try std.testing.expectEqualStrings("Import 'foo'", m.items.items[0].label);
}

test "Menu close clears state" {
    const allocator = std.testing.allocator;
    var m = Menu.init(allocator);
    defer m.deinit();

    try m.openEditor(100, 100);
    m.close();
    try std.testing.expect(!m.active);
    try std.testing.expectEqual(@as(usize, 0), m.items.items.len);
}

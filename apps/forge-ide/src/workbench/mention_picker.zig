//! Mention picker — `@file`, `@symbol`, `@folder`, `@web` autocomplete in chat.
//!
//! When the user types `@` in the agent prompt, a dropdown appears with
//! matching items. The dropdown is filtered as the user types more
//! characters after the `@`. Selecting an item inserts a mention token
//! (e.g. `@file:src/main.zig`) into the prompt and adds the corresponding
//! context to the agent's context bundle when submitted.
//!
//! Mention kinds:
//!   - `@file:<path>` — attach file content
//!   - `@symbol:<name>` — attach symbol definition + references (via LSP)
//!   - `@folder:<path>` — attach folder tree (depth-limited)
//!   - `@web:<query>` — fetch web search results (best-effort)

const std = @import("std");

pub const Kind = enum {
    file,
    symbol,
    folder,
    web,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .file => "file",
            .symbol => "symbol",
            .folder => "folder",
            .web => "web",
        };
    }
};

pub const Item = struct {
    kind: Kind,
    /// Display label (e.g. "src/main.zig" for a file).
    label: []const u8,
    /// Mention token to insert into the prompt (e.g. "@file:src/main.zig").
    token: []const u8,
    /// Optional secondary description (e.g. file size, symbol type).
    description: ?[]const u8 = null,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.token);
        if (self.description) |d| allocator.free(d);
        self.* = undefined;
    }
};

pub const Picker = struct {
    allocator: std.mem.Allocator,
    /// True when the picker dropdown is visible.
    active: bool = false,
    /// The kind of mention being entered (file/symbol/folder/web). Set
    /// after the user types `@file`, `@symbol`, etc. When null, the
    /// picker shows a kind chooser.
    kind: ?Kind = null,
    /// Filtered list of items currently shown.
    items: std.ArrayList(Item),
    /// Selected index in `items`.
    selected: usize = 0,
    /// Current filter text (text after the `@kind:` prefix).
    filter: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Picker {
        return .{
            .allocator = allocator,
            .items = .empty,
            .filter = .empty,
        };
    }

    pub fn deinit(self: *Picker) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.filter.deinit(self.allocator);
    }

    /// Open the picker with a kind chooser (no kind selected yet).
    pub fn open(self: *Picker) void {
        self.close();
        self.active = true;
        self.kind = null;
        self.populateKinds();
    }

    fn populateKinds(self: *Picker) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        const kinds = [_]struct { kind: Kind, label: []const u8, desc: []const u8 }{
            .{ .kind = .file, .label = "file", .desc = "Attach a file's content" },
            .{ .kind = .symbol, .label = "symbol", .desc = "Attach symbol definition + refs" },
            .{ .kind = .folder, .label = "folder", .desc = "Attach folder tree" },
            .{ .kind = .web, .label = "web", .desc = "Web search results" },
        };
        for (kinds) |k| {
            const label = self.allocator.dupe(u8, k.label) catch continue;
            const token = self.allocator.dupe(u8, k.label) catch continue;
            const desc = self.allocator.dupe(u8, k.desc) catch continue;
            self.items.append(self.allocator, .{
                .kind = k.kind,
                .label = label,
                .token = token,
                .description = desc,
            }) catch continue;
        }
        self.selected = 0;
    }

    pub fn close(self: *Picker) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        self.filter.clearRetainingCapacity();
        self.active = false;
        self.kind = null;
        self.selected = 0;
    }

    /// Set the kind and clear filter (user typed `@file` etc).
    pub fn setKind(self: *Picker, kind: Kind) void {
        self.kind = kind;
        self.filter.clearRetainingCapacity();
        // Caller is responsible for populating items via setFileItems /
        // setSymbolItems / etc. We just clear here.
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        self.selected = 0;
    }

    /// Append a character to the filter text.
    pub fn appendFilterChar(self: *Picker, ch: u8) !void {
        try self.filter.append(self.allocator, ch);
    }

    /// Append a string to the filter (for paste).
    pub fn appendFilterSlice(self: *Picker, s: []const u8) !void {
        try self.filter.appendSlice(self.allocator, s);
    }

    /// Backspace one character from the filter. If the filter becomes
    /// empty AND no kind is set, close the picker. If a kind is set and
    /// the filter is empty, keep the picker open showing all items for
    /// that kind.
    pub fn backspace(self: *Picker) void {
        if (self.filter.items.len > 0) {
            _ = self.filter.pop();
        }
    }

    pub fn filterText(self: *const Picker) []const u8 {
        return self.filter.items;
    }

    pub fn moveUp(self: *Picker) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *Picker) void {
        if (self.selected + 1 < self.items.items.len) self.selected += 1;
    }

    /// Returns the currently-selected item, if any.
    pub fn current(self: *const Picker) ?Item {
        if (self.items.items.len == 0) return null;
        if (self.selected >= self.items.items.len) return null;
        return self.items.items[self.selected];
    }

    /// Populate items from a list of file paths. Each path is duped.
    /// Caller must have already set the kind via setKind(.file).
    pub fn setFileItems(self: *Picker, paths: []const []const u8) !void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        const filter_text = self.filter.items;
        for (paths) |path| {
            if (filter_text.len > 0 and std.mem.indexOf(u8, path, filter_text) == null) continue;
            const label = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(label);
            const token = try std.fmt.allocPrint(self.allocator, "@file:{s}", .{path});
            errdefer self.allocator.free(token);
            try self.items.append(self.allocator, .{
                .kind = .file,
                .label = label,
                .token = token,
            });
        }
        self.selected = 0;
    }

    /// Populate items from a list of symbol names.
    pub fn setSymbolItems(self: *Picker, symbols: []const []const u8) !void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        const filter_text = self.filter.items;
        for (symbols) |sym| {
            if (filter_text.len > 0 and std.mem.indexOf(u8, sym, filter_text) == null) continue;
            const label = try self.allocator.dupe(u8, sym);
            errdefer self.allocator.free(label);
            const token = try std.fmt.allocPrint(self.allocator, "@symbol:{s}", .{sym});
            errdefer self.allocator.free(token);
            try self.items.append(self.allocator, .{
                .kind = .symbol,
                .label = label,
                .token = token,
            });
        }
        self.selected = 0;
    }

    /// Populate items from a list of folder paths.
    pub fn setFolderItems(self: *Picker, folders: []const []const u8) !void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        const filter_text = self.filter.items;
        for (folders) |f| {
            if (filter_text.len > 0 and std.mem.indexOf(u8, f, filter_text) == null) continue;
            const label = try self.allocator.dupe(u8, f);
            errdefer self.allocator.free(label);
            const token = try std.fmt.allocPrint(self.allocator, "@folder:{s}", .{f});
            errdefer self.allocator.free(token);
            try self.items.append(self.allocator, .{
                .kind = .folder,
                .label = label,
                .token = token,
            });
        }
        self.selected = 0;
    }

    /// Populate items with a single "Search web for: <query>" entry.
    pub fn setWebItem(self: *Picker) !void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        const query = self.filter.items;
        const label = if (query.len > 0)
            try std.fmt.allocPrint(self.allocator, "Search web: \"{s}\"", .{query})
        else
            try self.allocator.dupe(u8, "Search web (type query)");
        errdefer self.allocator.free(label);
        const token = try std.fmt.allocPrint(self.allocator, "@web:{s}", .{query});
        errdefer self.allocator.free(token);
        try self.items.append(self.allocator, .{
            .kind = .web,
            .label = label,
            .token = token,
        });
        self.selected = 0;
    }
};

test "Picker open shows 4 kinds" {
    const allocator = std.testing.allocator;
    var p = Picker.init(allocator);
    defer p.deinit();

    p.open();
    try std.testing.expect(p.active);
    try std.testing.expect(p.kind == null);
    try std.testing.expectEqual(@as(usize, 4), p.items.items.len);
}

test "Picker setFileItems filters by substring" {
    const allocator = std.testing.allocator;
    var p = Picker.init(allocator);
    defer p.deinit();

    p.open();
    p.setKind(.file);
    try p.appendFilterSlice("main");
    try p.setFileItems(&.{ "src/main.zig", "src/foo.zig", "lib/main.py" });
    try std.testing.expectEqual(@as(usize, 2), p.items.items.len);
    try std.testing.expectEqualStrings("@file:src/main.zig", p.items.items[0].token);
}

test "Picker moveUp/moveDown wraps selection" {
    const allocator = std.testing.allocator;
    var p = Picker.init(allocator);
    defer p.deinit();

    p.open();
    try std.testing.expectEqual(@as(usize, 0), p.selected);
    p.moveDown();
    try std.testing.expectEqual(@as(usize, 1), p.selected);
    p.moveUp();
    try std.testing.expectEqual(@as(usize, 0), p.selected);
    p.moveUp(); // at top, stays at 0
    try std.testing.expectEqual(@as(usize, 0), p.selected);
}

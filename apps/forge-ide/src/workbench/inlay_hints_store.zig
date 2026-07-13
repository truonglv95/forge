//! Inlay hints store — caches LSP `textDocument/inlayHint` results per
//! file, keyed by file path hash + buffer revision.
//!
//! The LSP request itself is sent by `lsp_sync.zig` after each
//! `didChange`. The response is parsed by `packages/lsp/src/inlay_hints.zig`
//! and stored here. The editor renderer (`viewport.zig`) reads from this
//! store to draw faint inline text (parameter names, inferred types)
//! alongside code.

const std = @import("std");
const lsp = @import("forge-lsp");

pub const Hint = struct {
    /// 0-indexed line.
    line: u32,
    /// 0-indexed character (column) where the hint should be displayed.
    character: u32,
    /// The hint text to display (already includes any padding/quotes).
    label: []const u8,
    /// 1 = type hint, 2 = parameter hint.
    kind: u32,
    /// Optional tooltip text (not yet rendered — for future).
    tooltip: ?[]const u8 = null,

    pub fn deinit(self: *Hint, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.tooltip) |t| allocator.free(t);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    /// File path → entry mapping.
    entries: std.StringHashMap(Entry),

    pub const Entry = struct {
        /// Buffer revision when this entry was last updated.
        revision: u64 = 0,
        /// Owned hints array.
        hints: []Hint = &.{},

        pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            for (self.hints) |*h| h.deinit(allocator);
            if (self.hints.len > 0) allocator.free(self.hints);
            self.hints = &.{};
        }
    };

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Get hints for a file, or null if not cached. Returned slice is
    /// borrowed from the store — caller must NOT free.
    pub fn get(self: *Store, path: []const u8) ?[]const Hint {
        if (self.entries.get(path)) |entry| {
            return entry.hints;
        }
        return null;
    }

    /// Replace hints for a file. Takes ownership of `hints` array
    /// (caller must have allocated it with `self.allocator`).
    /// Each Hint's `label` must also be allocator-owned.
    pub fn set(self: *Store, path: []const u8, revision: u64, hints: []Hint) !void {
        const gop = try self.entries.getOrPut(path);
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.allocator);
        }
        gop.value_ptr.* = .{
            .revision = revision,
            .hints = hints,
        };
    }

    /// Invalidate (remove) hints for a file. Called when a file is closed.
    pub fn invalidate(self: *Store, path: []const u8) void {
        if (self.entries.fetchRemove(path)) |kv| {
            var entry = kv.value;
            entry.deinit(self.allocator);
        }
    }

    /// Clear all cached hints (e.g. on LSP restart).
    pub fn clear(self: *Store) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Convert an LSP `InlayHintList` into our owned `[]Hint` array.
    /// Caller passes the result to `set()`.
    pub fn fromLspHints(allocator: std.mem.Allocator, lsp_hints: lsp.inlay_hints.InlayHintList) ![]Hint {
        var out = try allocator.alloc(Hint, lsp_hints.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |*h| h.deinit(allocator);
            allocator.free(out);
        }
        while (i < lsp_hints.items.len) : (i += 1) {
            const lh = lsp_hints.items[i];
            const label_owned = try allocator.dupe(u8, lh.label);
            errdefer allocator.free(label_owned);
            out[i] = .{
                .line = lh.line,
                .character = lh.character,
                .label = label_owned,
                .kind = @intFromEnum(lh.kind),
            };
        }
        return out;
    }
};

test "Store set/get/invalidate" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();

    var hints = try allocator.alloc(Hint, 1);
    hints[0] = .{
        .line = 0,
        .character = 5,
        .label = try allocator.dupe(u8, ": i32"),
        .kind = 1,
    };

    try s.set("main.zig", 1, hints);
    const got = s.get("main.zig").?;
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings(": i32", got[0].label);

    s.invalidate("main.zig");
    try std.testing.expect(s.get("main.zig") == null);
}

test "Store set replaces existing entry" {
    const allocator = std.testing.allocator;
    var s = Store.init(allocator);
    defer s.deinit();

    var hints1 = try allocator.alloc(Hint, 1);
    hints1[0] = .{ .line = 0, .character = 0, .label = try allocator.dupe(u8, "a"), .kind = 1 };
    try s.set("f.zig", 1, hints1);

    var hints2 = try allocator.alloc(Hint, 2);
    hints2[0] = .{ .line = 0, .character = 0, .label = try allocator.dupe(u8, "b"), .kind = 1 };
    hints2[1] = .{ .line = 1, .character = 0, .label = try allocator.dupe(u8, "c"), .kind = 2 };
    try s.set("f.zig", 2, hints2);

    const got = s.get("f.zig").?;
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("b", got[0].label);
}

const std = @import("std");
const workspace = @import("forge-workspace");
const buffer_mod = @import("buffer.zig");

pub const Document = struct {
    path: []const u8,
    buffer: buffer_mod.Buffer,
    saved_hash: u64,
    disk_hash: u64,
    external_conflict: bool,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Document {
        return .{
            .path = try allocator.dupe(u8, path),
            .buffer = try buffer_mod.Buffer.init(allocator),
            .saved_hash = 0,
            .disk_hash = 0,
            .external_conflict = false,
        };
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.buffer.deinit();
    }

    pub fn isDirty(self: *const Document) bool {
        const current = self.currentHash() catch return true;
        return current != self.saved_hash;
    }

    pub fn currentHash(self: *const Document) !u64 {
        const content = try self.buffer.content();
        defer self.buffer.allocator.free(content);
        return workspace.edit.contentHash(content);
    }

    pub fn markSaved(self: *Document) !void {
        self.saved_hash = try self.currentHash();
        self.disk_hash = self.saved_hash;
        self.external_conflict = false;
    }

    pub fn checkExternalConflict(self: *Document, io: std.Io, root: workspace.WorkspaceRoot) !void {
        const wp = workspace.WorkspacePath.parse(self.path) catch return;
        var snap = workspace.FileSnapshot.read(self.buffer.allocator, io, root, wp) catch |err| switch (err) {
            error.FileNotFound => {
                self.external_conflict = self.saved_hash != 0;
                return;
            },
            else => return err,
        };
        defer snap.deinit();
        self.disk_hash = snap.hash;
        self.external_conflict = snap.hash != self.saved_hash;
    }
};

pub const TabGroup = struct {
    allocator: std.mem.Allocator,
    tabs: std.ArrayList(Document),
    active: usize,

    pub fn init(allocator: std.mem.Allocator) TabGroup {
        return .{
            .allocator = allocator,
            .tabs = .empty,
            .active = 0,
        };
    }

    pub fn deinit(self: *TabGroup) void {
        for (self.tabs.items) |*doc| doc.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
    }

    pub fn activeDoc(self: *TabGroup) ?*Document {
        if (self.tabs.items.len == 0) return null;
        if (self.active >= self.tabs.items.len) self.active = self.tabs.items.len - 1;
        return &self.tabs.items[self.active];
    }

    pub fn closeAt(self: *TabGroup, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.tabs.items[index].deinit(self.allocator);
        _ = self.tabs.orderedRemove(index);
        if (self.tabs.items.len == 0) {
            self.active = 0;
            return;
        }
        if (self.active > index) {
            self.active -= 1;
        } else if (self.active >= self.tabs.items.len) {
            self.active = self.tabs.items.len - 1;
        }
    }

    pub fn closeAll(self: *TabGroup) void {
        for (self.tabs.items) |*doc| doc.deinit(self.allocator);
        self.tabs.clearRetainingCapacity();
        self.active = 0;
    }

    pub fn openOrActivate(self: *TabGroup, path: []const u8) !*Document {
        for (self.tabs.items, 0..) |*doc, index| {
            if (std.mem.eql(u8, doc.path, path)) {
                self.active = index;
                return doc;
            }
        }
        var doc = try Document.init(self.allocator, path);
        errdefer doc.deinit(self.allocator);
        try self.tabs.append(self.allocator, doc);
        self.active = self.tabs.items.len - 1;
        return &self.tabs.items[self.active];
    }
};

test "tab group close and close all" {
    const allocator = std.testing.allocator;
    var group = TabGroup.init(allocator);
    defer group.deinit();

    _ = try group.openOrActivate("a.zig");
    _ = try group.openOrActivate("b.zig");
    try std.testing.expectEqual(@as(usize, 2), group.tabs.items.len);

    group.closeAt(0);
    try std.testing.expectEqual(@as(usize, 1), group.tabs.items.len);
    try std.testing.expectEqualStrings("b.zig", group.tabs.items[0].path);

    group.closeAll();
    try std.testing.expectEqual(@as(usize, 0), group.tabs.items.len);
}

test "document dirty tracking uses content hash" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, "sample.txt");
    defer doc.deinit(allocator);

    try doc.buffer.loadFromSlice("hello");
    try doc.markSaved();
    try std.testing.expect(!doc.isDirty());

    try doc.buffer.insertString("!");
    try std.testing.expect(doc.isDirty());
}

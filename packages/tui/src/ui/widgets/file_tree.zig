//! File Tree widget for directory navigation

const std = @import("std");
const layouts = @import("../layouts/layouts.zig");

pub const TreeNode = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    children: std.ArrayList(TreeNode),
    expanded: bool = false,
    depth: usize = 0,

    pub fn deinit(self: *TreeNode, allocator: Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit();
    }
};

pub const FileTree = struct {
    rect: layouts.Rect,
    root: ?TreeNode,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    visible_items: std.ArrayList(TreeNode),
    allocator: Allocator,

    pub fn init(allocator: Allocator) FileTree {
        return .{
            .rect = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .root = null,
            .visible_items = std.ArrayList(TreeNode).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileTree) void {
        if (self.root) |*r| {
            r.deinit(self.allocator);
        }
        self.visible_items.deinit();
    }

    pub fn loadDirectory(self: *FileTree, path: []const u8) !void {
        // Simple implementation - in real app would use fs.Dir
        if (self.root) |*r| {
            r.deinit(self.allocator);
        }
        
        self.root = TreeNode{
            .name = "project",
            .path = path,
            .is_dir = true,
            .children = std.ArrayList(TreeNode).init(self.allocator),
            .depth = 0,
        };

        try self.updateVisibleItems();
    }

    fn updateVisibleItems(self: *FileTree) !void {
        self.visible_items.clearRetainingCapacity();
        if (self.root) |*r| {
            try self.collectVisibleItems(r, 0);
        }
    }

    fn collectVisibleItems(self: *FileTree, node: *TreeNode, index: usize) !void {
        try self.visible_items.append(node.*);
        
        if (node.expanded) {
            for (node.children.items) |*child| {
                try self.collectVisibleItems(child, index + 1);
            }
        }
    }

    pub fn render(self: *const FileTree, writer: anytype) !void {
        try writer.writeAll("\x1b[1m=== File Explorer ===\x1b[0m\n\n");

        for (self.visible_items.items, 0..) |item, i| {
            if (i == self.selected_index) {
                try writer.writeAll("\x1b[7m");
            }

            // Indent
            var d: usize = 0;
            while (d < item.depth) : (d += 1) {
                try writer.writeAll("  ");
            }

            // Icon
            if (item.is_dir) {
                try writer.writeAll("📁 ");
            } else {
                try writer.writeAll("📄 ");
            }

            try writer.writeAll(item.name);

            if (i == self.selected_index) {
                try writer.writeAll("\x1b[0m");
            }
            try writer.writeAll("\n");
        }
    }
};

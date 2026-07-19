const std = @import("std");
const workspace = @import("forge-workspace");

pub const ExplorerController = struct {
    entries: []const workspace.DirEntry = &[_]workspace.DirEntry{},
    scroll_y: f32 = 0,
    panel_width: f32 = 250,
    boot_pending: bool = false,
    root_expanded: bool = true,

    pub fn init() ExplorerController {
        return .{};
    }

    pub fn deinit(self: *ExplorerController, allocator: std.mem.Allocator) void {
        for (self.entries) |e| {
            allocator.free(e.path);
        }
        allocator.free(self.entries);
    }
};

const std = @import("std");
const workspace = @import("forge-workspace");
const sync_mod = @import("forge-core").sync;

pub const SearchController = struct {
    results: ?workspace.search.SearchResult = null,
    pending_results: ?workspace.search.SearchResult = null,
    mutex: sync_mod.Mutex = .{},
    running: bool = false,
    ready: bool = false,
    failed: bool = false,
    scroll_y: f32 = 0,

    pub fn init() SearchController {
        return .{};
    }

    pub fn deinit(self: *SearchController, allocator: std.mem.Allocator) void {
        if (self.results) |*res| res.deinit(allocator);
        if (self.pending_results) |*res| res.deinit(allocator);
    }
};

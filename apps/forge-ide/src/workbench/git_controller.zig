const std = @import("std");
const sync_mod = @import("forge-core").sync;
const git_status_mod = @import("git/status.zig");
const editor = @import("forge-editor");

pub const GitController = struct {
    status: ?git_status_mod.Status = null,
    refresh_mutex: sync_mod.Mutex = .{},
    refresh_running: bool = false,
    refresh_ready: bool = false,
    refresh_failed: bool = false,
    refresh_pending_status: ?git_status_mod.Status = null,
    push_running: bool = false,
    push_done: bool = false,
    pull_running: bool = false,
    pull_done: bool = false,
    scroll_y: f32 = 0,
    commit_msg: editor.Buffer,
    staged_collapsed: bool = false,
    changes_collapsed: bool = false,
    sync_icon_angle: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) GitController {
        return .{
            .commit_msg = editor.Buffer.init(allocator),
        };
    }

    pub fn deinit(self: *GitController, allocator: std.mem.Allocator) void {
        if (self.status) |*status| status.deinit(allocator);
        self.refresh_mutex.lock();
        if (self.refresh_pending_status) |*status| status.deinit(allocator);
        self.refresh_pending_status = null;
        self.refresh_mutex.unlock();
        self.refresh_mutex.deinit();
        self.commit_msg.deinit();
    }
};

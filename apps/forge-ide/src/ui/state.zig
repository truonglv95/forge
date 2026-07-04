const std = @import("std");
const renderer = @import("forge-renderer");
const Workbench = @import("../workbench.zig").Workbench;

pub var gpa: std.mem.Allocator = undefined;
pub var wb: ?*Workbench = undefined;

pub var time: f32 = 0;
pub var root_view: ?*renderer.View = null;
pub var header_view: ?*renderer.View = null;
pub var activity_view: ?*renderer.View = null;
pub var agent_view: ?*renderer.View = null;
pub var explorer_view: ?*renderer.View = null;
pub var editor_view: ?*renderer.View = null;
pub var panel_view: ?*renderer.View = null;
pub var border_view: ?*renderer.View = null;
pub var status_view: ?*renderer.View = null;

pub var prompt_buffer: ?*@import("forge-editor").Buffer = null;
pub var chat_history: ?*std.ArrayList(@import("../workbench.zig").ChatMessage) = null;

pub var is_dragging_agent_splitter: bool = false;
pub var is_dragging_explorer_splitter: bool = false;
pub var is_dragging_bottom_panel_splitter: bool = false;
pub var is_dragging_terminal_selection: bool = false;
pub var last_mouse_x: f32 = 0;
pub var last_mouse_y: f32 = 0;

pub const StatusBridge = struct {
    pub fn setStatus(message: []const u8) void {
        const workbench = wb orelse return;
        workbench.setStatus(message) catch {};
    }
};

pub fn workbenchPtr() *Workbench {
    return wb orelse unreachable;
}

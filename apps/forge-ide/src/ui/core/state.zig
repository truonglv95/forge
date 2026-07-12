const std = @import("std");
const renderer = @import("forge-renderer");
const Workbench = @import("../../workbench.zig").Workbench;

pub var gpa: std.mem.Allocator = undefined;
pub var wb: ?*Workbench = undefined;
pub var renderer_theme: *renderer.theme_mod.Theme = undefined;

pub var time: f32 = 0;
pub var perf_overlay_enabled: bool = false;
pub var perf_frame_ms: f32 = 0;
pub var perf_tick_ms: f32 = 0;
pub var perf_layout_ms: f32 = 0;
pub var perf_draw_ms: f32 = 0;
pub var perf_sidebar_ms: f32 = 0;
pub var perf_editor_ms: f32 = 0;
pub var perf_panel_ms: f32 = 0;
pub var perf_agent_ms: f32 = 0;
pub var perf_measure_hits: u64 = 0;
pub var perf_measure_misses: u64 = 0;
pub var perf_markdown_height_hits: u64 = 0;
pub var perf_markdown_height_misses: u64 = 0;
pub var perf_redraw_requests: u64 = 0;
pub var perf_frames: u64 = 0;
pub var perf_agent_queue_coalesced: u64 = 0;
pub var continuous_rendering_enabled: bool = false;

pub const DirtyPanel = enum(u3) {
    sidebar,
    editor,
    bottom_panel,
    agent,
    status,
};

pub var dirty_panels: u8 = 0xff;

pub fn markDirty(panel: DirtyPanel) void {
    dirty_panels |= @as(u8, 1) << @intFromEnum(panel);
    renderer.Renderer.requestRedraw();
}

pub fn markAllDirty() void {
    dirty_panels = 0xff;
    renderer.Renderer.requestRedraw();
}

pub fn clearDirty() void {
    dirty_panels = 0;
}
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
pub var chat_history: ?*std.ArrayList(@import("../../workbench.zig").ChatMessage) = null;

pub var is_dragging_agent_splitter: bool = false;
pub var is_dragging_explorer_splitter: bool = false;
pub var is_dragging_bottom_panel_splitter: bool = false;
pub var header_hover_action: ?@import("../chrome/header_toolbar.zig").Action = null;
pub var is_dragging_terminal_selection: bool = false;
pub var is_dragging_editor_selection: bool = false;
pub var is_dragging_chat_selection: bool = false;
pub var chat_selection: ?struct {
    msg_hash: u64,
    start: usize,
    end: usize,
} = null;
pub var last_mouse_x: f32 = 0;
pub var last_mouse_y: f32 = 0;
pub var explorer_hover_row: ?usize = null;

pub const StatusBridge = struct {
    pub fn setStatus(message: []const u8) void {
        const workbench = wb orelse return;
        workbench.setStatus(message) catch {};
    }
};

pub fn workbenchPtr() *Workbench {
    return wb orelse unreachable;
}

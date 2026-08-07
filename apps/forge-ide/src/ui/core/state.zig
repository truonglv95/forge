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
pub var perf_status_ms: f32 = 0;
pub var perf_measure_hits: u64 = 0;
pub var perf_measure_misses: u64 = 0;
pub var perf_markdown_height_hits: u64 = 0;
pub var perf_markdown_height_misses: u64 = 0;
pub var perf_redraw_requests: u64 = 0;
pub var perf_frames: u64 = 0;
pub var perf_agent_queue_coalesced: u64 = 0;
pub var perf_last_frame_ms: i64 = 0;
pub var perf_frame_count: u64 = 0;
pub var continuous_rendering_enabled: bool = false;

// --- Caret blink / focus tracking ---------------------------------------
//
// The caret blinks at ~1.06s period (0.53s on, 0.53s off). Instead of
// running the compositor at 60fps continuously (which caused Mac heat
// issues — ~30-60% CPU even when idle), we schedule a redraw only when
// the blink state is about to flip. This drops idle CPU to ~0%.
//
// `caret_blink_last_flip_ms` tracks when the blink last toggled. The
// render loop checks if 530ms have elapsed and, if so, requests a redraw
// (which flips the blink state and re-schedules the next flip).
pub var caret_blink_editor_focused: bool = false;
pub var caret_blink_visible: bool = true;
pub var caret_blink_last_flip_ms: i64 = 0;
pub const caret_blink_half_period_ms: i64 = 530;

/// Notify the blink scheduler that a text input has gained or lost focus.
/// No-op when the state hasn't changed.
pub fn setEditorFocused(focused: bool) void {
    if (caret_blink_editor_focused == focused) return;
    caret_blink_editor_focused = focused;
    if (focused) {
        // Reset blink to visible + schedule immediate redraw so the caret
        // appears on focus. The timestamp will be set on the first
        // tickCaretBlink() call from the render loop.
        caret_blink_visible = true;
        caret_blink_last_flip_ms = 0; // will be set by first tick
        renderer.Renderer.requestRedraw();
    }
}

/// Called from the render loop each frame. Returns true if the blink
/// state flipped (caller should request another redraw to continue the
/// blink cycle). When the editor is not focused, this is a no-op.
pub fn tickCaretBlink(now_ms: i64) bool {
    if (!caret_blink_editor_focused) return false;
    // First tick after focus — initialize the timestamp without flipping.
    if (caret_blink_last_flip_ms == 0) {
        caret_blink_last_flip_ms = now_ms;
        return false;
    }
    if (now_ms - caret_blink_last_flip_ms < caret_blink_half_period_ms) return false;
    // Flip the blink state + record the flip time.
    caret_blink_visible = !caret_blink_visible;
    caret_blink_last_flip_ms = now_ms;
    return true; // signal that a redraw is needed to show the new state
}

// Persistent frame arena — reused across frames to avoid init/deinit
// overhead. Reset (not deinit) at frame start for O(1) cleanup.
pub var frame_arena: ?std.heap.ArenaAllocator = null;
pub var frame_arena_inited: bool = false;
/// Peak frame arena usage in bytes (high-water mark across the session).
/// Used to tune the arena's retained capacity so we don't over-allocate
/// or trigger expensive grows mid-frame. Logged in the perf overlay.
pub var frame_arena_peak_bytes: usize = 0;
/// Frame arena usage at the end of the previous frame. Updated by
/// onRenderFrame after all panels have drawn. When this grows slowly
/// across frames (e.g. user scrolls a large file), the arena's backing
/// buffer is already sized correctly — no realloc needed.
pub var frame_arena_last_bytes: usize = 0;

// Dirty region tracking — marks which panels need redraw.
// When a panel is dirty, only that panel is redrawn; other panels
// retain their previous framebuffer content. When ALL panels are
// dirty (or on first frame), full redraw is performed.
pub var dirty_sidebar: bool = true;
pub var dirty_editor: bool = true;
pub var dirty_agent: bool = true;
pub var dirty_bottom_panel: bool = true;
pub var dirty_status_bar: bool = true;
pub var dirty_full: bool = true; // Force full redraw
pub var first_frame: bool = true;

pub fn markAllDirty() void {
    dirty_sidebar = true;
    dirty_editor = true;
    dirty_agent = true;
    dirty_bottom_panel = true;
    dirty_status_bar = true;
    dirty_full = true;
}

pub fn clearDirty() void {
    dirty_sidebar = false;
    dirty_editor = false;
    dirty_agent = false;
    dirty_bottom_panel = false;
    dirty_status_bar = false;
    dirty_full = false;
    first_frame = false;
}

pub fn anyDirty() bool {
    return dirty_full or dirty_sidebar or dirty_editor or dirty_agent or dirty_bottom_panel or dirty_status_bar;
}

pub const DirtyPanel = enum(u3) {
    sidebar,
    editor,
    bottom_panel,
    agent,
    status,
};

pub fn markDirty(panel: DirtyPanel) void {
    switch (panel) {
        .sidebar => dirty_sidebar = true,
        .editor => dirty_editor = true,
        .bottom_panel => dirty_bottom_panel = true,
        .agent => dirty_agent = true,
        .status => dirty_status_bar = true,
    }
    renderer.Renderer.requestRedraw();
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

// Tab drag state — set when the user clicks and drags a tab to reorder it.
// drag_source_index is the tab being dragged; drag_target_index is the
// insertion target (where the tab would land if released now). -1 means
// no drag in progress. The renderer reads these to draw the drag handle
// indicator on the target tab.
pub var tab_drag_source: ?usize = null;
pub var tab_drag_target: ?usize = null;
pub var tab_drag_start_x: f32 = 0;
pub var tab_drag_start_y: f32 = 0;

pub const StatusBridge = struct {
    pub fn setStatus(message: []const u8) void {
        const workbench = wb orelse return;
        workbench.setStatus(message) catch {};
    }
};

pub fn workbenchPtr() *Workbench {
    return wb orelse unreachable;
}

const commands_mod = @import("../workbench/commands.zig");

pub const tab_bar_height: f32 = 28;
pub const tab_h: f32 = 18;
pub const tab_y_offset: f32 = 6;

pub const Tab = struct {
    label: []const u8,
    mode: commands_mod.BottomPanelMode,
    x_offset: f32,
    w: f32,
};

pub const tabs = [_]Tab{
    .{ .label = "OUTPUT", .mode = .output, .x_offset = 12, .w = 72 },
    .{ .label = "PROBLEMS", .mode = .problems, .x_offset = 88, .w = 92 },
    .{ .label = "TERMINAL", .mode = .terminal, .x_offset = 184, .w = 82 },
    .{ .label = "DEBUG", .mode = .debug_console, .x_offset = 268, .w = 72 },
    .{ .label = "VARS", .mode = .debug_variables, .x_offset = 344, .w = 52 },
    .{ .label = "STACK", .mode = .debug_callstack, .x_offset = 400, .w = 64 },
};

pub fn tabBarTop(panel_y: f32) f32 {
    return panel_y + tab_y_offset;
}

pub fn hitTab(editor_x: f32, panel_y: f32, x: f32, y: f32) ?commands_mod.BottomPanelMode {
    if (y < panel_y or y >= panel_y + tab_bar_height) return null;
    for (tabs) |tab| {
        const left = editor_x + tab.x_offset;
        if (x >= left and x < left + tab.w) return tab.mode;
    }
    return null;
}

pub fn inContentArea(panel_y: f32, y: f32) bool {
    return y >= panel_y + tab_bar_height;
}

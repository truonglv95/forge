const layout = @import("layout.zig");
const sidebar_view = @import("sidebar_view.zig");

// Start horizontally from the left edge
pub const icon_x_start: f32 = 0;
pub const icon_w: f32 = 40;

pub fn iconIndex(view: sidebar_view.SidebarView) ?usize {
    for (sidebar_view.all, 0..) |entry, index| {
        if (entry == view) return index;
    }
    return null;
}

pub fn iconX(view: sidebar_view.SidebarView) f32 {
    const index = iconIndex(view) orelse return icon_x_start;
    return icon_x_start + @as(f32, @floatFromInt(index)) * icon_w;
}

pub fn hitTest(x: f32, y: f32, explorer_w: f32) ?sidebar_view.SidebarView {
    // Height is activity_bar_height (35)
    if (y < layout.header_height or y >= layout.header_height + layout.activity_bar_height) return null;
    if (x < 0 or x >= explorer_w) return null;

    // In horizontal layout, we can center it if needed, but let's assume it's left-aligned for now,
    // or we can center the block. Let's assume left aligned but with some padding.
    // Let's use a dynamic start X to center them:
    const total_w = @as(f32, @floatFromInt(sidebar_view.all.len)) * icon_w;
    const padding = @max(0, (explorer_w - total_w) / 2);

    for (sidebar_view.all, 0..) |view, index| {
        const left = padding + @as(f32, @floatFromInt(index)) * icon_w;
        if (x >= left and x < left + icon_w) return view;
    }
    return null;
}

pub fn iconCenter(view: sidebar_view.SidebarView, explorer_w: f32) struct { x: f32, y: f32 } {
    const index = iconIndex(view) orelse 0;
    const total_w = @as(f32, @floatFromInt(sidebar_view.all.len)) * icon_w;
    const padding = @max(0, (explorer_w - total_w) / 2);
    const left = padding + @as(f32, @floatFromInt(index)) * icon_w;
    return .{
        .x = left + icon_w / 2,
        .y = layout.header_height + layout.activity_bar_height / 2,
    };
}

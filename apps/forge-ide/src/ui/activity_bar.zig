const layout = @import("layout.zig");
const sidebar_view = @import("sidebar_view.zig");

pub const icon_y: f32 = 36;
pub const icon_h: f32 = 40;

pub fn iconIndex(view: sidebar_view.SidebarView) ?usize {
    for (sidebar_view.all, 0..) |entry, index| {
        if (entry == view) return index;
    }
    return null;
}

pub fn iconY(view: sidebar_view.SidebarView) f32 {
    const index = iconIndex(view) orelse return icon_y;
    return icon_y + @as(f32, @floatFromInt(index)) * icon_h;
}

pub fn hitTest(x: f32, y: f32) ?sidebar_view.SidebarView {
    if (x < 0 or x >= layout.activity_bar_width) return null;
    for (sidebar_view.all, 0..) |view, index| {
        const top = icon_y + @as(f32, @floatFromInt(index)) * icon_h;
        if (y >= top and y < top + icon_h) return view;
    }
    return null;
}

pub fn iconCenter(view: sidebar_view.SidebarView) struct { x: f32, y: f32 } {
    const top = iconY(view);
    return .{
        .x = layout.activity_bar_width / 2,
        .y = top + icon_h / 2,
    };
}

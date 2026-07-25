const std = @import("std");
const renderer = @import("forge-renderer");

/// Thin modern scrollbar — 6px wide, rounded corners, semi-transparent.
pub const track_w: f32 = 6;
pub const thumb_min_h: f32 = 24;
pub const edge_inset: f32 = 3;

// Scrollbar colors — subtle, becomes more visible on hover.
const thumb_idle = renderer.Color{ .r = 0.5, .g = 0.5, .b = 0.55, .a = 0.3 };
const thumb_hover = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.65, .a = 0.6 };

pub fn hovered(mouse_x: f32, mouse_y: f32, x: f32, y: f32, w: f32, h: f32) bool {
    return mouse_x >= x and mouse_x < x + w and mouse_y >= y and mouse_y < y + h;
}

pub fn drawVertical(
    track_x: f32,
    track_y: f32,
    track_h: f32,
    scroll_y: f32,
    max_scroll: f32,
    content_h: f32,
    visible_h: f32,
    show: bool,
) void {
    if (!show or max_scroll <= 0 or track_h <= 0 or content_h <= 0) return;
    const usable_h = @max(0, track_h - edge_inset * 2);
    const thumb_h = @max(thumb_min_h, usable_h * visible_h / content_h);
    const scroll_ratio = if (max_scroll > 0) scroll_y / max_scroll else 0;
    const thumb_y = track_y + edge_inset + scroll_ratio * @max(0, usable_h - thumb_h);
    // Use rounded rect for modern scrollbar appearance
    renderer.Renderer.drawRoundedRect(track_x, thumb_y, track_w, thumb_h, 3, thumb_idle);
}

pub fn drawHorizontal(
    track_x: f32,
    track_y: f32,
    track_area_w: f32,
    scroll_x: f32,
    max_scroll: f32,
    content_w: f32,
    visible_w: f32,
    show: bool,
) void {
    if (!show or max_scroll <= 0 or track_area_w <= 0 or content_w <= 0) return;
    const usable_w = @max(0, track_area_w - edge_inset * 2);
    const thumb_w = @max(thumb_min_h, usable_w * visible_w / content_w);
    const scroll_ratio = if (max_scroll > 0) scroll_x / max_scroll else 0;
    const thumb_x = track_x + edge_inset + scroll_ratio * @max(0, usable_w - thumb_w);
    renderer.Renderer.drawRoundedRect(thumb_x, track_y, thumb_w, track_w, 3, thumb_idle);
}

pub fn sidebarMetrics(row_count: usize, row_h: f32, list_top: f32, window_h: f32, status_h: f32) struct {
    viewport_h: f32,
    content_h: f32,
    max_scroll: f32,
} {
    const viewport_h = @max(0, window_h - status_h - list_top);
    const content_h = @as(f32, @floatFromInt(row_count)) * row_h;
    const max_scroll = @max(0, content_h - viewport_h);
    return .{ .viewport_h = viewport_h, .content_h = content_h, .max_scroll = max_scroll };
}

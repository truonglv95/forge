const std = @import("std");
const renderer = @import("forge-renderer");

/// VS Code default verticalScrollbarSize.
pub const track_w: f32 = 10;
pub const thumb_min_h: f32 = 24;
/// Small inset so thumb does not touch panel edges (matches VS Code slider padding).
pub const edge_inset: f32 = 2;

// vscode theme: scrollbarSlider.hoverBackground (#A8A9AA90) — shown on panel hover.
const thumb_color = renderer.Color{ .r = 0.659, .g = 0.663, .b = 0.667, .a = 0.56 };

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
    renderer.Renderer.drawRect(track_x, thumb_y, track_w, thumb_h, thumb_color);
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
    renderer.Renderer.drawRect(thumb_x, track_y, thumb_w, track_w, thumb_color);
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

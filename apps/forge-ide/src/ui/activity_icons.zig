const renderer = @import("forge-renderer");
const sidebar_view = @import("sidebar_view.zig");

const Color = renderer.Color;

fn strokeH(x: f32, y: f32, w: f32, t: f32, color: Color) void {
    renderer.Renderer.drawRect(x, y, w, t, color);
}

fn strokeV(x: f32, y: f32, h: f32, t: f32, color: Color) void {
    renderer.Renderer.drawRect(x, y, t, h, color);
}

fn strokeRect(x: f32, y: f32, w: f32, h: f32, t: f32, color: Color) void {
    strokeH(x, y, w, t, color);
    strokeH(x, y + h - t, w, t, color);
    strokeV(x, y, h, t, color);
    strokeV(x + w - t, y, h, t, color);
}

pub fn draw(view: sidebar_view.SidebarView, cx: f32, cy: f32, color: Color) void {
    const s: f32 = 9.0;
    const x = cx - s / 2;
    const y = cy - s / 2;
    const t: f32 = 1.6;

    switch (view) {
        .explorer => {
            strokeRect(x + 1, y, s - 2, s - 3, t, color);
            strokeH(x + 3, y + 3, s - 6, t, color);
            strokeRect(x + 3, y + 5, s - 6, s - 8, t, color);
        },
        .search => {
            strokeRect(x + 2, y + 2, s - 5, s - 5, t, color);
            strokeH(x + s - 4, y + s - 4, 4.5, t + 0.2, color);
            strokeV(x + s - 2, y + s - 2, 4.5, t + 0.2, color);
        },
        .git => {
            strokeV(x + 4, y + 1, s - 2, t, color);
            renderer.Renderer.drawRoundedRect(x + 2, y + 1, 4, 4, 2, color);
            renderer.Renderer.drawRoundedRect(x + s - 6, y + s / 2 - 1, 4, 4, 2, color);
            renderer.Renderer.drawRoundedRect(x + 2, y + s - 5, 4, 4, 2, color);
            strokeH(x + 5, y + 3, s - 8, t, color);
            strokeH(x + 5, y + s / 2 + 1, s - 8, t, color);
        },
        .run => {
            strokeH(x, y + 1, s, t, color);
            strokeH(x, y + s - t - 1, s, t, color);
            strokeV(x, y + 1, s - 2, t, color);
            strokeV(x + s - t, y + 1, s - 2, t, color);
            strokeH(x + 3, y + 3, 3, t, color);
            strokeV(x + 3, y + 3, s - 6, t, color);
            renderer.Renderer.drawRect(x + 5, y + 3, 4, s - 6, color);
        },
        .extensions => {
            const u: f32 = (s - t) / 2;
            strokeRect(x, y, u, u, t, color);
            strokeRect(x + u + t, y, u, u, t, color);
            strokeRect(x, y + u + t, u, u, t, color);
            strokeRect(x + u + t, y + u + t, u, u, t, color);
        },
    }
}

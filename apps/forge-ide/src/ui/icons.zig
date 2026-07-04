const renderer = @import("forge-renderer");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const ChevronDirection = enum {
    down,
    up,
    right,
};

pub const chevron_color = renderer.Color{ .r = 0.89, .g = 0.89, .b = 0.89, .a = 1.0 };

fn drawChevronRow(cx: f32, y: f32, half_span: f32, p: f32, color: renderer.Color) void {
    if (half_span <= 0.01) {
        renderer.Renderer.drawRect(cx - p * 0.5, y, p, p, color);
        return;
    }
    renderer.Renderer.drawRect(cx - half_span * p - p * 0.5, y, p, p, color);
    renderer.Renderer.drawRect(cx + half_span * p - p * 0.5, y, p, p, color);
}

fn drawChevronCol(x: f32, cy: f32, half_span: f32, p: f32, color: renderer.Color) void {
    if (half_span <= 0.01) {
        renderer.Renderer.drawRect(x, cy - p * 0.5, p, p, color);
        return;
    }
    renderer.Renderer.drawRect(x, cy - half_span * p - p * 0.5, p, p, color);
    renderer.Renderer.drawRect(x, cy + half_span * p - p * 0.5, p, p, color);
}

/// Material chevron icons (expand_more / expand_less / chevron_right), rasterized small.
pub fn drawChevron(rect: Rect, direction: ChevronDirection, color: renderer.Color) void {
    const cx = @round(rect.x + rect.w * 0.5);
    const cy = @round(rect.y + rect.h * 0.5);
    const p: f32 = 1.0;
    const half_spans = [_]f32{ 2.5, 1.5, 0.5, 0.0 };
    const offsets = [_]f32{ -1.5, -0.5, 0.5, 1.5 };

    switch (direction) {
        .down => {
            var i: usize = 0;
            while (i < half_spans.len) : (i += 1) {
                drawChevronRow(cx, cy + offsets[i] * p, half_spans[i], p, color);
            }
        },
        .up => {
            var i: usize = 0;
            while (i < half_spans.len) : (i += 1) {
                const row = half_spans.len - 1 - i;
                drawChevronRow(cx, cy + offsets[i] * p, half_spans[row], p, color);
            }
        },
        .right => {
            var i: usize = 0;
            while (i < half_spans.len) : (i += 1) {
                drawChevronCol(cx + offsets[i] * p, cy, half_spans[i], p, color);
            }
        },
    }
}

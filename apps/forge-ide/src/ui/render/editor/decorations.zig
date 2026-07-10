const renderer = @import("forge-renderer");
const Buffer = @import("forge-editor").Buffer;

pub fn drawDecorations(
    editor_buf: *Buffer,
    buf_line: usize,
    text_x: f32,
    line_y: f32,
    line_h: f32,
    viewport_w: f32,
) void {
    var l: usize = 0;
    var r: usize = editor_buf.decorations.items.len;
    while (l < r) {
        const m = l + (r - l) / 2;
        if (editor_buf.decorations.items[m].row < buf_line) {
            l = m + 1;
        } else {
            r = m;
        }
    }

    if (l < editor_buf.decorations.items.len) {
        for (editor_buf.decorations.items[l..]) |dec| {
            if (dec.row != buf_line) break;
            const color = if (dec.kind == .addition)
                renderer.Color{ .r = 0.2, .g = 0.7, .b = 0.3, .a = 0.25 }
            else
                renderer.Color{ .r = 0.9, .g = 0.3, .b = 0.3, .a = 0.25 };

            renderer.Renderer.drawRect(text_x - 4, line_y, viewport_w, line_h, color);

            if (dec.kind == .deletion) {
                // Strike-through
                renderer.Renderer.drawRect(text_x, line_y + line_h / 2, viewport_w - 16, 1.5, .{ .r = 0.95, .g = 0.25, .b = 0.25, .a = 0.85 });
            }
        }
    }
}

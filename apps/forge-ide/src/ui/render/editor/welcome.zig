const std = @import("std");
const renderer = @import("forge-renderer");
const Workbench = @import("../../../workbench.zig").Workbench;
const editor_scroll = @import("../../../ui/editor/editor_scroll.zig");
const syntax = @import("syntax.zig");

pub fn draw(wb: *Workbench, editor_x: f32, editor_w: f32, editor_h: f32) void {
    const theme = &wb.theme;
    const bg = syntax.color(theme.colors.editor_bg);
    const text = syntax.color(theme.colors.text_primary);
    const muted = syntax.color(theme.colors.text_muted);
    const accent = syntax.color(theme.colors.accent);
    const border = syntax.color(theme.colors.border);
    const row_bg = syntax.color(theme.colors.tab_bar_bg);

    renderer.Renderer.drawRect(editor_x, editor_scroll.content_top, editor_w, editor_h - editor_scroll.content_top, bg);

    const content_w: f32 = @min(760, @max(280, editor_w - 120));
    const content_x = editor_x + @max(32, (editor_w - content_w) * 0.5);
    var y = editor_scroll.content_top + 86;

    drawText("Forge", content_x, y, 34, text);
    y += 40;
    drawText("AI-first native IDE", content_x + 2, y, 15, muted);
    y += 64;

    drawText("Start", content_x, y, 18, text);
    y += 34;
    drawAction(content_x, y, content_w, renderer.icons.file_directory, "Open current folder", "forge .", accent, row_bg, border, text, muted);
    y += 48;
    drawAction(content_x, y, content_w, renderer.icons.file, "Open a file or folder", "forge /path/to/project", accent, row_bg, border, text, muted);
    y += 68;

    drawText("Recent", content_x, y, 18, text);
    y += 30;
    if (wb.recent_workspace_paths.len == 0) {
        drawText("No recent workspaces yet", content_x, y, 14, muted);
        return;
    }

    const count = @min(wb.recent_workspace_paths.len, 5);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const path = wb.recent_workspace_paths[i];
        const name = std.fs.path.basename(path);
        drawRecent(content_x, y, content_w, name, path, accent, row_bg, border, text, muted);
        y += 46;
    }
}

fn drawAction(
    x: f32,
    y: f32,
    w: f32,
    icon: [:0]const u8,
    title: []const u8,
    command: []const u8,
    accent: renderer.Color,
    bg: renderer.Color,
    border: renderer.Color,
    text: renderer.Color,
    muted: renderer.Color,
) void {
    renderer.Renderer.drawRoundedRect(x, y, w, 38, 6, bg);
    renderer.Renderer.drawRect(x, y + 37, w, 1, border);
    renderer.Renderer.drawSvg(icon, x + 12, y + 10, 18, 18, accent);
    drawText(title, x + 42, y + 8, 14, text);
    drawText(command, x + w - @min(260, w * 0.42), y + 9, 13, muted);
}

fn drawRecent(
    x: f32,
    y: f32,
    w: f32,
    name: []const u8,
    path: []const u8,
    accent: renderer.Color,
    bg: renderer.Color,
    border: renderer.Color,
    text: renderer.Color,
    muted: renderer.Color,
) void {
    renderer.Renderer.drawRoundedRect(x, y, w, 36, 6, bg);
    renderer.Renderer.drawRect(x, y + 35, w, 1, border);
    renderer.Renderer.drawSvg(renderer.icons.repo, x + 12, y + 9, 17, 17, accent);
    drawText(name, x + 42, y + 7, 14, text);
    drawText(path, x + @min(280, w * 0.42), y + 8, 13, muted);
}

fn drawText(text: []const u8, x: f32, y: f32, size: f32, color: renderer.Color) void {
    var buf: [256:0]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    renderer.Renderer.drawText(@ptrCast(&buf), x, y, size, color);
}

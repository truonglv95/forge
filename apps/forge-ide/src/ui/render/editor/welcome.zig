const std = @import("std");
const renderer = @import("forge-renderer");
const Workbench = @import("../../../workbench.zig").Workbench;
const editor_scroll = @import("../../../ui/editor/editor_scroll.zig");
const syntax = @import("syntax.zig");

/// Welcome screen — modern, clean layout inspired by VSCode/Cursor.
/// Shows forge logo, tagline, quick actions, recent workspaces, and
/// keyboard shortcuts.
pub fn draw(wb: *Workbench, editor_x: f32, editor_w: f32, editor_h: f32) void {
    const theme = &wb.theme;
    const bg = syntax.color(theme.colors.editor_bg);
    const text = syntax.color(theme.colors.text_primary);
    const muted = syntax.color(theme.colors.text_muted);
    const secondary = syntax.color(theme.colors.text_secondary);
    const accent = syntax.color(theme.colors.accent);
    const accent_soft = syntax.color(theme.colors.accent_soft);
    const border = syntax.color(theme.colors.border);
    const row_bg = syntax.color(theme.colors.tab_bar_bg);
    const card_bg = syntax.color(theme.colors.agent_bg);

    // Full background
    renderer.Renderer.drawRect(editor_x, editor_scroll.content_top, editor_w, editor_h - editor_scroll.content_top, bg);

    // Centered content column
    const content_w: f32 = @min(820, @max(320, editor_w - 120));
    const content_x = editor_x + @max(48, (editor_w - content_w) * 0.5);
    var y = editor_scroll.content_top + 64;

    // Logo accent bar (gradient-like with 3 stacked rects)
    const logo_x = content_x;
    renderer.Renderer.drawRoundedRect(logo_x, y, 4, 44, 2, accent);
    renderer.Renderer.drawRoundedRect(logo_x + 6, y + 4, 3, 36, 1.5, accent_soft);

    // Forge title
    drawText("Forge", logo_x + 22, y + 2, 38, text);
    y += 48;
    drawText("AI-first native IDE", logo_x + 24, y, 15, accent);
    y += 32;

    // Subtle divider
    renderer.Renderer.drawRect(content_x, y, content_w, 1, border);
    y += 28;

    // Two-column layout: Start (left) + Shortcuts (right)
    const col_gap: f32 = 32;
    const col_w: f32 = (content_w - col_gap) * 0.5;
    const left_x = content_x;
    const right_x = content_x + col_w + col_gap;

    // Left column: Start
    drawText("Start", left_x, y, 11, muted);
    y += 22;

    drawAction(left_x, y, col_w, renderer.icons.file_directory, "Open folder", "forge .", accent, row_bg, border, text, secondary);
    y += 46;
    drawAction(left_x, y, col_w, renderer.icons.file, "Open file", "forge /path/to/file", accent, row_bg, border, text, secondary);
    y += 46;
    drawAction(left_x, y, col_w, renderer.icons.terminal, "Clone repo", "git clone <url> && forge <dir>", accent, row_bg, border, text, secondary);
    y += 64;

    // Recent
    drawText("Recent", left_x, y, 11, muted);
    y += 22;
    if (wb.recent_workspace_paths.len == 0) {
        drawText("No recent workspaces yet", left_x, y, 13, muted);
    } else {
        const count = @min(wb.recent_workspace_paths.len, 4);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const path = wb.recent_workspace_paths[i];
            const name = std.fs.path.basename(path);
            drawRecent(left_x, y, col_w, name, path, accent, row_bg, border, text, muted);
            y += 42;
        }
    }

    // Right column: Walkthrough / Shortcuts
    var ry = editor_scroll.content_top + 64 + 48 + 32 + 28;

    drawText("Walkthrough", right_x, ry, 11, muted);
    ry += 22;

    // Walkthrough card
    renderer.Renderer.drawRoundedRect(right_x, ry, col_w, 140, 8, card_bg);
    renderer.Renderer.drawRect(right_x, ry, col_w, 1, border);
    renderer.Renderer.drawRoundedRect(right_x, ry, 4, 140, 2, accent);

    drawText("Get started with Forge", right_x + 16, ry + 14, 15, text);
    ry += 38;
    drawText("• Open a project folder to start editing", right_x + 16, ry, 13, secondary);
    ry += 20;
    drawText("• Press Cmd+P for the command palette", right_x + 16, ry, 13, secondary);
    ry += 20;
    drawText("• Press Cmd+Shift+A to open the AI agent", right_x + 16, ry, 13, secondary);
    ry += 20;
    drawText("• Use forge chat for CLI AI workflow", right_x + 16, ry, 13, secondary);
    ry += 28;

    // Keyboard shortcuts
    drawText("Keyboard shortcuts", right_x, ry, 11, muted);
    ry += 22;

    drawShortcut(right_x, ry, col_w, "Command palette", "Cmd+P", card_bg, border, text, muted);
    ry += 30;
    drawShortcut(right_x, ry, col_w, "Toggle AI agent", "Cmd+Shift+A", card_bg, border, text, muted);
    ry += 30;
    drawShortcut(right_x, ry, col_w, "Inline edit (Composer)", "Cmd+K", card_bg, border, text, muted);
    ry += 30;
    drawShortcut(right_x, ry, col_w, "Accept ghost completion", "Tab", card_bg, border, text, muted);
    ry += 30;
    drawShortcut(right_x, ry, col_w, "Toggle terminal", "Cmd+J", card_bg, border, text, muted);
    ry += 30;
    drawShortcut(right_x, ry, col_w, "Search files", "Cmd+Shift+F", card_bg, border, text, muted);
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
    secondary: renderer.Color,
) void {
    renderer.Renderer.drawRoundedRect(x, y, w, 40, 6, bg);
    renderer.Renderer.drawRect(x, y + 39, w, 1, border);
    renderer.Renderer.drawSvg(icon, x + 12, y + 11, 18, 18, accent);
    drawText(title, x + 42, y + 9, 14, text);
    drawText(command, x + w - @min(220, w * 0.42), y + 10, 12, secondary);
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
    renderer.Renderer.drawRoundedRect(x, y, w, 38, 6, bg);
    renderer.Renderer.drawRect(x, y + 37, w, 1, border);
    renderer.Renderer.drawSvg(renderer.icons.repo, x + 12, y + 10, 17, 17, accent);
    drawText(name, x + 42, y + 8, 13, text);
    drawText(path, x + @min(240, w * 0.42), y + 9, 12, muted);
}

fn drawShortcut(
    x: f32,
    y: f32,
    w: f32,
    label: []const u8,
    key: []const u8,
    bg: renderer.Color,
    border: renderer.Color,
    text: renderer.Color,
    muted: renderer.Color,
) void {
    drawText(label, x, y + 4, 13, text);
    // Right-aligned key badge
    const key_w: f32 = @min(110, w * 0.32);
    const key_x = x + w - key_w;
    renderer.Renderer.drawRoundedRect(key_x, y, key_w, 22, 4, bg);
    renderer.Renderer.drawRect(key_x, y, key_w, 1, border);
    drawText(key, key_x + 8, y + 4, 11, muted);
}

fn drawText(text: []const u8, x: f32, y: f32, size: f32, color: renderer.Color) void {
    var buf: [256:0]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    renderer.Renderer.drawText(@ptrCast(&buf), x, y, size, color);
}

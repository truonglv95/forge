//! Editor minimap — scaled-down overview of the file content.
//!
//! Shows a zoomed-out representation of the file on the right side of
//! the editor, with a viewport indicator showing the currently visible
//! region. Click to scroll, drag to pan.
//!
//! Inspired by VSCode/Sublime Text minimaps.

const std = @import("std");
const renderer = @import("forge-renderer");
const Workbench = @import("../../workbench.zig").Workbench;
const theme_mod = @import("../render/theme.zig");
const editor_scroll = @import("editor_scroll.zig");
const tokens = @import("../tokens.zig");

pub const minimap_width: f32 = 80;
pub const minimap_line_height: f32 = 2.5;
pub const viewport_indicator_alpha: f32 = 0.2;

/// Simple keyword set for minimap syntax colouring. Mirrors the
/// keyword list in chat_markdown.zig — kept short to avoid perf hit
/// at the minimap's tiny scale.
const minimap_keywords = [_][]const u8{
    "pub",  "fn",     "const",  "var",   "let",   "function", "class",    "import",
    "from", "export", "struct", "enum",  "union", "return",   "try",      "catch",
    "if",   "else",   "switch", "while", "for",   "break",    "continue", "defer",
};

fn isMinimapKeyword(word: []const u8) bool {
    for (minimap_keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Classify a word for minimap colouring. Returns a tinted colour
/// based on the word's role (keyword/type/function/identifier).
/// Colours are desaturated to ~30% of the editor's syntax palette —
/// minimap should read as a soft overview, not a neon copy of the
/// editor (per VLM review: was too vibrant/noisy at full saturation).
fn classifyWord(word: []const u8, base: renderer.Color) renderer.Color {
    if (word.len == 0) return base;
    if (isMinimapKeyword(word)) {
        // Muted purple — 30% of syntax_keyword brightness.
        return .{ .r = tokens.color.syntax_keyword.r * 0.3, .g = tokens.color.syntax_keyword.g * 0.3, .b = tokens.color.syntax_keyword.b * 0.3, .a = 0.6 };
    }
    if (word[0] >= 'A' and word[0] <= 'Z') {
        // Muted cyan for types.
        return .{ .r = tokens.color.syntax_type.r * 0.3, .g = tokens.color.syntax_type.g * 0.3, .b = tokens.color.syntax_type.b * 0.3, .a = 0.6 };
    }
    return base;
}

/// Draw the minimap on the right side of the editor.
/// `editor_x` is the left edge of the editor area, `editor_w` is its width.
pub fn drawMinimap(wb: *Workbench, editor_x: f32, editor_w: f32, editor_h: f32) void {
    const doc = wb.editor.tabs.activeDoc() orelse return;

    const theme = &wb.theme;
    const bg = theme_mod.color(theme.colors.tab_bar_bg);
    const fg = theme_mod.color(theme.colors.text_muted);
    const accent = theme_mod.color(theme.colors.accent);
    const viewport_bg = theme_mod.color(theme.colors.accent_soft);

    // Minimap is positioned to the LEFT of the scrollbar. The scrollbar
    // occupies the rightmost ~10px (track_w + content_gap) of editor_w,
    // and the scrollbar gutter is reserved OUTSIDE the editor's content
    // clip rect (see viewport.zig). The minimap sits between the editor
    // text area and the scrollbar gutter.
    const scrollbar = @import("../core/scrollbar.zig");
    const scrollbar_reserve: f32 = scrollbar.track_w + scrollbar.content_gap;
    const minimap_x = editor_x + editor_w - minimap_width - scrollbar_reserve;
    const minimap_y = editor_scroll.content_top;
    const minimap_h = editor_h - editor_scroll.content_top;

    // Background
    renderer.Renderer.drawRect(minimap_x, minimap_y, minimap_width, minimap_h, bg);

    // Draw scaled-down representation of lines.
    // Each line becomes a thin horizontal strip; characters become colored
    // segments based on syntax classification.
    const lines = doc.buffer.lines.items;
    const total_lines = lines.len;

    // How many minimap lines fit in the visible area.
    const visible_minimap_lines = @as(usize, @intFromFloat(minimap_h / minimap_line_height));

    // Which source lines are visible (based on scroll offset).
    const scroll_offset = wb.editor_scroll_y;
    const line_height_px = editor_scroll.lineHeight(theme);
    const first_visible_line: usize = @intFromFloat(@max(0, scroll_offset / line_height_px));
    const line_offset = if (total_lines > visible_minimap_lines) first_visible_line else 0;

    var y = minimap_y;
    var i: usize = line_offset;
    const max_iter = @min(total_lines, line_offset + visible_minimap_lines + 5);
    while (i < max_iter and y < minimap_y + minimap_h) : (i += 1) {
        const line = lines[i].items;
        if (line.len == 0) {
            y += minimap_line_height;
            continue;
        }

        // Draw a thin strip for each line. Density based on character count.
        // Max ~80 chars represented; longer lines get brighter color.
        const char_count = @min(line.len, 80);
        const density: f32 = @as(f32, @floatFromInt(char_count)) / 80.0;

        // Draw colored segments for non-whitespace characters.
        // Each word gets a tinted colour based on syntax classification
        // (keyword=purple, type=cyan, identifier=fg). This makes the
        // minimap visually echo the editor's syntax highlighting.
        var col: usize = 0;
        const char_width: f32 = (minimap_width - 6) / 80.0;
        while (col < char_count) {
            // Skip whitespace
            if (std.ascii.isWhitespace(line[col])) {
                col += 1;
                continue;
            }
            // Find end of word
            var word_end = col;
            while (word_end < char_count and !std.ascii.isWhitespace(line[word_end])) : (word_end += 1) {}

            // Draw word segment with syntax-coloured tint
            const word_len = word_end - col;
            const seg_x = minimap_x + 3 + @as(f32, @floatFromInt(col)) * char_width;
            const seg_w = @as(f32, @floatFromInt(word_len)) * char_width;
            const word = line[col..word_end];
            const base_color: renderer.Color = .{
                .r = fg.r * (0.4 + density * 0.6),
                .g = fg.g * (0.4 + density * 0.6),
                .b = fg.b * (0.4 + density * 0.6),
                .a = 0.7,
            };
            const seg_color = classifyWord(word, base_color);
            renderer.Renderer.drawRect(seg_x, y, seg_w, minimap_line_height - 0.5, seg_color);

            col = word_end;
        }

        y += minimap_line_height;
    }

    // Viewport indicator — shows which portion of the file is visible.
    if (total_lines > visible_minimap_lines) {
        const viewport_h = @as(f32, @floatFromInt(visible_minimap_lines)) * minimap_line_height;
        const viewport_y = minimap_y + @as(f32, @floatFromInt(first_visible_line)) * minimap_line_height;
        const viewport_overlay: renderer.Color = .{
            .r = viewport_bg.r,
            .g = viewport_bg.g,
            .b = viewport_bg.b,
            .a = viewport_indicator_alpha,
        };
        renderer.Renderer.drawRect(minimap_x, viewport_y, minimap_width, viewport_h, viewport_overlay);
        // Accent border on left of viewport
        renderer.Renderer.drawRect(minimap_x, viewport_y, 2, viewport_h, accent);
    }

    // Separator border on left
    renderer.Renderer.drawRect(minimap_x - 1, minimap_y, 1, minimap_h, theme_mod.color(theme.colors.border));
}

/// Check if a click position is within the minimap area.
pub fn isMinimapClick(editor_x: f32, editor_w: f32, click_x: f32, click_y: f32, editor_h: f32) bool {
    const scrollbar = @import("../core/scrollbar.zig");
    const scrollbar_reserve: f32 = scrollbar.track_w + scrollbar.content_gap;
    const minimap_x = editor_x + editor_w - minimap_width - scrollbar_reserve;
    return click_x >= minimap_x and click_x <= minimap_x + minimap_width and
        click_y >= editor_scroll.content_top and click_y <= editor_h;
}

/// Convert a click Y position in the minimap to a scroll offset.
pub fn minimapClickToScroll(click_y: f32, total_lines: usize, visible_lines: usize) f32 {
    if (total_lines <= visible_lines) return 0;
    const minimap_h = @as(f32, @floatFromInt(total_lines)) * minimap_line_height;
    const visible_h = @as(f32, @floatFromInt(visible_lines)) * minimap_line_height;
    const scrollable_h = minimap_h - visible_h;
    if (scrollable_h <= 0) return 0;
    const ratio = std.math.clamp(click_y / scrollable_h, 0, 1);
    return ratio * @as(f32, @floatFromInt(total_lines - visible_lines));
}

test "isMinimapClick detects clicks in minimap area" {
    try std.testing.expect(isMinimapClick(0, 800, 730, 100, 600));
    try std.testing.expect(!isMinimapClick(0, 800, 100, 100, 600));
}

test "minimapClickToScroll returns 0 for small files" {
    try std.testing.expectEqual(@as(f32, 0), minimapClickToScroll(50, 10, 20));
}

test "minimapClickToScroll returns ratio for large files" {
    const scroll = minimapClickToScroll(100, 1000, 100);
    try std.testing.expect(scroll > 0);
}

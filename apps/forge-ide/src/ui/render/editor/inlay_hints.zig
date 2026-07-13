//! Inlay hints rendering — draws faint inline text (parameter names,
//! inferred types) at positions returned by the LSP.
//!
//! Rendered as small grey text overlays at the position the LSP returned,
//! slightly offset from the actual code so the user can distinguish code
//! from inferred annotation.

const std = @import("std");
const renderer = @import("forge-renderer");
const editor_scroll = @import("../../editor/editor_scroll.zig");
const theme_mod = @import("../theme.zig");
const inlay_hints_store = @import("../../../workbench/inlay_hints_store.zig");

/// Draw inlay hints for a single line. `hints` is the full hints array
/// for this file; we filter to those on `line_idx`.
pub fn drawLineHints(
    hints: ?[]const inlay_hints_store.Hint,
    line_idx: usize,
    line_text: []const u8,
    text_x: f32,
    line_y: f32,
    font_size: f32,
    theme: *const @import("forge-workspace").Theme,
) void {
    _ = line_text;
    const hs = hints orelse return;
    if (hs.len == 0) return;

    // Color for inlay hints — use a muted grey slightly brighter than
    // line numbers, with italic feel (we don't have italic in the
    // renderer so we just use a desaturated color).
    const c = theme_mod.color(theme.colors.text_muted);

    for (hs) |h| {
        if (h.line != line_idx) continue;

        // Compute the x position based on the character column.
        // We use the same monospace char width as the editor.
        const char_w = theme.charWidth();
        const col_f: f32 = @floatFromInt(h.character);
        const hint_x = text_x + col_f * char_w;

        // Draw the hint text. For type hints we draw after the column
        // (e.g. `x: i32` where `: i32` is the hint). For parameter hints
        // we draw before (e.g. `name:` before the argument value).
        switch (h.kind) {
            1 => {
                // Type hint — draw at the column (after the variable).
                renderer.Renderer.drawText(h.label, hint_x, line_y, font_size, c);
            },
            2 => {
                // Parameter hint — draw slightly before the column.
                const label_w = @as(f32, @floatFromInt(h.label.len)) * char_w;
                renderer.Renderer.drawText(h.label, hint_x - label_w, line_y, font_size, c);
            },
            else => {
                renderer.Renderer.drawText(h.label, hint_x, line_y, font_size, c);
            },
        }
    }
}

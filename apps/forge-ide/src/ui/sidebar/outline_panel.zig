//! Symbol outline panel — shows a flat tree of LSP document symbols for
//! the active file. Clicking a symbol jumps to its definition.
//!
//! Renders in the sidebar when `SidebarView.outline` is selected. The
//! panel fetches symbols on file activation / buffer change (debounced
//! via the existing lsp_sync tick), and stores them in
//! `Workbench.outline_symbols`.

const std = @import("std");
const renderer = @import("forge-renderer");
const lsp = @import("forge-lsp");
const theme_mod = @import("../render/theme.zig");
const layout = @import("../core/layout.zig");
const panel_scroll = @import("../core/panel_scroll.zig");
const editor_scroll = @import("../editor/editor_scroll.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub const list_top: f32 = layout.header_height + 32;
pub const row_h: f32 = 22;
pub const indent_w: f32 = 14;

pub const Hit = union(enum) {
    none,
    select_symbol: usize,
};

/// Returns the screen-space rectangle for a row.
pub fn rowRect(panel_x: f32, panel_w: f32, index: usize, scroll_y: f32) struct { x: f32, y: f32, w: f32, h: f32 } {
    const y = list_top + @as(f32, @floatFromInt(index)) * row_h - scroll_y;
    return .{
        .x = panel_x,
        .y = y,
        .w = panel_w,
        .h = row_h,
    };
}

/// Hit-test a click in the outline panel.
pub fn hitTest(panel_x: f32, panel_w: f32, y: f32, scroll_y: f32, item_count: usize) ?usize {
    _ = panel_w;
    if (y < list_top) return null;
    const rel_y = y - list_top + scroll_y;
    if (rel_y < 0) return null;
    const idx = @as(usize, @intFromFloat(rel_y / row_h));
    if (idx >= item_count) return null;
    if (panel_x < 0) return null;
    return idx;
}

/// Draw the outline panel. Reads from `wb.lsp.outline_symbols`.
pub fn drawOutline(wb: *Workbench, panel_x: f32, panel_w: f32, panel_h: f32) void {
    const theme = &wb.theme;
    const font_size = theme.ui_font_size;

    // Background.
    renderer.Renderer.drawRect(panel_x, layout.header_height, panel_w, panel_h - layout.header_height, theme_mod.color(theme.colors.sidebar_bg));

    // Header.
    renderer.Renderer.drawText("OUTLINE", panel_x + 16, layout.header_height + 8, 11.0, theme_mod.color(theme.colors.text_muted));

    // Empty state.
    if (wb.lsp.outline_symbols.len == 0) {
        const active_path = wb.activeFilePath() orelse {
            renderer.Renderer.drawText("No file open", panel_x + 16, list_top + 8, font_size, theme_mod.color(theme.colors.text_muted));
            return;
        };
        _ = active_path;
        renderer.Renderer.drawText("No symbols available", panel_x + 16, list_top + 8, font_size, theme_mod.color(theme.colors.text_muted));
        renderer.Renderer.drawText("(open a file with LSP)", panel_x + 16, list_top + 24, 11.0, theme_mod.color(theme.colors.text_muted));
        return;
    }

    // Set clip rect so symbols don't overflow into editor.
    renderer.Renderer.setClipRect(panel_x, list_top, panel_w, panel_h - list_top - layout.status_height);

    const scroll_y = wb.lsp.outline_scroll_y;
    const max_visible = @as(usize, @intFromFloat(@floor((panel_h - list_top - layout.status_height) / row_h)));

    for (wb.lsp.outline_symbols, 0..) |sym, i| {
        const y = list_top + @as(f32, @floatFromInt(i)) * row_h - scroll_y;
        if (y + row_h < list_top) continue;
        if (y > panel_h) break;
        if (i > max_visible + 100) break; // safety cap

        const indent: f32 = @as(f32, @floatFromInt(sym.depth)) * indent_w;
        const x = panel_x + 16 + indent;

        // Hover highlight.
        const is_hover = (i == wb.lsp.outline_hover_index);
        if (is_hover) {
            renderer.Renderer.drawRect(panel_x, y, panel_w, row_h, .{ .r = 0.18, .g = 0.20, .b = 0.24, .a = 1.0 });
        }

        // Symbol glyph (kind indicator).
        const glyph_color = switch (sym.kind) {
            .Class, .Struct, .Interface => theme_mod.color(theme.colors.type),
            .Function, .Method, .Constructor => theme_mod.color(theme.colors.function),
            .Property, .Field => theme_mod.color(theme.colors.property),
            .Enum, .EnumMember => theme_mod.color(theme.colors.type),
            .Constant, .Variable => theme_mod.color(theme.colors.variable),
            else => theme_mod.color(theme.colors.text_secondary),
        };
        const glyph = sym.glyph();
        renderer.Renderer.drawText(glyph, x, y + 4, font_size, glyph_color);

        // Symbol name.
        const name_x = x + 18;
        renderer.Renderer.drawText(sym.name, name_x, y + 4, font_size, theme_mod.color(theme.colors.text_primary));

        // Optional detail (signature).
        if (sym.detail) |detail| {
            const name_w = editor_scroll.cursorX(sym.name, 0, font_size);
            const detail_color = theme_mod.color(theme.colors.text_muted);
            // Truncate detail if it would overflow.
            const max_detail_w = panel_w - (name_x - panel_x) - name_w - 8;
            if (max_detail_w > 30) {
                var visible_len: usize = 0;
                var visible_w: f32 = 0;
                while (visible_len < detail.len) : (visible_len += 1) {
                    const ch_w = editor_scroll.charWidth(theme);
                    visible_w += ch_w;
                    if (visible_w > max_detail_w) break;
                }
                if (visible_len > 0) {
                    renderer.Renderer.drawText(detail[0..@min(visible_len, detail.len)], name_x + name_w, y + 4, font_size, detail_color);
                }
            }
        }
    }

    renderer.Renderer.clearClipRect();

    // Scrollbar.
    const total_h = @as(f32, @floatFromInt(wb.lsp.outline_symbols.len)) * row_h;
    const view_h = panel_h - list_top - layout.status_height;
    if (total_h > view_h) {
        const scrollbar = @import("../core/scrollbar.zig");
        scrollbar.drawVertical(
            panel_x + panel_w - scrollbar.track_w - 4,
            list_top,
            view_h,
            scroll_y,
            total_h - view_h,
            total_h,
            view_h,
            true,
        );
    }
}

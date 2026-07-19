//! Breadcrumbs — file path + symbol breadcrumbs at the top of the editor.
//!
//! Shows the file path (relative to workspace) followed by the chain
//! of containers/symbols containing the cursor. Clicking a breadcrumb
//! jumps to that location.
//!
//! Example: `src/main.zig › main › Buffer › insertString`

const std = @import("std");
const renderer = @import("forge-renderer");
const lsp = @import("forge-lsp");
const theme_mod = @import("../theme.zig");
const editor_scroll = @import("../../editor/editor_scroll.zig");
const tabs_ui = @import("../../editor/tabs.zig");
const Workbench = @import("../../../workbench.zig").Workbench;

pub const height: f32 = 22;
pub const separator: []const u8 = " › ";

/// Returns the symbols that contain the cursor at (row, col), sorted
/// outermost-to-innermost.
pub fn breadcrumbsForCursor(
    allocator: std.mem.Allocator,
    symbols: []const lsp.document_symbol.Symbol,
    row: u32,
    col: u32,
) ![]const lsp.document_symbol.Symbol {
    var matches: std.ArrayList(lsp.document_symbol.Symbol) = .empty;
    errdefer matches.deinit(allocator);

    for (symbols) |sym| {
        // Symbol contains cursor if cursor is in [start, end] range.
        if (row < sym.line or row > sym.end_line) continue;
        if (sym.depth == 0 and !sym.isContainer()) continue; // top-level leaves don't contain
        // For same-line containment, check column.
        if (row == sym.line and col < sym.character) continue;
        if (row == sym.end_line and col > sym.end_character) continue;
        try matches.append(allocator, sym);
    }

    // Sort by depth ascending (outermost first), then by line.
    std.sort.block(lsp.document_symbol.Symbol, matches.items, {}, struct {
        fn less(_: void, a: lsp.document_symbol.Symbol, b: lsp.document_symbol.Symbol) bool {
            if (a.depth != b.depth) return a.depth < b.depth;
            return a.line < b.line;
        }
    }.less);

    return matches.toOwnedSlice(allocator);
}

/// Draw breadcrumbs at the top of the editor.
pub fn drawBreadcrumbs(
    wb: *Workbench,
    editor_x: f32,
    editor_w: f32,
    file_path: []const u8,
) void {
    const theme = &wb.theme;
    const font_size = 11.0;
    const y: f32 = tabs_ui.tab_bar_top + tabs_ui.tab_bar_height;

    // Background strip.
    renderer.Renderer.drawRect(editor_x, y, editor_w, height, theme_mod.color(theme.colors.tab_bar_bg));

    // Get the cursor position.
    const buf = wb.activeBuffer() orelse return;
    const row: u32 = @intCast(buf.cursor.row);
    const col: u32 = @intCast(buf.cursor.col);

    // Compute breadcrumb path.
    const symbols = wb.lsp.outline_symbols;
    const crumbs = breadcrumbsForCursor(wb.allocator, symbols, row, col) catch return;
    defer wb.allocator.free(crumbs);

    // Draw file basename first.
    const basename = std.fs.path.basename(file_path);
    var x = editor_x + 8;
    renderer.Renderer.drawText(basename, x, y + 4, font_size, theme_mod.color(theme.colors.text_secondary));
    x += editor_scroll.cursorX(basename, 0, font_size) + 6;

    // Draw separator + symbol names.
    for (crumbs) |sym| {
        // Separator.
        renderer.Renderer.drawText(separator, x, y + 4, font_size, theme_mod.color(theme.colors.text_muted));
        x += editor_scroll.cursorX(separator, 0, font_size);

        // Symbol name with kind-based color.
        const color = switch (sym.kind) {
            .Class, .Struct, .Interface => theme_mod.color(theme.colors.type),
            .Function, .Method, .Constructor => theme_mod.color(theme.colors.function),
            .Property, .Field => theme_mod.color(theme.colors.property),
            .Enum, .EnumMember => theme_mod.color(theme.colors.type),
            else => theme_mod.color(theme.colors.text_primary),
        };
        renderer.Renderer.drawText(sym.name, x, y + 4, font_size, color);
        x += editor_scroll.cursorX(sym.name, 0, font_size) + 4;

        // Stop if we run out of space.
        if (x > editor_x + editor_w - 50) break;
    }
}

/// Hit-test a click on breadcrumbs. Returns the index of the clicked
/// crumb (0 = file, 1..N = symbols), or null if the click missed.
pub fn hitTest(
    wb: *Workbench,
    editor_x: f32,
    editor_w: f32,
    file_path: []const u8,
    click_x: f32,
    click_y: f32,
) ?usize {
    const y: f32 = tabs_ui.tab_bar_top + tabs_ui.tab_bar_height;
    if (click_y < y or click_y > y + height) return null;
    if (click_x < editor_x or click_x > editor_x + editor_w) return null;

    const buf = wb.activeBuffer() orelse return null;
    const row: u32 = @intCast(buf.cursor.row);
    const col: u32 = @intCast(buf.cursor.col);

    const symbols = wb.lsp.outline_symbols;
    const crumbs = breadcrumbsForCursor(wb.allocator, symbols, row, col) catch return null;
    defer wb.allocator.free(crumbs);

    var x = editor_x + 8;
    const basename = std.fs.path.basename(file_path);
    const font_size = 11.0;

    // File crumb.
    const basename_w = editor_scroll.cursorX(basename, 0, font_size);
    if (click_x >= x and click_x <= x + basename_w) return 0;
    x += basename_w + 6;

    for (crumbs, 0..) |sym, i| {
        const sep_w = editor_scroll.cursorX(separator, 0, font_size);
        x += sep_w;
        const name_w = editor_scroll.cursorX(sym.name, 0, font_size);
        if (click_x >= x and click_x <= x + name_w) return i + 1;
        x += name_w + 4;
    }
    return null;
}

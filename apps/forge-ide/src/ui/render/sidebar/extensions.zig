const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const extensions_panel = @import("../../sidebar/extensions_panel.zig");
const plugin = @import("forge-plugin");
const agent_scope_picker_mod = @import("../../../agent/scope_picker.zig");
const scroll_region = @import("../../core/scroll_region.zig");
const scrollbar = @import("../../core/scrollbar.zig");

const ui_text_style = renderer.TextStyle.prose;
const ui_strong_style = renderer.TextStyle.prose_semibold;

fn drawUiText(text: []const u8, x: f32, y: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.drawTextWithStyle(text, x, @round(y), size, c, ui_text_style);
}

fn drawStrongText(text: []const u8, x: f32, y: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.drawTextWithStyle(text, x, @round(y), size, c, ui_strong_style);
}

fn drawClippedText(text: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, color: renderer.Color, strong: bool) void {
    renderer.Renderer.pushClipRect(x, y - 2, @max(0, w), h);
    if (strong) {
        drawStrongText(text, x, y, size, color);
    } else {
        drawUiText(text, x, y, size, color);
    }
    renderer.Renderer.popClipRect();
}

fn copyZ(dst: []u8, src: []const u8) [:0]const u8 {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
    return @ptrCast(dst[0..n :0]);
}

fn installedMatches(filter: []const u8, ext: *const plugin.LoadedExtension) bool {
    if (filter.len == 0) return true;
    return agent_scope_picker_mod.matchesQuery(filter, ext.name) or
        agent_scope_picker_mod.matchesQuery(filter, ext.id) or
        agent_scope_picker_mod.matchesQuery(filter, ext.version);
}

fn marketplaceMatches(filter: []const u8, entry: *const plugin.MarketplaceEntry) bool {
    if (filter.len == 0) return true;
    return agent_scope_picker_mod.matchesQuery(filter, entry.name) or
        agent_scope_picker_mod.matchesQuery(filter, entry.id) or
        agent_scope_picker_mod.matchesQuery(filter, entry.description) or
        agent_scope_picker_mod.matchesQuery(filter, entry.publisher);
}

fn installedCount(host: *const plugin.Host, filter: []const u8) usize {
    var count: usize = 0;
    for (host.extensions.items) |*ext| {
        if (installedMatches(filter, ext)) count += 1;
    }
    return count;
}

fn marketplaceCount(catalog: ?*const plugin.MarketplaceCatalog, filter: []const u8) usize {
    const catalog_ptr = catalog orelse return 0;
    var count: usize = 0;
    for (catalog_ptr.entries) |*entry| {
        if (marketplaceMatches(filter, entry)) count += 1;
    }
    return count;
}

fn drawButton(label: []const u8, x: f32, y: f32, w: f32, h: f32, active: bool, theme: anytype) void {
    const bg = if (active)
        shared.color(theme.colors.accent_soft)
    else
        renderer.Color{ .r = 0.18, .g = 0.19, .b = 0.22, .a = 1.0 };
    const fg = if (active)
        renderer.Color{ .r = 0.92, .g = 0.94, .b = 0.98, .a = 1.0 }
    else
        renderer.Color{ .r = 0.74, .g = 0.75, .b = 0.78, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(x, y, w, h, 5, bg);
    drawClippedText(label, x + 10, y + 7, w - 20, h - 8, 11.5, fg, active);
}

fn drawSectionHeader(label: []const u8, count: usize, x: f32, y: f32, w: f32) void {
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, x + 8, y + 2, 16, 16, .{ .r = 0.68, .g = 0.69, .b = 0.72, .a = 1.0 });
    drawStrongText(label, x + 28, y + 3, 11.5, .{ .r = 0.78, .g = 0.79, .b = 0.82, .a = 1.0 });
    var count_buf: [24]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch "";
    const badge_w = @max(24, renderer.Renderer.measureTextWithStyle(count_text, 10.5, ui_strong_style) + 12);
    renderer.Renderer.drawRoundedRect(x + w - badge_w - 12, y, badge_w, 22, 11, .{ .r = 0.34, .g = 0.34, .b = 0.36, .a = 1.0 });
    drawStrongText(count_text, x + w - badge_w - 6, y + 5, 10.5, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
}

fn drawExtensionAvatar(ext_id: []const u8, x: f32, y: f32, size: f32) void {
    var hash: u32 = 2166136261;
    for (ext_id) |ch| hash = (hash ^ ch) *% 16777619;
    const r = 0.18 + @as(f32, @floatFromInt(hash & 0xff)) / 255.0 * 0.42;
    const g = 0.22 + @as(f32, @floatFromInt((hash >> 8) & 0xff)) / 255.0 * 0.42;
    const b = 0.28 + @as(f32, @floatFromInt((hash >> 16) & 0xff)) / 255.0 * 0.42;
    renderer.Renderer.drawRoundedRect(x, y, size, size, 6, .{ .r = r, .g = g, .b = b, .a = 1.0 });
    var initials: [3]u8 = .{ 'E', 0, 0 };
    if (ext_id.len > 0) initials[0] = std.ascii.toUpper(ext_id[0]);
    drawStrongText(@ptrCast(initials[0..1 :0]), x + size * 0.34, y + size * 0.29, 14.0, .{ .r = 0.96, .g = 0.97, .b = 0.99, .a = 1.0 });
}

fn drawInstalledRow(wb: *Workbench, ext: *const plugin.LoadedExtension, index: usize, x: f32, y: f32, w: f32, h: f32) void {
    const selected = wb.selected_extension_index == index;
    if (selected) {
        renderer.Renderer.drawRoundedRect(x + 6, y, w - 12, h - 6, 5, shared.color(wb.theme.colors.selection));
    }

    drawExtensionAvatar(ext.id, x + 14, y + 10, 42);
    const text_x = x + 68;
    const right_pad: f32 = 36;
    const text_w = @max(0, w - 82 - right_pad);
    drawClippedText(ext.name, text_x, y + 8, text_w, 18, 13.0, .{ .r = 0.88, .g = 0.89, .b = 0.92, .a = 1.0 }, true);

    const status = if (ext.active) "Active" else "Disabled";
    var meta_buf: [192]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{s}  v{s}", .{ status, ext.version }) catch status;
    drawClippedText(meta, text_x, y + 28, text_w, 16, 10.5, .{ .r = 0.6, .g = 0.61, .b = 0.66, .a = 1.0 }, false);

    const path_label = if (std.mem.eql(u8, ext.root_path, "(builtin)")) "(built-in)" else ext.root_path;
    drawClippedText(path_label, text_x, y + 45, text_w, 16, 10.0, .{ .r = 0.5, .g = 0.58, .b = 0.66, .a = 1.0 }, false);

    renderer.Renderer.drawSvg(renderer.icons.gear, x + w - 30, y + 24, 16, 16, .{ .r = 0.66, .g = 0.67, .b = 0.7, .a = 1.0 });

    var cmd_y = y + extensions_panel.header_h + 8;
    for (ext.commands.items) |cmd| {
        if (cmd_y + extensions_panel.cmd_row_h > y + h - 26) break;
        var cmd_buf: [160]u8 = undefined;
        const cmd_line = std.fmt.bufPrint(&cmd_buf, "> {s}", .{cmd.title}) catch cmd.title;
        drawClippedText(cmd_line, text_x, cmd_y, text_w, 15, 10.5, .{ .r = 0.76, .g = 0.77, .b = 0.8, .a = 1.0 }, false);
        cmd_y += extensions_panel.cmd_row_h;
    }

    if (@import("../../../workbench/extensions_ops.zig").canUninstallExtension(wb, ext)) {
        drawUiText("Uninstall", text_x, y + h - 25, 10.5, .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 });
    }
}

fn drawMarketplaceRow(entry: *const plugin.MarketplaceEntry, x: f32, y: f32, w: f32, h: f32, theme: anytype) void {
    renderer.Renderer.drawRoundedRect(x + 6, y, w - 12, h - 6, 5, shared.color(theme.colors.selection));
    drawExtensionAvatar(entry.id, x + 14, y + 10, 42);

    const text_x = x + 68;
    const text_w = @max(0, w - 158);
    drawClippedText(entry.name, text_x, y + 7, text_w, 18, 13.0, .{ .r = 0.88, .g = 0.89, .b = 0.92, .a = 1.0 }, true);
    drawClippedText(entry.description, text_x, y + 27, text_w, 16, 10.5, .{ .r = 0.63, .g = 0.64, .b = 0.68, .a = 1.0 }, false);
    drawClippedText(entry.publisher, text_x, y + 45, text_w, 16, 10.5, .{ .r = 0.7, .g = 0.71, .b = 0.74, .a = 1.0 }, true);

    renderer.Renderer.drawRoundedRect(x + w - 76, y + h - 31, 58, 22, 5, shared.color(theme.colors.accent));
    drawStrongText("Install", x + w - 64, y + h - 26, 10.5, .{ .r = 0.97, .g = 0.98, .b = 1.0, .a = 1.0 });
    drawUiText("Details", x + w - 76, y + 11, 10.0, .{ .r = 0.6, .g = 0.72, .b = 0.9, .a = 1.0 });
}

fn drawMarketplaceRows(
    catalog: *const plugin.MarketplaceCatalog,
    filter: []const u8,
    panel_x: f32,
    panel_w: f32,
    y_start: f32,
    viewport_h: f32,
    scroll_y: f32,
    theme: anytype,
) f32 {
    var y = y_start;
    const row_h = extensions_panel.marketplace_row_h;
    if (filter.len == 0) {
        const region = scroll_region.region(@as(f32, @floatFromInt(catalog.entries.len)) * row_h, viewport_h);
        const range = region.visibleRange(@max(0, scroll_y - extensions_panel.footer_h - extensions_panel.section_h), row_h, catalog.entries.len);
        y += @as(f32, @floatFromInt(range.first)) * row_h;
        for (catalog.entries[range.first..range.last]) |*entry| {
            drawMarketplaceRow(entry, panel_x, y, panel_w, row_h, theme);
            y += row_h;
        }
        return y + @as(f32, @floatFromInt(catalog.entries.len - range.last)) * row_h;
    }

    const visible_top = extensions_panel.list_top;
    const visible_bottom = extensions_panel.list_top + viewport_h;
    for (catalog.entries) |*entry| {
        if (!marketplaceMatches(filter, entry)) continue;
        if (y + row_h >= visible_top and y < visible_bottom) {
            drawMarketplaceRow(entry, panel_x, y, panel_w, row_h, theme);
        }
        y += row_h;
    }
    return y;
}

pub fn drawExtensionsPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const host = &wb.extension_host;
    const panel_y = extensions_panel.panel_top;
    const filter = wb.extensionsFilterSlice();
    const catalog_ptr: ?*const plugin.MarketplaceCatalog = if (wb.marketplace_catalog) |*catalog| catalog else null;
    const list_viewport = extensions_panel.viewportHeight(h);

    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);

    const icon_c = renderer.Color{ .r = 0.64, .g = 0.65, .b = 0.68, .a = 1.0 };
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 12, 16, 16, icon_c);
    drawStrongText("EXTENSIONS", panel_x + 28, panel_y + 13, 11.0, .{ .r = 0.8, .g = 0.81, .b = 0.84, .a = 1.0 });
    renderer.Renderer.drawSvg(renderer.icons.sync, panel_x + panel_w - 56, panel_y + 11, 16, 16, icon_c);
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, panel_x + panel_w - 30, panel_y + 11, 16, 16, icon_c);

    const filter_y = extensions_panel.filter_top;
    const input_border = if (wb.focused_panel == .extensions) shared.color(theme.colors.accent) else renderer.Color{ .r = 0.25, .g = 0.26, .b = 0.29, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(panel_x + 12, filter_y, panel_w - 24, extensions_panel.filter_h, 5, input_border);
    renderer.Renderer.drawRoundedRect(panel_x + 13, filter_y + 1, panel_w - 26, extensions_panel.filter_h - 2, 5, .{ .r = 0.18, .g = 0.19, .b = 0.21, .a = 1.0 });

    var filter_buf: [129]u8 = undefined;
    const filter_text = copyZ(&filter_buf, filter);
    const show_placeholder = filter.len == 0 and wb.focused_panel != .extensions;
    const input_text = if (show_placeholder) "Search Extensions in Marketplace" else filter_text;
    const input_color = if (show_placeholder)
        renderer.Color{ .r = 0.58, .g = 0.59, .b = 0.63, .a = 1.0 }
    else
        renderer.Color{ .r = 0.9, .g = 0.91, .b = 0.94, .a = 1.0 };
    drawClippedText(input_text, panel_x + 20, filter_y + 9, panel_w - 82, 18, 12.5, input_color, false);
    renderer.Renderer.drawSvg(renderer.icons.search, panel_x + panel_w - 36, filter_y + 9, 16, 16, icon_c);

    const btn_w = (panel_w - 44) / 2;
    drawButton("Open workspace", panel_x + 12, extensions_panel.dir_row_top, btn_w, extensions_panel.dir_row_h, false, theme);
    drawButton("Open user", panel_x + 16 + btn_w, extensions_panel.dir_row_top, btn_w, extensions_panel.dir_row_h, false, theme);

    drawButton("Installed", panel_x + 12, extensions_panel.tabs_top, btn_w, extensions_panel.tabs_h, wb.extensions_panel_mode == .installed, theme);
    drawButton("Marketplace", panel_x + 16 + btn_w, extensions_panel.tabs_top, btn_w, extensions_panel.tabs_h, wb.extensions_panel_mode == .marketplace, theme);

    renderer.Renderer.setClipRect(panel_x, extensions_panel.list_top, panel_w, h - extensions_panel.list_top - layout.status_height);
    var y = extensions_panel.list_top + extensions_panel.footer_h - wb.extensions_scroll_y;

    if (wb.extensions_detail_index) |detail_index| {
        if (wb.marketplace_catalog) |catalog| {
            if (detail_index < catalog.entries.len) {
                const entry = catalog.entries[detail_index];
                drawUiText("< Back", panel_x + 16, y + 4, 11.5, shared.color(theme.colors.accent));
                y += 28;
                drawClippedText(entry.name, panel_x + 16, y, panel_w - 32, 24, 15.0, .{ .r = 0.92, .g = 0.93, .b = 0.95, .a = 1.0 }, true);
                y += 26;
                drawClippedText(entry.id, panel_x + 16, y, panel_w - 32, 16, 10.5, .{ .r = 0.55, .g = 0.75, .b = 0.95, .a = 1.0 }, false);
                y += 22;
                drawClippedText(entry.publisher, panel_x + 16, y, panel_w - 32, 16, 11.0, .{ .r = 0.68, .g = 0.69, .b = 0.72, .a = 1.0 }, true);
                y += 24;
                drawClippedText(entry.description, panel_x + 16, y, panel_w - 32, 42, 11.0, .{ .r = 0.76, .g = 0.77, .b = 0.8, .a = 1.0 }, false);
                y += 58;
                renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 28, 5, shared.color(theme.colors.accent_soft));
                drawStrongText("Install extension", panel_x + 22, y + 8, 11.5, .{ .r = 0.92, .g = 0.94, .b = 0.98, .a = 1.0 });
            }
        }
    } else if (wb.extensions_panel_mode == .installed) {
        const count = installedCount(host, filter);
        drawSectionHeader("INSTALLED", count, panel_x, y, panel_w);
        y += 32;
        const visible_top = extensions_panel.list_top;
        const visible_bottom = extensions_panel.list_top + list_viewport;
        var first_visible_index: usize = host.extensions.items.len;
        var scan_y = y;
        for (host.extensions.items, 0..) |ext, index| {
            if (!installedMatches(filter, &ext)) continue;
            const block_h = extensions_panel.blockHeight(&ext);
            if (scan_y + block_h >= visible_top) {
                first_visible_index = index;
                y = scan_y;
                break;
            }
            scan_y += block_h;
        }

        if (first_visible_index < host.extensions.items.len) {
            for (host.extensions.items[first_visible_index..], first_visible_index..) |ext, index| {
                if (!installedMatches(filter, &ext)) continue;
                const block_h = extensions_panel.blockHeight(&ext);
                if (y >= visible_bottom) break;
                drawInstalledRow(wb, &ext, index, panel_x, y, panel_w, block_h);
                y += block_h;
            }
        } else {
            y = scan_y;
        }

        if (count == 0) {
            drawUiText("No extensions loaded.", panel_x + 16, y + 8, 11.5, .{ .r = 0.62, .g = 0.63, .b = 0.66, .a = 1.0 });
            drawUiText("Add forge.toml to extensions/", panel_x + 16, y + 28, 10.5, .{ .r = 0.5, .g = 0.51, .b = 0.55, .a = 1.0 });
        }
    } else if (wb.marketplace_catalog) |catalog| {
        const count = marketplaceCount(catalog_ptr, filter);
        drawSectionHeader("RECOMMENDED", count, panel_x, y, panel_w);
        y += 32;
        y = drawMarketplaceRows(&catalog, filter, panel_x, panel_w, y, list_viewport, wb.extensions_scroll_y, theme);
        if (count == 0) {
            drawUiText("No marketplace results.", panel_x + 16, y + 8, 11.5, .{ .r = 0.62, .g = 0.63, .b = 0.66, .a = 1.0 });
        }
    } else {
        drawUiText("No catalog found.", panel_x + 16, y + 8, 11.5, .{ .r = 0.62, .g = 0.63, .b = 0.66, .a = 1.0 });
        drawUiText("Add extensions/catalog.toml", panel_x + 16, y + 28, 10.5, .{ .r = 0.5, .g = 0.51, .b = 0.55, .a = 1.0 });
    }

    renderer.Renderer.clearClipRect();
    const ext_content = extensions_panel.contentHeight(host, catalog_ptr, wb.extensions_panel_mode, filter, wb.extensions_detail_index);
    const ext_viewport = extensions_panel.viewportHeight(h);
    const ext_max = extensions_panel.maxScrollY(host, catalog_ptr, wb.extensions_panel_mode, h, filter, wb.extensions_detail_index);
    const show_ext_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, extensions_panel.list_top, panel_w, ext_viewport);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        extensions_panel.list_top,
        ext_viewport,
        wb.extensions_scroll_y,
        ext_max,
        ext_content,
        ext_viewport,
        show_ext_scroll,
    );
}

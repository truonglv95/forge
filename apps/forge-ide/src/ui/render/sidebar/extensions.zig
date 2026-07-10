const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const extensions_panel = @import("../../sidebar/extensions_panel.zig");
const plugin = @import("forge-plugin");
const agent_scope_picker_mod = @import("../../../agent/scope_picker.zig");
const scrollbar = @import("../../core/scrollbar.zig");
pub fn drawExtensionsPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const host = &wb.extension_host;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("EXTENSIONS", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const filter_y = extensions_panel.list_top - 20;
    renderer.Renderer.drawRoundedRect(panel_x + 12, filter_y, panel_w - 24, 18, 4, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
    var filter_buf: [128:0]u8 = undefined;
    @memcpy(filter_buf[0..wb.extensions_filter_len], wb.extensionsFilterSlice());
    filter_buf[wb.extensions_filter_len] = 0;
    renderer.Renderer.drawText(@ptrCast(&filter_buf), panel_x + 20, filter_y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

    var y = extensions_panel.list_top - wb.extensions_scroll_y;
    const btn_w = (panel_w - 44) / 2;
    const filter = wb.extensionsFilterSlice();

    if (y + 22 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, btn_w, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Reload", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(panel_x + 16 + btn_w, y, btn_w, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Open ext/", panel_x + 24 + btn_w, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Open .forge/extensions/", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        const installed_bg = if (wb.extensions_panel_mode == .installed)
            shared.color(theme.colors.accent_soft)
        else
            renderer.Color{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 };
        const market_bg = if (wb.extensions_panel_mode == .marketplace)
            shared.color(theme.colors.accent_soft)
        else
            renderer.Color{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 };
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, btn_w, 18, 4, installed_bg);
        renderer.Renderer.drawText("Installed", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(panel_x + 16 + btn_w, y, btn_w, 18, 4, market_bg);
        renderer.Renderer.drawText("Marketplace", panel_x + 24 + btn_w, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += extensions_panel.footer_h;

    if (wb.extensions_detail_index) |detail_index| {
        if (wb.marketplace_catalog) |catalog| {
            if (detail_index < catalog.entries.len) {
                const entry = catalog.entries[detail_index];
                if (y + 22 >= 65 and y < h - layout.status_height) {
                    renderer.Renderer.drawText("< Back", panel_x + 16, y + 4, 11.0, shared.color(theme.colors.accent));
                }
                y += 24;
                var title_buf: [128:0]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}", .{ entry.name, entry.version }) catch entry.name;
                title_buf[title.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 13.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                y += 22;
                var id_buf: [128:0]u8 = undefined;
                @memcpy(id_buf[0..entry.id.len], entry.id);
                id_buf[entry.id.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&id_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.55, .g = 0.75, .b = 0.95, .a = 1.0 });
                y += 16;
                var publisher_buf: [128:0]u8 = undefined;
                const publisher_line = std.fmt.bufPrint(&publisher_buf, "Publisher: {s}", .{entry.publisher}) catch entry.publisher;
                publisher_buf[publisher_line.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&publisher_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                y += 18;
                var desc_buf: [256:0]u8 = undefined;
                @memcpy(desc_buf[0..@min(entry.description.len, desc_buf.len - 1)], entry.description);
                desc_buf[@min(entry.description.len, desc_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&desc_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });
                y += 40;
                renderer.Renderer.drawRoundedRect(panel_x + 12, y + 40, panel_w - 24, 18, 4, shared.color(theme.colors.accent_soft));
                renderer.Renderer.drawText("Install extension", panel_x + 20, y + 43, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            }
        }
    } else if (wb.extensions_panel_mode == .installed) {
        for (host.extensions.items, 0..) |ext, index| {
            if (filter.len > 0 and !agent_scope_picker_mod.matchesQuery(filter, ext.name) and !agent_scope_picker_mod.matchesQuery(filter, ext.id)) continue;
            const block_h = extensions_panel.blockHeight(&ext);
            if (y + block_h >= 65 and y < h - layout.status_height) {
                const selected = wb.selected_extension_index == index;
                if (selected) {
                    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, block_h - 4, 4, shared.color(theme.colors.selection));
                }

                var title_buf: [128:0]u8 = undefined;
                const status = if (ext.active) "active" else "off";
                const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}  {s}", .{ ext.name, ext.version, status }) catch ext.name;
                title_buf[title.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });

                var id_buf: [128:0]u8 = undefined;
                @memcpy(id_buf[0..ext.id.len], ext.id);
                id_buf[ext.id.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&id_buf), panel_x + 16, y + 20, 10.0, .{ .r = 0.55, .g = 0.75, .b = 0.95, .a = 1.0 });

                var path_buf: [160:0]u8 = undefined;
                const path_label = if (std.mem.eql(u8, ext.root_path, "(builtin)"))
                    "(built-in)"
                else
                    ext.root_path;
                @memcpy(path_buf[0..path_label.len], path_label);
                path_buf[path_label.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&path_buf), panel_x + 16, y + 34, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });

                var cmd_y = y + extensions_panel.header_h;
                for (ext.commands.items) |cmd| {
                    var cmd_buf: [160:0]u8 = undefined;
                    const cmd_line = std.fmt.bufPrint(&cmd_buf, "> {s}", .{cmd.title}) catch cmd.title;
                    cmd_buf[cmd_line.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&cmd_buf), panel_x + 20, cmd_y, 10.0, .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 });
                    cmd_y += extensions_panel.cmd_row_h;
                }
                if (wb.canUninstallExtension(&ext)) {
                    renderer.Renderer.drawText("Uninstall", panel_x + 16, y + block_h - 20, 10.0, .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 });
                }
            }
            y += block_h;
        }

        if (host.extensions.items.len == 0) {
            renderer.Renderer.drawText("No extensions loaded.", panel_x + 16, extensions_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            renderer.Renderer.drawText("Add forge.toml to extensions/", panel_x + 16, extensions_panel.list_top + 26, 10.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
        }
    } else if (wb.marketplace_catalog) |catalog| {
        if (filter.len == 0) {
            const row_h = extensions_panel.marketplace_row_h;
            const view_top = @max(0, 65 - y);
            const view_bottom = @max(0, h - layout.status_height - y);
            const start_idx = @as(usize, @intFromFloat(view_top / row_h));
            const end_idx = @min(catalog.entries.len, @as(usize, @intFromFloat(view_bottom / row_h)) + 2);

            y += @as(f32, @floatFromInt(start_idx)) * row_h;
            for (catalog.entries[start_idx..end_idx], start_idx..) |entry, index| {
                if (y + row_h >= 65 and y < h - layout.status_height) {
                    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, row_h - 6, 4, shared.color(theme.colors.selection));
                    var title_buf: [128:0]u8 = undefined;
                    const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}", .{ entry.name, entry.version }) catch entry.name;
                    title_buf[title.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                    var desc_buf: [192:0]u8 = undefined;
                    @memcpy(desc_buf[0..@min(entry.description.len, desc_buf.len - 1)], entry.description);
                    desc_buf[@min(entry.description.len, desc_buf.len - 1)] = 0;
                    renderer.Renderer.drawText(@ptrCast(&desc_buf), panel_x + 16, y + 20, 10.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                    renderer.Renderer.drawText("Install", panel_x + 16, y + 36, 10.0, shared.color(theme.colors.accent));
                    renderer.Renderer.drawText("Details >", panel_x + panel_w - 80, y + 36, 10.0, .{ .r = 0.65, .g = 0.75, .b = 0.95, .a = 1.0 });
                    _ = index;
                }
                y += row_h;
            }
            if (end_idx < catalog.entries.len) {
                y += @as(f32, @floatFromInt(catalog.entries.len - end_idx)) * row_h;
            }
        } else {
            for (catalog.entries, 0..) |entry, index| {
                if (!agent_scope_picker_mod.matchesQuery(filter, entry.name) and !agent_scope_picker_mod.matchesQuery(filter, entry.id) and !agent_scope_picker_mod.matchesQuery(filter, entry.description)) continue;
                if (y + extensions_panel.marketplace_row_h >= 65 and y < h - layout.status_height) {
                    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, extensions_panel.marketplace_row_h - 6, 4, shared.color(theme.colors.selection));
                    var title_buf: [128:0]u8 = undefined;
                    const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}", .{ entry.name, entry.version }) catch entry.name;
                    title_buf[title.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                    var desc_buf: [192:0]u8 = undefined;
                    @memcpy(desc_buf[0..@min(entry.description.len, desc_buf.len - 1)], entry.description);
                    desc_buf[@min(entry.description.len, desc_buf.len - 1)] = 0;
                    renderer.Renderer.drawText(@ptrCast(&desc_buf), panel_x + 16, y + 20, 10.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                    renderer.Renderer.drawText("Install", panel_x + 16, y + 36, 10.0, shared.color(theme.colors.accent));
                    renderer.Renderer.drawText("Details >", panel_x + panel_w - 80, y + 36, 10.0, .{ .r = 0.65, .g = 0.75, .b = 0.95, .a = 1.0 });
                    _ = index;
                }
                y += extensions_panel.marketplace_row_h;
            }
        }
        if (catalog.entries.len == 0) {
            renderer.Renderer.drawText("Catalog is empty.", panel_x + 16, y + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        }
    } else {
        renderer.Renderer.drawText("No catalog found.", panel_x + 16, y + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        renderer.Renderer.drawText("Add extensions/catalog.toml", panel_x + 16, y + 26, 10.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
    }

    renderer.Renderer.clearClipRect();
    const catalog_ptr: ?*const plugin.MarketplaceCatalog = if (wb.marketplace_catalog) |*catalog| catalog else null;
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

const std = @import("std");
const layout = @import("layout.zig");
const plugin = @import("forge-plugin");
const scope_picker = @import("../agent/scope_picker.zig");

pub const PanelMode = enum { installed, marketplace };

pub const list_top: f32 = 163;
pub const header_h: f32 = 52;
pub const cmd_row_h: f32 = 18;
pub const footer_h: f32 = 72;
pub const marketplace_row_h: f32 = 56;
pub const detail_h: f32 = 220;

pub fn blockHeight(ext: *const plugin.LoadedExtension) f32 {
    return header_h + @as(f32, @floatFromInt(ext.commands.items.len)) * cmd_row_h + 28;
}

fn extensionMatchesFilter(filter: []const u8, ext: *const plugin.LoadedExtension) bool {
    if (filter.len == 0) return true;
    return scope_picker.matchesQuery(filter, ext.name) or
        scope_picker.matchesQuery(filter, ext.id) or
        scope_picker.matchesQuery(filter, ext.version);
}

fn catalogMatchesFilter(filter: []const u8, entry: *const plugin.MarketplaceEntry) bool {
    if (filter.len == 0) return true;
    return scope_picker.matchesQuery(filter, entry.name) or
        scope_picker.matchesQuery(filter, entry.id) or
        scope_picker.matchesQuery(filter, entry.description) or
        scope_picker.matchesQuery(filter, entry.publisher);
}

pub fn installedContentHeight(host: *const plugin.Host, filter: []const u8) f32 {
    var total: f32 = footer_h;
    for (host.extensions.items) |*ext| {
        if (!extensionMatchesFilter(filter, ext)) continue;
        total += blockHeight(ext);
    }
    return total;
}

pub fn marketplaceContentHeight(catalog: ?*const plugin.MarketplaceCatalog, filter: []const u8) f32 {
    const catalog_ptr = catalog orelse return footer_h;
    var total: f32 = footer_h;
    for (catalog_ptr.entries) |*entry| {
        if (catalogMatchesFilter(filter, entry)) total += marketplace_row_h;
    }
    return total;
}

pub fn contentHeight(
    host: *const plugin.Host,
    catalog: ?*const plugin.MarketplaceCatalog,
    mode: PanelMode,
    filter: []const u8,
    detail_index: ?usize,
) f32 {
    if (detail_index != null) return detail_h + footer_h;
    return switch (mode) {
        .installed => installedContentHeight(host, filter),
        .marketplace => marketplaceContentHeight(catalog, filter),
    };
}

pub fn viewportHeight(window_h: f32) f32 {
    return @max(0, window_h - layout.status_height - list_top);
}

pub fn maxScrollY(
    host: *const plugin.Host,
    catalog: ?*const plugin.MarketplaceCatalog,
    mode: PanelMode,
    window_h: f32,
    filter: []const u8,
    detail_index: ?usize,
) f32 {
    return @max(0, contentHeight(host, catalog, mode, filter, detail_index) - viewportHeight(window_h));
}

pub fn clampScrollY(
    scroll_y: f32,
    host: *const plugin.Host,
    catalog: ?*const plugin.MarketplaceCatalog,
    mode: PanelMode,
    window_h: f32,
    filter: []const u8,
    detail_index: ?usize,
) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(host, catalog, mode, window_h, filter, detail_index));
}

pub const Hit = union(enum) {
    reload,
    open_workspace_dir,
    open_user_dir,
    show_installed,
    show_marketplace,
    toggle: usize,
    install: usize,
    show_detail: usize,
    back_from_detail,
    uninstall: usize,
    run_command: struct { ext_index: usize, cmd_index: usize },
};

pub fn hitTest(
    host: *const plugin.Host,
    catalog: ?*const plugin.MarketplaceCatalog,
    mode: PanelMode,
    panel_x: f32,
    panel_w: f32,
    click_x: f32,
    click_y: f32,
    scroll_y: f32,
    filter: []const u8,
    detail_index: ?usize,
    can_uninstall_fn: *const fn (ext_index: usize) bool,
) ?Hit {
    if (click_x < panel_x or click_x >= panel_x + panel_w) return null;
    const local_y = click_y - list_top + scroll_y;
    if (local_y < 0) return null;

    const btn_w = (panel_w - 44) / 2;
    if (local_y >= 0 and local_y < 22) {
        if (click_x < panel_x + 20 + btn_w) return .reload;
        return .open_workspace_dir;
    }
    if (local_y >= 22 and local_y < 44) {
        return .open_user_dir;
    }
    if (local_y >= 44 and local_y < 66) {
        if (click_x < panel_x + 20 + btn_w) return .show_installed;
        return .show_marketplace;
    }

    if (detail_index != null) {
        if (local_y >= footer_h and local_y < footer_h + 22) return .back_from_detail;
        const catalog_ptr = catalog orelse return null;
        const index = detail_index.?;
        if (index >= catalog_ptr.entries.len) return null;
        if (local_y >= footer_h + 160 and local_y < footer_h + 180) return .{ .install = index };
        return null;
    }

    var y: f32 = footer_h;
    if (mode == .installed) {
        for (host.extensions.items, 0..) |*ext, ext_index| {
            if (!extensionMatchesFilter(filter, ext)) continue;
            const block_h = blockHeight(ext);
            if (local_y >= y and local_y < y + block_h) {
                const inner = local_y - y;
                if (inner >= block_h - 24 and can_uninstall_fn(ext_index)) return .{ .uninstall = ext_index };
                if (inner < header_h) return .{ .toggle = ext_index };
                const cmd_index_f = (inner - header_h) / cmd_row_h;
                const cmd_index: usize = @intFromFloat(cmd_index_f);
                if (cmd_index < ext.commands.items.len) {
                    return .{ .run_command = .{ .ext_index = ext_index, .cmd_index = cmd_index } };
                }
                return .{ .toggle = ext_index };
            }
            y += block_h;
        }
    } else if (catalog) |cat| {
        for (cat.entries, 0..) |_, index| {
            if (!catalogMatchesFilter(filter, &cat.entries[index])) continue;
            if (local_y >= y and local_y < y + marketplace_row_h) {
                const row_inner = local_y - y;
                if (row_inner >= marketplace_row_h - 20) return .{ .show_detail = index };
                return .{ .install = index };
            }
            y += marketplace_row_h;
        }
    }
    return null;
}

test "extensions scroll math" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var host = plugin.Host.init(allocator, io);
    defer host.deinit();
    try std.testing.expectEqual(@as(f32, 0), maxScrollY(&host, null, .installed, 800, "", null));
}

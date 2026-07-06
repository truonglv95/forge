const std = @import("std");
const workspace = @import("forge-workspace");
const plugin = @import("forge-plugin");
const builtin_ext = @import("../extensions/builtin.zig");
const wasm_bridge = @import("../extensions/wasm_bridge.zig");
const settings_mod = @import("settings.zig");

pub fn canUninstallExtension(wb: anytype, ext: *const plugin.LoadedExtension) bool {
    _ = wb;
    return std.mem.startsWith(u8, ext.root_path, ".forge/extensions/");
}

pub fn handleExtensionsClick(wb: anytype, hit: @import("../ui/sidebar/extensions_panel.zig").Hit) !void {
    switch (hit) {
        .reload => try wb.dispatch(.reload_extensions),
        .open_workspace_dir => try wb.dispatch(.{ .open_file = "extensions/README.md" }),
        .open_user_dir => try wb.dispatch(.{ .open_file = ".forge/extensions/README.md" }),
        .show_installed => try wb.dispatch(.{ .set_extensions_panel_mode = .installed }),
        .show_marketplace => try wb.dispatch(.{ .set_extensions_panel_mode = .marketplace }),
        .toggle => |index| try wb.dispatch(.{ .extension_toggle = index }),
        .install => |index| {
            const catalog = wb.marketplace_catalog orelse return;
            if (index >= catalog.entries.len) return;
            const id = try wb.allocator.dupe(u8, catalog.entries[index].id);
            defer wb.allocator.free(id);
            try wb.dispatch(.{ .install_marketplace_extension = id });
        },
        .show_detail => |index| try wb.dispatch(.{ .extensions_show_detail = index }),
        .back_from_detail => try wb.dispatch(.extensions_back_from_detail),
        .uninstall => |index| {
            if (index >= wb.extension_host.extensions.items.len) return;
            const ext = &wb.extension_host.extensions.items[index];
            const id = try wb.allocator.dupe(u8, ext.id);
            defer wb.allocator.free(id);
            try wb.dispatch(.{ .uninstall_extension = id });
        },
        .run_command => |sel| {
            if (sel.ext_index >= wb.extension_host.extensions.items.len) return;
            const ext = &wb.extension_host.extensions.items[sel.ext_index];
            if (sel.cmd_index >= ext.commands.items.len) return;
            const cmd_id = ext.commands.items[sel.cmd_index].id;
            try wb.dispatch(.{ .run_extension_command = cmd_id });
            wb.selected_extension_index = sel.ext_index;
        },
    }
}

pub fn reloadExtensions(wb: anytype) !void {
    wb.extension_host.deinit();
    wb.extension_host = plugin.Host.init(wb.allocator, wb.io);
    try wb.extension_host.registerBuiltin(&builtin_ext.hello_extension);
    wb.extension_host.setHostCallbacks(wasm_bridge.hostCallbacks());
    try wb.extension_host.discoverWorkspace(wb.workspace_root);
    try wb.extension_host.activateAll();
    if (wb.marketplace_catalog) |*catalog| catalog.deinit(wb.allocator);
    wb.marketplace_catalog = plugin.marketplace.loadCatalog(wb.allocator, wb.io, wb.workspace_root) catch null;
    try wb.palette.rebuildCatalog();
    try wb.syncContributions();
    try wb.setStatus("Extensions reloaded");
}

pub fn ensureBundledExtensions(wb: anytype) !void {
    const manifest_wp = workspace.WorkspacePath.parse(".forge/extensions/zig-lsp/forge.toml") catch return;
    if (workspace.FileSnapshot.read(wb.allocator, wb.io, wb.workspace_root, manifest_wp)) |snap_val| {
        var snap = snap_val;
        defer snap.deinit();
        return;
    } else |_| {}

    const catalog = wb.marketplace_catalog orelse return;
    const entry = plugin.marketplace.findEntry(&catalog, "forge.lsp.zig") orelse return;
    const dest = try plugin.marketplace.install(wb.allocator, wb.io, wb.workspace_root, entry);
    defer wb.allocator.free(dest);
}

pub fn persistExtensionTheme(wb: anytype, qualified: []const u8) !void {
    const existing = @import("../theme_loader.zig").readUserSettings(wb.allocator, wb.io, wb.workspace_root) catch null;
    defer if (existing) |content| wb.allocator.free(content);

    const content = if (existing) |user_content|
        try settings_mod.mergeExtensionTheme(wb.allocator, user_content, qualified)
    else
        try std.fmt.allocPrint(wb.allocator,
            \\[extension_theme]
            \\active = "{s}"
            \\
        , .{qualified});
    defer wb.allocator.free(content);

    const wp = try workspace.WorkspacePath.parse(".forge/settings.toml");
    try workspace.atomic.replaceFile(wb.io, wb.workspace_root, wp, content);
}

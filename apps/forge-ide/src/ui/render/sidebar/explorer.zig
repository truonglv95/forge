const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const explorer_scroll = @import("../../sidebar/explorer_scroll.zig");
pub fn drawExplorerPanel(wb: *Workbench, explorer_x: f32, explorer_panel_width: f32, h: f32, alloc: std.mem.Allocator) void {
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(explorer_x, panel_y, explorer_panel_width, h - panel_y - layout.status_height);

    const renderer_theme = state.renderer_theme;
    const my = state.last_mouse_y;
    const mx = state.last_mouse_x;
    const header_padding = renderer_theme.getMetric("explorer.header_padding", 8.0);
    const icon_size = renderer_theme.getMetric("explorer.icon_size", 16.0);

    // Create Root Node
    var root_node = alloc.create(renderer.layout.Node) catch return;
    root_node.* = renderer.layout.Node.init(alloc);
    root_node.direction = .column;
    var root_view = alloc.create(renderer.view.View) catch return;
    root_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    root_view.flex_node = root_node;
    root_view.theme = renderer_theme;

    // Header Row Node
    var header_node = alloc.create(renderer.layout.Node) catch return;
    header_node.* = renderer.layout.Node.init(alloc);
    header_node.direction = .row;
    header_node.padding = header_padding;

    root_node.addChild(alloc, header_node) catch return;

    var header_view = alloc.create(renderer.view.View) catch return;
    header_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    header_view.flex_node = header_node;
    root_view.addChild(alloc, header_view) catch return;

    // Workspace Chevron
    var chevron_node = alloc.create(renderer.layout.Node) catch return;
    chevron_node.* = renderer.layout.Node.init(alloc);
    chevron_node.direction = .row;
    chevron_node.width = icon_size;
    chevron_node.height = icon_size;
    header_node.addChild(alloc, chevron_node) catch return;

    var chevron_view = alloc.create(renderer.view.View) catch return;
    chevron_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    chevron_view.flex_node = chevron_node;
    const chevron_svg = if (wb.explorer_root_expanded) renderer.icons.chevron_down else renderer.icons.chevron_right;
    chevron_view.data = .{ .icon = .{ .svg = chevron_svg, .color = .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 }, .size = icon_size } };
    header_view.addChild(alloc, chevron_view) catch return;

    // Workspace Label
    var ws_name_buf: [128:0]u8 = undefined;
    const basename = wb.workspace_name;
    var name_len: usize = 0;
    for (basename) |ch| {
        if (name_len >= ws_name_buf.len - 1) break;
        ws_name_buf[name_len] = std.ascii.toUpper(ch);
        name_len += 1;
    }
    ws_name_buf[name_len] = 0;

    var label_node = alloc.create(renderer.layout.Node) catch return;
    label_node.* = renderer.layout.Node.init(alloc);
    label_node.direction = .row;
    label_node.flex_grow = 1.0; // Pushes icons to the right
    header_node.addChild(alloc, label_node) catch return;

    var label_view = alloc.create(renderer.view.View) catch return;
    label_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    label_view.flex_node = label_node;
    const alloc_name = alloc.dupeZ(u8, ws_name_buf[0..name_len]) catch return;
    label_view.data = .{ .label = .{ .text = alloc_name, .color = .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 }, .size = 11.0 } };
    header_view.addChild(alloc, label_view) catch return;

    // Actions
    const action_svgs = [_][:0]const u8{ renderer.icons.file, renderer.icons.file_directory, renderer.icons.sync, renderer.icons.chevron_down };

    var action_views: [4]*renderer.view.View = undefined;

    for (action_svgs, 0..) |svg, i| {
        var action_node = alloc.create(renderer.layout.Node) catch return;
        action_node.* = renderer.layout.Node.init(alloc);
        action_node.direction = .row;
        action_node.width = icon_size + 4.0;
        action_node.margin = 2.0;
        action_node.height = icon_size + 4.0;
        header_node.addChild(alloc, action_node) catch return;

        var action_view = alloc.create(renderer.view.View) catch return;
        action_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        action_view.flex_node = action_node;
        action_view.data = .{ .icon = .{ .svg = svg, .color = .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 }, .size = icon_size } };
        header_view.addChild(alloc, action_view) catch return;
        action_views[i] = action_view;
    }

    // Layout Calculation
    root_node.calculateLayout(explorer_panel_width, h - panel_y, explorer_x, panel_y);

    // Apply Hover States

    for (action_views) |v| {
        if (v.flex_node) |node| {
            if (mx >= node.layout_x and mx < (node.layout_x + node.layout_w) and
                my >= node.layout_y and my < (node.layout_y + node.layout_h))
            {
                v.bg_color = .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
            }
        }
    }

    // Render the Header Declaratively!
    root_view.render();

    if (!wb.explorer_root_expanded) {
        renderer.Renderer.clearClipRect();
        return;
    }

    const active_path = wb.activeFilePath();
    const row_h = explorer_scroll.row_height;
    const range = shared.visibleRowRange(wb.explorer_scroll_y, explorer_scroll.viewportHeight(h), row_h, wb.explorer.entries.len);

    // Create Tree Root Node
    var tree_root_node = alloc.create(renderer.layout.Node) catch return;
    tree_root_node.* = renderer.layout.Node.init(alloc);
    tree_root_node.direction = .column;
    var tree_root_view = alloc.create(renderer.view.View) catch return;
    tree_root_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    tree_root_view.flex_node = tree_root_node;
    tree_root_view.theme = renderer_theme;

    // To handle hover logic inside loop, we capture mouse
    var action_overlay: ?struct { x: f32, y: f32, w: f32, h: f32, text: []const u8 } = null;

    for (wb.explorer.entries[range.first..range.last], range.first..) |row, row_index| {
        const row_selected = if (wb.explorer.selected_path) |sel| std.mem.eql(u8, sel, row.path) else false;
        const row_active = if (active_path) |act| std.mem.eql(u8, act, row.path) else false;
        const row_expanded = row.kind == .directory and wb.explorer.expanded_paths.contains(row.path);

        const indent = @as(f32, @floatFromInt(row.depth)) * 14.0;
        const icon_w: f32 = 14.0;

        var row_node = alloc.create(renderer.layout.Node) catch return;
        row_node.* = renderer.layout.Node.init(alloc);
        row_node.direction = .row;
        row_node.height = row_h;
        tree_root_node.addChild(alloc, row_node) catch return;

        var row_view = alloc.create(renderer.view.View) catch return;
        row_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        row_view.flex_node = row_node;
        tree_root_view.addChild(alloc, row_view) catch return;

        // Background logic
        if (row_active) {
            row_view.bg_color_id = "accent";
        } else if (row_selected) {
            row_view.bg_color_id = "selection";
        } else if (state.explorer_hover_row == row_index) {
            // we will also check hover via mouse y later, but for now fallback to state
            row_view.bg_color = .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
        }

        // Left Padding (20) + Indent
        var indent_node = alloc.create(renderer.layout.Node) catch return;
        indent_node.* = renderer.layout.Node.init(alloc);
        indent_node.direction = .row;
        indent_node.width = 20.0 + indent;
        row_node.addChild(alloc, indent_node) catch return;

        var indent_view = alloc.create(renderer.view.View) catch return;
        indent_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        indent_view.flex_node = indent_node;
        row_view.addChild(alloc, indent_view) catch return;

        // Chevron / Icon
        var icon_node = alloc.create(renderer.layout.Node) catch return;
        icon_node.* = renderer.layout.Node.init(alloc);
        icon_node.direction = .row;
        icon_node.width = icon_w;
        row_node.addChild(alloc, icon_node) catch return;

        var icon_view = alloc.create(renderer.view.View) catch return;
        icon_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        icon_view.flex_node = icon_node;

        if (row.kind == .directory) {
            const chevron_color = if (row_selected or row_active)
                renderer.Color{ .r = 0.89, .g = 0.89, .b = 0.89, .a = 1.0 }
            else
                renderer.Color{ .r = 0.62, .g = 0.64, .b = 0.68, .a = 1.0 };
            const c_svg = if (row_expanded) renderer.icons.chevron_down else renderer.icons.chevron_right;
            icon_view.data = .{ .icon = .{ .svg = c_svg, .color = chevron_color, .size = icon_w } };
        } else {
            const res = @import("../icon_resolver.zig").resolveIcon(row.name);
            icon_view.data = .{ .icon = .{ .svg = res.svg, .color = res.color, .size = icon_w } };
        }
        row_view.addChild(alloc, icon_view) catch return;

        // Gap
        var gap_node = alloc.create(renderer.layout.Node) catch return;
        gap_node.* = renderer.layout.Node.init(alloc);
        gap_node.direction = .row;
        gap_node.width = 6.0;
        row_node.addChild(alloc, gap_node) catch return;
        var gap_view = alloc.create(renderer.view.View) catch return;
        gap_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        gap_view.flex_node = gap_node;
        row_view.addChild(alloc, gap_view) catch return;

        // Git Status Logic
        var is_modified = false;
        var is_added = false;
        var is_untracked = false;

        if (wb.git.status) |*status| {
            if (std.mem.startsWith(u8, row.path, wb.workspace_path)) {
                var rel_path = row.path[wb.workspace_path.len..];
                if (rel_path.len > 0 and (rel_path[0] == '/' or rel_path[0] == '\\')) {
                    rel_path = rel_path[1..];
                }

                if (row.kind == .directory) {
                    if (status.directoryAggregate(rel_path)) |aggregate| {
                        if (aggregate[0] == 'M' or aggregate[1] == 'M') is_modified = true;
                        if (aggregate[0] == 'A') is_added = true;
                        if (aggregate[0] == '?') is_untracked = true;
                    }
                } else if (status.findFirstStartingWith(rel_path)) |start_idx_git| {
                    const entry = &status.entries[start_idx_git];
                    if (std.mem.eql(u8, entry.path, rel_path)) {
                        if (entry.status[0] == 'M' or entry.status[1] == 'M') is_modified = true;
                        if (entry.status[0] == 'A') is_added = true;
                        if (entry.status[0] == '?') is_untracked = true;
                    }
                }
            }
        }

        // Label
        var row_label_node = alloc.create(renderer.layout.Node) catch return;
        row_label_node.* = renderer.layout.Node.init(alloc);
        row_label_node.direction = .row;
        row_label_node.flex_grow = 1.0;
        row_node.addChild(alloc, row_label_node) catch return;

        var row_label_view = alloc.create(renderer.view.View) catch return;
        row_label_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        row_label_view.flex_node = row_label_node;

        var color = if (row_active)
            renderer.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }
        else if (row_selected)
            renderer.Color{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 }
        else
            renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

        if (!row_active and !row_selected) {
            if (is_modified) {
                color = renderer_theme.getColor("git.modified");
            } else if (is_added or is_untracked) {
                color = renderer_theme.getColor("git.added");
            }
        }

        var label_buf: [512:0]u8 = undefined;
        const name = row.name;
        const max_name = @min(name.len, label_buf.len - 1);
        @memcpy(label_buf[0..max_name], name[0..max_name]);
        label_buf[max_name] = 0;
        const row_alloc_name = alloc.dupeZ(u8, label_buf[0..max_name]) catch return;

        row_label_view.data = .{ .label = .{ .text = row_alloc_name, .color = color, .size = 13.0 } };
        row_view.addChild(alloc, row_label_view) catch return;

        // If renaming, we'll draw overlay in Immediate mode later to keep it simple and ensure it floats
        if (wb.renaming and row_selected) {
            const rename_str = wb.rename_buffer.toDisplayString(true) catch "";
            const duped = alloc.dupe(u8, rename_str) catch "";
            action_overlay = .{ .x = 0, .y = 0, .w = 0, .h = 0, .text = duped }; // will be populated after calculateLayout
        }

        // Git Indicator on far right
        if (is_modified or is_added or is_untracked) {
            var git_node = alloc.create(renderer.layout.Node) catch return;
            git_node.* = renderer.layout.Node.init(alloc);
            git_node.direction = .row;
            git_node.width = 16.0;
            git_node.margin = 4.0;
            row_node.addChild(alloc, git_node) catch return;

            var git_view = alloc.create(renderer.view.View) catch return;
            git_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            git_view.flex_node = git_node;

            if (row.kind == .file) {
                const git_text = if (is_modified) "M" else if (is_added) "A" else "U";
                const git_color = if (is_modified)
                    renderer_theme.getColor("git.modified")
                else
                    renderer_theme.getColor("git.added");
                git_view.data = .{ .label = .{ .text = git_text, .color = git_color, .size = 11.0 } };
            } else {
                // Directory: just a colored background (dot representation)
                const git_color = if (is_modified)
                    renderer_theme.getColor("git.modified")
                else
                    renderer_theme.getColor("git.added");
                git_view.bg_color = git_color;
            }
            row_view.addChild(alloc, git_view) catch return;
        }
    }

    // Calculate Layout
    const tree_y = shared.visibleRowY(explorer_scroll.list_top, wb.explorer_scroll_y, row_h, range.first);
    tree_root_node.calculateLayout(explorer_panel_width, h - tree_y, explorer_x, tree_y);

    // Render Flexbox Tree
    tree_root_view.render();

    // Draw Renaming Overlay on top
    if (action_overlay) |overlay| {
        // We find the selected row's label layout
        if (tree_root_view.children.items.len > 0) {
            for (tree_root_view.children.items) |row_view| {
                if (row_view.bg_color_id) |bg| {
                    if (std.mem.eql(u8, bg, "selection")) {
                        // This is the active row, overlay rename input
                        const label_x = row_view.frame.x + 20.0 + 14.0 + 6.0; // Approximation if node search is too complex
                        // Wait, it's better to just get the row's frame
                        renderer.Renderer.drawRoundedRect(label_x - 4, row_view.frame.y - 2, explorer_panel_width - 32, 18, 3, .{ .r = 0.2, .g = 0.25, .b = 0.35, .a = 1.0 });
                        renderer.Renderer.drawText(overlay.text, label_x, row_view.frame.y, 13.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
                    }
                }
            }
        }
    }
    renderer.Renderer.clearClipRect();
    shared.drawSidebarScrollbar(explorer_x, explorer_panel_width, explorer_scroll.list_top, h, wb.explorer_scroll_y, wb.explorer.entries.len, explorer_scroll.row_height);
}

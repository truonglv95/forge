const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const activity_bar = @import("../../sidebar/activity_bar.zig");
const sidebar_view = @import("../../sidebar/sidebar_view.zig");

pub fn drawActivityBar(wb: *Workbench, w: f32, alloc: std.mem.Allocator) void {
    const theme = &wb.theme;

    // Draw bottom border for activity bar
    renderer.Renderer.drawRect(0, layout.header_height + layout.activity_bar_height - 1, w, 1, shared.color(theme.colors.border));

    var root_node = alloc.create(renderer.layout.Node) catch return;
    root_node.* = renderer.layout.Node.init(alloc);
    root_node.direction = .row;
    root_node.justify = .start;
    root_node.align_items = .center;
    root_node.width = w;
    root_node.height = layout.activity_bar_height;
    // Activity bar needs to align center, we'll use flex_grow spacers
    // root_node.padding = @max(0, (w - total_w) / 2.0); // REMOVED: padding pushes Y axis down as well in this layout engine

    var left_spacer = alloc.create(renderer.layout.Node) catch return;
    left_spacer.* = renderer.layout.Node.init(alloc);
    left_spacer.flex_grow = 1.0;
    root_node.addChild(alloc, left_spacer) catch return;

    var root_view = alloc.create(renderer.view.View) catch return;
    root_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    root_view.flex_node = root_node;
    root_view.theme = state.renderer_theme;
    root_view.bg_color_id = "sidebar.bg";

    for (sidebar_view.all) |view| {
        const selected = wb.sidebar_view == view;
        const color = if (selected)
            renderer.Color{ .r = 1, .g = 1, .b = 1, .a = 1 }
        else
            renderer.Color{ .r = 0.65, .g = 0.65, .b = 0.65, .a = 1 };

        const svg = switch (view) {
            .explorer => renderer.icons.file_directory,
            .search => renderer.icons.search,
            .git => renderer.icons.git_branch,
            .run => renderer.icons.gear,
            .extensions => renderer.icons.plus,
            .ai => renderer.icons.sparkle,
            .outline => renderer.icons.kebab_horizontal,
        };

        var child_node = alloc.create(renderer.layout.Node) catch return;
        child_node.* = renderer.layout.Node.init(alloc);
        child_node.width = activity_bar.icon_w;
        child_node.height = layout.activity_bar_height;
        root_node.addChild(alloc, child_node) catch return;

        var icon_view = alloc.create(renderer.view.View) catch return;
        icon_view.* = renderer.view.View.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
        icon_view.flex_node = child_node;
        icon_view.data = .{ .icon = .{ .svg = svg, .color = color, .size = 16.0 } };

        root_view.addChild(alloc, icon_view) catch return;
    }

    var right_spacer = alloc.create(renderer.layout.Node) catch return;
    right_spacer.* = renderer.layout.Node.init(alloc);
    right_spacer.flex_grow = 1.0;
    root_node.addChild(alloc, right_spacer) catch return;

    // Solve Layout Constraint
    root_node.calculateLayout(w, layout.activity_bar_height, 0, layout.header_height);

    // Recursively Render
    root_view.render();
}

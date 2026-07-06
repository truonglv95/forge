const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const activity_bar = @import("../../sidebar/activity_bar.zig");
const sidebar_view = @import("../../sidebar/sidebar_view.zig");
pub fn drawActivityBar(wb: *Workbench, w: f32) void {
    const theme = &wb.theme;
    const accent = shared.color(theme.colors.accent);

    // Draw bottom border for activity bar
    renderer.Renderer.drawRect(0, layout.header_height + layout.activity_bar_height - 1, w, 1, shared.color(theme.colors.border));

    for (sidebar_view.all) |view| {
        const x = activity_bar.iconX(view);
        const y = layout.header_height;
        const selected = wb.sidebar_view == view;
        if (selected) {
            // Draw top highlight for selected horizontal tab
            renderer.Renderer.drawRect(x + 6, y, activity_bar.icon_w - 12, 2, accent);
        }
        const color = if (selected)
            renderer.Color{ .r = 1, .g = 1, .b = 1, .a = 1 }
        else
            renderer.Color{ .r = 0.65, .g = 0.65, .b = 0.65, .a = 1 };
        const center = activity_bar.iconCenter(view, w);

        const svg = switch (view) {
            .explorer => renderer.icons.file_directory,
            .search => renderer.icons.search,
            .git => renderer.icons.git_branch,
            .run => renderer.icons.gear,
            .extensions => renderer.icons.plus, // placeholder for extensions
            .ai => renderer.icons.sparkle,
        };
        renderer.Renderer.drawSvg(svg, center.x - 8, center.y - 8, 16, 16, color);
    }
}

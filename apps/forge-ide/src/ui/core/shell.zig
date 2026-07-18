const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("state.zig");
const workspace = @import("forge-workspace");

fn allocView(allocator: std.mem.Allocator, frame: renderer.Rect, bg: ?renderer.Color) !*renderer.View {
    const view = try allocator.create(renderer.View);
    view.* = renderer.View.init(frame);
    view.bg_color = bg;
    return view;
}

pub fn initShell(allocator: std.mem.Allocator) !void {
    // Initialize Theme
    const t = try allocator.create(renderer.theme_mod.Theme);
    t.* = renderer.theme_mod.Theme.init(allocator);
    state.renderer_theme = t;

    // Copy resolved defaults from workbench
    if (state.wb) |wb| {
        const c = wb.theme.colors;
        t.colors.put("workbench.bg", .{ .r = c.workbench_bg.r, .g = c.workbench_bg.g, .b = c.workbench_bg.b, .a = c.workbench_bg.a }) catch {};
        t.colors.put("header.bg", .{ .r = c.header_bg.r, .g = c.header_bg.g, .b = c.header_bg.b, .a = c.header_bg.a }) catch {};
        t.colors.put("activity.bg", .{ .r = c.activity_bg.r, .g = c.activity_bg.g, .b = c.activity_bg.b, .a = c.activity_bg.a }) catch {};
        t.colors.put("sidebar.bg", .{ .r = c.sidebar_bg.r, .g = c.sidebar_bg.g, .b = c.sidebar_bg.b, .a = c.sidebar_bg.a }) catch {};
        t.colors.put("editor.bg", .{ .r = c.editor_bg.r, .g = c.editor_bg.g, .b = c.editor_bg.b, .a = c.editor_bg.a }) catch {};
    }

    t.metrics.put("explorer.header_padding", 8.0) catch {};
    t.metrics.put("explorer.row_height", 24.0) catch {};
    t.metrics.put("explorer.icon_size", 16.0) catch {};

    // Load theme from ~/.forge/theme.toml if exists
    if (workspace.global_store.joinHome(allocator, "theme.toml")) |theme_path| {
        defer allocator.free(theme_path);
        if (state.wb) |wb| {
            if (workspace.global_store.readAbsoluteFile(allocator, wb.io, theme_path)) |content| {
                defer allocator.free(content);
                t.loadFromToml(content);
            } else |_| {}
        }
    } else |_| {}

    const root = try allocView(allocator, .{ .x = 0, .y = 0, .w = 1024, .h = 768 }, .{ .r = 0.117, .g = 0.117, .b = 0.117, .a = 1.0 });
    state.root_view = root;

    state.header_view = try allocView(allocator, .{ .x = 0, .y = 0, .w = 1024, .h = 30 }, .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 });
    try root.addChild(allocator, state.header_view.?);

    state.activity_view = try allocView(allocator, .{ .x = 0, .y = 30, .w = 50, .h = 716 }, .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 });
    try root.addChild(allocator, state.activity_view.?);

    state.explorer_view = try allocView(allocator, .{ .x = 50, .y = 30, .w = 250, .h = 716 }, .{ .r = 0.125, .g = 0.125, .b = 0.13, .a = 1.0 });
    try root.addChild(allocator, state.explorer_view.?);

    state.editor_view = try allocView(allocator, .{ .x = 300, .y = 30, .w = 344, .h = 500 }, .{ .r = 0.117, .g = 0.117, .b = 0.117, .a = 1.0 });
    try root.addChild(allocator, state.editor_view.?);

    state.panel_view = try allocView(allocator, .{ .x = 300, .y = 530, .w = 344, .h = 216 }, .{ .r = 0.117, .g = 0.117, .b = 0.117, .a = 1.0 });
    try root.addChild(allocator, state.panel_view.?);

    state.border_view = try allocView(allocator, .{ .x = 300, .y = 530, .w = 344, .h = 1 }, .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 });
    try state.panel_view.?.addChild(allocator, state.border_view.?);

    state.agent_view = try allocView(allocator, .{ .x = 644, .y = 30, .w = 380, .h = 716 }, .{ .r = 0.145, .g = 0.145, .b = 0.15, .a = 1.0 });
    try root.addChild(allocator, state.agent_view.?);

    state.status_view = try allocView(allocator, .{ .x = 0, .y = 746, .w = 1024, .h = 22 }, .{ .r = 0.0, .g = 0.48, .b = 0.8, .a = 1.0 });
    try root.addChild(allocator, state.status_view.?);
}

pub fn runRenderer() void {
    renderer.Renderer.init();
    renderer.Renderer.setRenderCallback(@import("../render/frame.zig").onRenderFrame);
    renderer.Renderer.setKeyCallback(@import("../input/input.zig").onKeyEvent);
    renderer.Renderer.setMouseCallback(@import("../input/input.zig").onMouseEvent);
    renderer.Renderer.setImeCompositionCallback(@import("../input/input.zig").onImeCompositionEvent);
    renderer.Renderer.createWindow("Forge", 1024, 768);
    renderer.Renderer.requestRedraw();
    renderer.Renderer.run();
}

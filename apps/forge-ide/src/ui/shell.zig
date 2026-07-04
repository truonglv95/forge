const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("state.zig");

fn allocView(allocator: std.mem.Allocator, frame: renderer.Rect, bg: ?renderer.Color) !*renderer.View {
    const view = try allocator.create(renderer.View);
    view.* = renderer.View.init(frame);
    view.bg_color = bg;
    return view;
}

pub fn initShell(allocator: std.mem.Allocator) !void {
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
    renderer.Renderer.setRenderCallback(@import("render.zig").onRenderFrame);
    renderer.Renderer.setKeyCallback(@import("input.zig").onKeyEvent);
    renderer.Renderer.setMouseCallback(@import("input.zig").onMouseEvent);
    renderer.Renderer.createWindow("Forge", 1024, 768);
    renderer.Renderer.run();
}

const std = @import("std");
const root = @import("root.zig");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const ViewData = union(enum) {
    none: void,
    icon: struct { svg: [:0]const u8, color: Color, size: f32 },
    label: struct { text: []const u8, color: Color, size: f32 },
};

pub const View = struct {
    flex_node: ?*root.layout.Node = null,
    bg_color_id: ?[]const u8 = null,
    theme: ?*const root.theme_mod.Theme = null,
    frame: Rect,
    bg_color: ?Color = null,
    data: ViewData = .{ .none = {} },
    children: std.ArrayList(*View),

    pub fn init(frame: Rect) View {
        return .{
            .frame = frame,
            .children = .empty,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
    }

    pub fn addChild(self: *View, allocator: std.mem.Allocator, child: *View) !void {
        try self.children.append(allocator, child);
    }

    pub fn render(self: *const View) void {
        var render_x = self.frame.x;
        var render_y = self.frame.y;
        var render_w = self.frame.w;
        var render_h = self.frame.h;

        if (self.flex_node) |node| {
            render_x = node.layout_x;
            render_y = node.layout_y;
            render_w = node.layout_w;
            render_h = node.layout_h;
        }

        var color_to_draw = self.bg_color;
        if (self.bg_color_id) |id| {
            if (self.theme) |t| {
                color_to_draw = t.getColor(id);
            }
        }

        if (color_to_draw) |color| {
            root.Renderer.drawRect(
                render_x,
                render_y,
                render_w,
                render_h,
                color,
            );
        }

        switch (self.data) {
            .none => {},
            .icon => |icon| {
                const center_x = render_x + (render_w / 2.0);
                const center_y = render_y + (render_h / 2.0);
                root.Renderer.drawSvg(
                    icon.svg,
                    center_x - (icon.size / 2.0),
                    center_y - (icon.size / 2.0),
                    icon.size,
                    icon.size,
                    icon.color,
                );
            },
            .label => |label| {
                root.Renderer.drawText(label.text, render_x, render_y, label.size, label.color);
            },
        }

        for (self.children.items) |child| {
            child.render();
        }
    }
};

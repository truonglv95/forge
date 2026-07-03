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

pub const View = struct {
    frame: Rect,
    bg_color: ?Color = null,
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
        if (self.bg_color) |color| {
            root.Renderer.drawRect(
                self.frame.x,
                self.frame.y,
                self.frame.w,
                self.frame.h,
                color,
            );
        }

        for (self.children.items) |child| {
            child.render();
        }
    }
};

pub const LabelView = struct {
    view: View,
    text: []const u8,
    text_color: Color,
    font_size: f32,

    pub fn init(frame: Rect, text: []const u8) LabelView {
        return .{
            .view = View.init(frame),
            .text = text,
            .text_color = .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 },
            .font_size = 14.0,
        };
    }

    pub fn render(self: *const LabelView) void {
        // Draw background and children
        self.view.render();

        // Draw Text
        root.Renderer.drawText(self.text, self.view.frame.x, self.view.frame.y, self.font_size, self.text_color);
    }
};

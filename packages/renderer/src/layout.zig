const std = @import("std");

pub const Direction = enum { row, column };
pub const Justify = enum { start, center, end, space_between };
pub const Align = enum { start, center, end, stretch };

pub const Node = struct {
    direction: Direction = .column,
    justify: Justify = .start,
    align_items: Align = .stretch,

    // Constraints
    width: ?f32 = null,
    height: ?f32 = null,
    flex_grow: f32 = 0,

    padding: f32 = 0,
    margin: f32 = 0,

    // Calculated Layout Output
    layout_x: f32 = 0,
    layout_y: f32 = 0,
    layout_w: f32 = 0,
    layout_h: f32 = 0,

    children: std.ArrayList(*Node),

    pub fn init(allocator: std.mem.Allocator) Node {
        _ = allocator;
        return .{
            .children = .empty,
        };
    }

    pub fn deinit(self: *Node) void {
        self.children.deinit();
    }

    pub fn addChild(self: *Node, allocator: std.mem.Allocator, child: *Node) !void {
        try self.children.append(allocator, child);
    }

    // A highly simplified flex layout solver
    pub fn calculateLayout(self: *Node, available_w: f32, available_h: f32, start_x: f32, start_y: f32) void {
        self.layout_x = start_x + self.margin;
        self.layout_y = start_y + self.margin;

        const w = if (self.width) |w_val| w_val else available_w - (self.margin * 2);
        const h = if (self.height) |h_val| h_val else available_h - (self.margin * 2);

        self.layout_w = w;
        self.layout_h = h;

        const content_w = w - (self.padding * 2);
        const content_h = h - (self.padding * 2);

        if (self.children.items.len == 0) return;

        if (self.direction == .column) {
            var total_fixed_h: f32 = 0;
            var total_flex: f32 = 0;

            for (self.children.items) |child| {
                if (child.flex_grow == 0) {
                    const ch = if (child.height) |ch_val| ch_val else 0;
                    total_fixed_h += ch + (child.margin * 2);
                } else {
                    total_flex += child.flex_grow;
                }
            }

            const remaining_h = @max(0, content_h - total_fixed_h);
            var current_y = self.layout_y + self.padding;

            for (self.children.items) |child| {
                const child_avail_w = content_w;
                var child_avail_h: f32 = 0;

                if (child.flex_grow > 0) {
                    child_avail_h = (child.flex_grow / total_flex) * remaining_h;
                } else {
                    child_avail_h = if (child.height) |ch_val| ch_val else 0;
                    child_avail_h += child.margin * 2;
                }

                child.calculateLayout(child_avail_w, child_avail_h, self.layout_x + self.padding, current_y);
                current_y += child.layout_h + (child.margin * 2);
            }
        } else {
            // Row direction
            var total_fixed_w: f32 = 0;
            var total_flex: f32 = 0;

            for (self.children.items) |child| {
                if (child.flex_grow == 0) {
                    const cw = if (child.width) |cw_val| cw_val else 0;
                    total_fixed_w += cw + (child.margin * 2);
                } else {
                    total_flex += child.flex_grow;
                }
            }

            const remaining_w = @max(0, content_w - total_fixed_w);
            var current_x = self.layout_x + self.padding;

            for (self.children.items) |child| {
                const child_avail_h = content_h;
                var child_avail_w: f32 = 0;

                if (child.flex_grow > 0) {
                    child_avail_w = (child.flex_grow / total_flex) * remaining_w;
                } else {
                    child_avail_w = if (child.width) |cw_val| cw_val else 0;
                    child_avail_w += child.margin * 2;
                }

                child.calculateLayout(child_avail_w, child_avail_h, current_x, self.layout_y + self.padding);
                current_x += child.layout_w + (child.margin * 2);
            }
        }
    }
};

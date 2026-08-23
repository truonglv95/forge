//! Layout engine for Forge TUI
//! Supports FlexBox and Grid layouts

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Rectangle geometry
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,

    pub fn area(self: Rect) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and x < self.x + @as(i32, self.width) and
            y >= self.y and y < self.y + @as(i32, self.height);
    }

    pub fn intersect(self: Rect, other: Rect) ?Rect {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.x + @as(i32, self.width), other.x + @as(i32, other.width));
        const y2 = @min(self.y + @as(i32, self.height), other.y + @as(i32, other.height));

        if (x1 >= x2 or y1 >= y2) return null;

        return Rect{
            .x = x1,
            .y = y1,
            .width = @intCast(x2 - x1),
            .height = @intCast(y2 - y1),
        };
    }
};

/// Size constraint for layout
pub const Constraint = union(enum) {
    fixed: u16,
    percentage: f32,
    min: u16,
    max: u16,
    fill: u16, // Weight for filling remaining space

    pub fn resolve(self: Constraint, available: u16) u16 {
        return switch (self) {
            .fixed => |v| v,
            .percentage => |p| @intFromFloat(@as(f32, available) * p / 100.0),
            .min => |v| if (available < v) available else v,
            .max => |v| if (available > v) v else available,
            .fill => |_| 0, // Resolved in context of siblings
        };
    }
};

/// Flexbox direction
pub const Direction = enum {
    horizontal,
    vertical,
};

/// Flexbox layout configuration
pub const FlexConfig = struct {
    direction: Direction = .vertical,
    padding: Rect = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    gap: u16 = 0,
};

/// Flexbox item
pub const FlexItem = struct {
    constraint: Constraint = .{ .fill = 1 },
    min_size: ?u16 = null,
    max_size: ?u16 = null,
};

/// FlexBox layout engine
pub const FlexBox = struct {
    config: FlexConfig,
    children: std.ArrayList(FlexItem),
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: FlexConfig) FlexBox {
        return .{
            .config = config,
            .children = std.ArrayList(FlexItem).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FlexBox) void {
        self.children.deinit();
    }

    pub fn addItem(self: *FlexBox, item: FlexItem) !void {
        try self.children.append(item);
    }

    pub fn calculate(self: *const FlexBox, rect: Rect) []Rect {
        var result = std.ArrayList(Rect).init(self.allocator);
        defer result.deinit();

        const inner = Rect{
            .x = rect.x + @intCast(self.config.padding.x),
            .y = rect.y + @intCast(self.config.padding.y),
            .width = rect.width - @intCast(self.config.padding.x * 2),
            .height = rect.height - @intCast(self.config.padding.y * 2),
        };

        if (self.children.items.len == 0) return result.toOwnedSlice();

        // Calculate total fill weight
        var total_fill: u16 = 0;
        var used_space: u16 = 0;

        for (self.children.items) |item| {
            switch (item.constraint) {
                .fill => |w| total_fill += w,
                else => {},
            }
        }

        const available_space = if (self.config.direction == .horizontal) inner.width else inner.height;
        const gaps_space = if (self.children.items.len > 0) (self.children.items.len - 1) * self.config.gap else 0;
        const distributable_space = if (available_space > gaps_space) available_space - gaps_space else 0;

        // First pass: calculate fixed/percentage sizes
        for (self.children.items) |item| {
            const size = item.constraint.resolve(distributable_space);
            used_space += size;
        }

        // Second pass: distribute remaining space to fill items
        const remaining = if (distributable_space > used_space) distributable_space - used_space else 0;
        var current_pos: u16 = 0;

        for (self.children.items, 0..) |item, i| {
            var size = item.constraint.resolve(distributable_space);

            if (item.constraint == .fill) {
                const fill_weight = item.constraint.fill;
                if (total_fill > 0) {
                    size = @intCast((@as(u32, remaining) * fill_weight) / total_fill);
                }
            }

            // Apply min/max constraints
            if (item.min_size) |min| {
                if (size < min) size = min;
            }
            if (item.max_size) |max| {
                if (size > max) size = max;
            }

            const child_rect = switch (self.config.direction) {
                .horizontal => Rect{
                    .x = inner.x + @as(i32, current_pos),
                    .y = inner.y,
                    .width = size,
                    .height = inner.height,
                },
                .vertical => Rect{
                    .x = inner.x,
                    .y = inner.y + @as(i32, current_pos),
                    .width = inner.width,
                    .height = size,
                },
            };

            result.append(child_rect) catch break;
            current_pos += size + self.config.gap;
        }

        return result.toOwnedSlice();
    }
};

/// Grid configuration
pub const GridConfig = struct {
    columns: u16,
    rows: u16,
    column_gap: u16 = 0,
    row_gap: u16 = 0,
    padding: u16 = 0,
};

/// Grid layout engine
pub const Grid = struct {
    config: GridConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: GridConfig) Grid {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn getCell(self: *const Grid, rect: Rect, col: u16, row: u16) Rect {
        const inner_width = rect.width - (self.config.padding * 2);
        const inner_height = rect.height - (self.config.padding * 2);

        const total_col_gap = self.config.column_gap * (self.config.columns - 1);
        const total_row_gap = self.config.row_gap * (self.config.rows - 1);

        const col_width = (inner_width - total_col_gap) / self.config.columns;
        const row_height = (inner_height - total_row_gap) / self.config.rows;

        const x = rect.x + self.config.padding + @as(i32, col) * (@as(i32, col_width) + @as(i32, self.config.column_gap));
        const y = rect.y + self.config.padding + @as(i32, row) * (@as(i32, row_height) + @as(i32, self.config.row_gap));

        return Rect{
            .x = x,
            .y = y,
            .width = col_width,
            .height = row_height,
        };
    }
};

test "rect intersection" {
    const r1 = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const r2 = Rect{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const intersection = r1.intersect(r2).?;
    try std.testing.expectEqual(@as(i32, 5), intersection.x);
    try std.testing.expectEqual(@as(i32, 5), intersection.y);
    try std.testing.expectEqual(@as(u16, 5), intersection.width);
    try std.testing.expectEqual(@as(u16, 5), intersection.height);
}

test "flexbox layout" {
    var fb = FlexBox.init(std.testing.allocator, .{
        .direction = .horizontal,
        .gap = 1,
    });
    defer fb.deinit();
    try fb.addItem(.{ .constraint = .{ .fixed = 10 } });
    try fb.addItem(.{ .constraint = .{ .fill = 1 } });

    const rect = Rect{ .x = 0, .y = 0, .width = 50, .height = 20 };
    const results = fb.calculate(rect);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
}

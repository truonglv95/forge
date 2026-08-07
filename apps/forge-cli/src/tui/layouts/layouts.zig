//! Layout System for Forge TUI
//! 
//! Provides flexible layout components: FlexBox, Grid, and constraint-based layouts.

const std = @import("std");
const theme = @import("../theme/theme.zig");

/// Dimension constraints
pub const Constraint = union(enum) {
    fixed: u16,
    percentage: u8, // 0-100
    min: u16,
    max: u16,
    fill: u16, // flex weight
    
    pub fn resolve(self: Constraint, available: u16) u16 {
        return switch (self) {
            .fixed => |v| v,
            .percentage => |p| @as(u16, @intCast((@as(u32, available) * p) / 100)),
            .min => |v| if (available < v) available else v,
            .max => |v| if (available > v) v else available,
            .fill => |_| available, // resolved by flexbox
        };
    }
};

/// Direction for flex layouts
pub const Direction = enum {
    horizontal,
    vertical,
};

/// Alignment options
pub const Alignment = enum {
    start,
    center,
    end,
    stretch,
};

/// Layout configuration
pub const LayoutConfig = struct {
    direction: Direction = .vertical,
    padding_top: u16 = 0,
    padding_right: u16 = 0,
    padding_bottom: u16 = 0,
    padding_left: u16 = 0,
    gap: u16 = 0,
    align_main: Alignment = .start,
    align_cross: Alignment = .stretch,
};

/// A rectangular area in the terminal
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn area(self: Rect) u32 {
        return @as(u32, self.width) * self.height;
    }

    pub fn contains(self: Rect, px: u16, py: u16) bool {
        return px >= self.x and px < self.x + self.width and
               py >= self.y and py < self.y + self.height;
    }

    pub fn shrink(self: Rect, amount: u16) Rect {
        if (amount * 2 >= self.width or amount * 2 >= self.height) {
            return .{ .x = self.x, .y = self.y, .width = 0, .height = 0 };
        }
        return .{
            .x = self.x + amount,
            .y = self.y + amount,
            .width = self.width - amount * 2,
            .height = self.height - amount * 2,
        };
    }

    pub fn offset(self: Rect, dx: i16, dy: i16) Rect {
        const new_x = if (dx < 0) 0 else @as(u16, @intCast(@as(i32, self.x) + dx));
        const new_y = if (dy < 0) 0 else @as(u16, @intCast(@as(i32, self.y) + dy));
        return .{
            .x = new_x,
            .y = new_y,
            .width = self.width,
            .height = self.height,
        };
    }
};

/// FlexBox child item
pub const FlexItem = struct {
    constraint: Constraint = .{ .fill = 1 },
    min_size: ?Rect = null,
    max_size: ?Rect = null,
    align: ?Alignment = null,
    
    /// The content to render in this item
    content: anytype = undefined,
};

/// FlexBox layout engine
pub const FlexBox = struct {
    config: LayoutConfig,
    items: std.ArrayList(FlexItem),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: LayoutConfig) FlexBox {
        return .{
            .config = config,
            .items = std.ArrayList(FlexItem).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FlexBox) void {
        self.items.deinit();
    }

    pub fn addItem(self: *FlexBox, item: FlexItem) !void {
        try self.items.append(item);
    }

    pub fn calculate(self: *FlexBox, available: Rect) []Rect {
        var result = std.ArrayList(Rect).init(self.allocator);
        
        const total_gap = if (self.items.items.len > 0) 
            self.config.gap * (@as(u32, self.items.items.len) - 1) 
        else 0;
        
        const main_size = switch (self.config.direction) {
            .horizontal => available.width -| total_gap,
            .vertical => available.height -| total_gap,
        };
        
        // Calculate flex weights
        var total_weight: u32 = 0;
        for (self.items.items) |item| {
            if (item.constraint == .fill) {
                total_weight += item.constraint.fill;
            }
        }
        
        var current_pos: u16 = 0;
        for (self.items.items) |item| {
            const item_size = switch (item.constraint) {
                .fixed => |v| v,
                .percentage => |p| @as(u16, @intCast((main_size * p) / 100)),
                .min => |v| if (main_size < v) main_size else v,
                .max => |v| if (main_size > v) v else main_size,
                .fill => |w| if (total_weight > 0) 
                    @as(u16, @intCast((main_size * w) / total_weight)) 
                else main_size / self.items.items.len,
            };
            
            const rect = switch (self.config.direction) {
                .horizontal => Rect{
                    .x = available.x + current_pos,
                    .y = available.y,
                    .width = item_size,
                    .height = available.height,
                },
                .vertical => Rect{
                    .x = available.x,
                    .y = available.y + current_pos,
                    .width = available.width,
                    .height = item_size,
                },
            };
            
            result.append(rect) catch break;
            current_pos += item_size + self.config.gap;
        }
        
        return result.toOwnedSlice() catch &.{};
    }
};

/// Grid cell definition
pub const GridCell = struct {
    col_start: u16,
    col_end: u16,
    row_start: u16,
    row_end: u16,
    content: anytype = undefined,
};

/// Grid layout engine
pub const Grid = struct {
    columns: u16,
    rows: u16,
    col_widths: []Constraint,
    row_heights: []Constraint,
    cells: std.ArrayList(GridCell),
    allocator: std.mem.Allocator,
    gap: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) Grid {
        const col_widths = allocator.alloc(Constraint, cols) catch &.{};
        const row_heights = allocator.alloc(Constraint, rows) catch &.{};
        
        // Default to equal distribution
        for (col_widths) |*c| c.* = .{ .fill = 1 };
        for (row_heights) |*r| r.* = .{ .fill = 1 };
        
        return .{
            .columns = cols,
            .rows = rows,
            .col_widths = col_widths,
            .row_heights = row_heights,
            .cells = std.ArrayList(GridCell).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.col_widths);
        self.allocator.free(self.row_heights);
        self.cells.deinit();
    }

    pub fn setColumnWidth(self: *Grid, index: u16, constraint: Constraint) void {
        if (index < self.columns) {
            self.col_widths[index] = constraint;
        }
    }

    pub fn setRowHeight(self: *Grid, index: u16, constraint: Constraint) void {
        if (index < self.rows) {
            self.row_heights[index] = constraint;
        }
    }

    pub fn addCell(self: *Grid, cell: GridCell) !void {
        try self.cells.append(cell);
    }

    pub fn calculate(self: *Grid, available: Rect) [][]Rect {
        _ = available;
        // Simplified grid calculation
        var result = std.ArrayList([]Rect).init(self.allocator);
        return result.toOwnedSlice() catch &.{};
    }
};

/// Main Layout type (union of layout strategies)
pub const Layout = union(enum) {
    flex: *FlexBox,
    grid: *Grid,
    stack: void, // Layers components on top of each other
    custom: *const fn (Rect) []Rect,

    pub fn calculate(self: Layout, available: Rect) []Rect {
        return switch (self) {
            .flex => |fb| fb.calculate(available),
            .grid => |g| g.calculate(available),
            .stack => [_]Rect{available}[0..],
            .custom => |fn_ptr| fn_ptr(available),
        };
    }
};

test "Rect operations" {
    const rect = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    try std.testing.expectEqual(@as(u32, 1920), rect.area());
    try std.testing.expect(rect.contains(40, 12));
    try std.testing.expect(!rect.contains(80, 24));
}

test "FlexBox basic layout" {
    const allocator = std.testing.allocator;
    var fb = FlexBox.init(allocator, .{ .direction = .horizontal });
    defer fb.deinit();
    
    try fb.addItem(.{ .constraint = .{ .fixed = 20 } });
    try fb.addItem(.{ .constraint = .{ .fill = 1 } });
    
    const rects = fb.calculate(.{ .x = 0, .y = 0, .width = 100, .height = 24 });
    defer allocator.free(rects);
    
    try std.testing.expectEqual(@as(usize, 2), rects.len);
}

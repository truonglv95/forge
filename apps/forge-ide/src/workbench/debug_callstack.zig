const std = @import("std");
const debug_stop = @import("debug_stop.zig");
const panel_scroll = @import("../ui/core/panel_scroll.zig");

pub const Frame = struct {
    index: usize,
    label: []const u8,
    path: []const u8,
    line: usize,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Frame),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
    }

    pub fn clear(self: *Store) void {
        for (self.items.items) |*frame| frame.deinit(self.allocator);
        self.items.clearRetainingCapacity();
    }

    pub fn addFrame(self: *Store, parsed: ParsedFrame) !void {
        if (parsed.index == 0) self.clear();
        for (self.items.items, 0..) |*existing, idx| {
            if (existing.index == parsed.index) {
                existing.deinit(self.allocator);
                _ = self.items.orderedRemove(idx);
                break;
            }
        }
        try self.items.append(self.allocator, .{
            .index = parsed.index,
            .label = try self.allocator.dupe(u8, parsed.label),
            .path = try self.allocator.dupe(u8, parsed.path),
            .line = parsed.line,
        });
    }
};

pub const ParsedFrame = struct {
    index: usize,
    label: []const u8,
    path: []const u8,
    line: usize,
};

pub fn parseFrameLine(line: []const u8) ?ParsedFrame {
    if (!std.mem.startsWith(u8, line, "frame #")) return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const index_str = std.mem.trim(u8, line["frame #".len..colon], " ");
    const index = std.fmt.parseInt(usize, index_str, 10) catch return null;

    const loc = debug_stop.parseStopLine(line) orelse return null;
    const at = std.mem.lastIndexOf(u8, line, " at ") orelse return null;
    const label = std.mem.trim(u8, line[colon + 1 .. at], " ");
    if (label.len == 0) return null;

    return .{
        .index = index,
        .label = label,
        .path = loc.path,
        .line = loc.line,
    };
}

pub fn hitTest(
    editor_x: f32,
    panel_y: f32,
    panel_h: f32,
    x: f32,
    y: f32,
    scroll_y: f32,
    item_count: usize,
) ?usize {
    const header_h: f32 = 16;
    const top = panel_y + panel_scroll.bottom_content_top + header_h;
    const viewport = panel_scroll.bottomViewportHeight(panel_h) - header_h;
    if (x < editor_x or y < top or y >= top + viewport) return null;

    const float_line = (y - top + scroll_y) / panel_scroll.bottom_line_h;
    if (float_line < 0) return null;
    const line: usize = @intFromFloat(float_line);
    if (line >= item_count) return null;
    return line;
}

test "parseFrameLine reads lldb backtrace row" {
    const line = "frame #1: 0x100003f20 forge`main at apps/forge-ide/src/main.zig:42:5";
    const parsed = parseFrameLine(line).?;
    try std.testing.expectEqual(@as(usize, 1), parsed.index);
    try std.testing.expectEqualStrings("apps/forge-ide/src/main.zig", parsed.path);
    try std.testing.expectEqual(@as(usize, 41), parsed.line);
}

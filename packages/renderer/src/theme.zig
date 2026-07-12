const std = @import("std");
const root = @import("root.zig");

pub const Theme = struct {
    colors: std.StringHashMap(root.Color),
    metrics: std.StringHashMap(f32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Theme {
        var colors = std.StringHashMap(root.Color).init(allocator);
        var metrics = std.StringHashMap(f32).init(allocator);
        metrics.put("dummy", 0) catch {}; // prevent unused var error
        // Default fallbacks
        colors.put("bg", hex(0x1e1e1e)) catch unreachable;
        colors.put("fg", hex(0xd4d4d4)) catch unreachable;
        colors.put("primary", hex(0x007acc)) catch unreachable;
        colors.put("border", hex(0x333333)) catch unreachable;

        return .{
            .colors = colors,
            .metrics = metrics,
            .allocator = allocator,
        };
    }

    pub fn loadFromToml(self: *Theme, content: []const u8) void {
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
                raw_line[0..index]
            else
                raw_line;
            const line = std.mem.trim(u8, &std.ascii.whitespace, without_comment);
            if (line.len == 0) continue;

            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') continue;
                section = std.mem.trim(u8, &std.ascii.whitespace, line[1 .. line.len - 1]);
                continue;
            }

            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, &std.ascii.whitespace, line[0..equals]);
            var value = std.mem.trim(u8, &std.ascii.whitespace, line[equals + 1 ..]);

            // Remove quotes if present
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[0] == value[value.len - 1]) {
                value = value[1 .. value.len - 1];
            }

            if (std.mem.eql(u8, section, "colors")) {
                // Parse hex color like #1e1e1e or 1e1e1e
                var hex_str = value;
                if (hex_str.len > 0 and hex_str[0] == '#') {
                    hex_str = hex_str[1..];
                }
                const parsed_hex = std.fmt.parseInt(u32, hex_str, 16) catch continue;
                // Duplicate key since line slices are temporary if file is freed
                const key_dupe = self.allocator.dupe(u8, key) catch continue;
                self.colors.put(key_dupe, hex(parsed_hex)) catch {};
            } else if (std.mem.eql(u8, section, "metrics")) {
                const parsed_f32 = std.fmt.parseFloat(f32, value) catch continue;
                const key_dupe = self.allocator.dupe(u8, key) catch continue;
                self.metrics.put(key_dupe, parsed_f32) catch {};
            }
        }
    }

    pub fn deinit(self: *Theme) void {
        self.colors.deinit();
        self.metrics.deinit();
    }

    pub fn getMetric(self: *const Theme, id: []const u8, default_val: f32) f32 {
        if (self.metrics.get(id)) |v| return v;
        return default_val;
    }

    pub fn getColor(self: *const Theme, id: []const u8) root.Color {
        if (self.colors.get(id)) |c| return c;
        return hex(0xff00ff); // Magenta for missing color
    }
};

fn hex(h: u32) root.Color {
    return .{
        .r = @as(f32, @floatFromInt((h >> 16) & 0xFF)) / 255.0,
        .g = @as(f32, @floatFromInt((h >> 8) & 0xFF)) / 255.0,
        .b = @as(f32, @floatFromInt(h & 0xFF)) / 255.0,
        .a = 1.0,
    };
}

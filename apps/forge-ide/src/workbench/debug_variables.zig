const std = @import("std");

pub const Entry = struct {
    type_name: []const u8,
    name: []const u8,
    value: []const u8,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
        allocator.free(self.name);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
    }

    pub fn clear(self: *Store) void {
        for (self.items.items) |*entry| entry.deinit(self.allocator);
        self.items.clearRetainingCapacity();
    }

    pub fn addParsed(self: *Store, parsed: ParsedLine) !void {
        try self.items.append(self.allocator, .{
            .type_name = try self.allocator.dupe(u8, parsed.type_name),
            .name = try self.allocator.dupe(u8, parsed.name),
            .value = try self.allocator.dupe(u8, parsed.value),
        });
    }
};

pub const ParsedLine = struct {
    type_name: []const u8,
    name: []const u8,
    value: []const u8,
};

pub fn parseVariableLine(line: []const u8) ?ParsedLine {
    if (line.len == 0 or line[0] != '(') return null;
    const close_paren = std.mem.indexOfScalar(u8, line, ')') orelse return null;
    const type_name = std.mem.trim(u8, line[1..close_paren], " ");
    if (type_name.len == 0) return null;

    const rest = std.mem.trim(u8, line[close_paren + 1 ..], " ");
    const eq = std.mem.indexOf(u8, rest, " = ") orelse return null;
    const name = std.mem.trim(u8, rest[0..eq], " ");
    const value = std.mem.trim(u8, rest[eq + 3 ..], " ");
    if (name.len == 0 or value.len == 0) return null;

    return .{ .type_name = type_name, .name = name, .value = value };
}

test "parseVariableLine reads lldb locals" {
    const parsed = parseVariableLine("(i32) count = 42").?;
    try std.testing.expectEqualStrings("i32", parsed.type_name);
    try std.testing.expectEqualStrings("count", parsed.name);
    try std.testing.expectEqualStrings("42", parsed.value);
}

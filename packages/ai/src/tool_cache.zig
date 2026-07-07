const std = @import("std");

/// Session-scoped cache for idempotent read/search tool results.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Cache, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    pub fn put(self: *Cache, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const gop = try self.entries.getOrPut(owned_key);
        if (gop.found_existing) {
            self.allocator.free(owned_key);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = owned_value;
        } else {
            gop.value_ptr.* = owned_value;
        }
    }

    pub fn makeKey(allocator: std.mem.Allocator, tool: []const u8, args_json: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ tool, args_json });
    }
};

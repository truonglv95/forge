const std = @import("std");
const forge_util = @import("forge-util");

pub const ContextCache = struct {
    allocator: std.mem.Allocator,
    mutex: forge_util.sync.Mutex = .{},
    entries: std.StringHashMap(Entry),

    pub const Entry = struct {
        mtime: i128,
        preview: ?[]const u8 = null,
        imports: ?[][]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) ContextCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *ContextCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.preview) |p| self.allocator.free(p);
            if (entry.value_ptr.imports) |arr| {
                for (arr) |p| self.allocator.free(p);
                self.allocator.free(arr);
            }
        }
        self.entries.deinit();
    }
};

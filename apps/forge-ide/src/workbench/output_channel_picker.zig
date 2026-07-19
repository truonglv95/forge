const std = @import("std");
const process_spawn = @import("forge-util").process_spawn;

pub const Entry = struct {
    id: []const u8,
    name: []const u8,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

pub const Picker = struct {
    allocator: std.mem.Allocator,
    query: []u8,
    query_len: usize,
    open: bool = false,
    selected: usize = 0,
    entries: std.ArrayList(Entry),
    filtered: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator) !Picker {
        return .{
            .allocator = allocator,
            .query = try allocator.alloc(u8, 256),
            .query_len = 0,
            .entries = .empty,
            .filtered = .empty,
        };
    }

    pub fn deinit(self: *Picker) void {
        self.clearEntries();
        self.entries.deinit(self.allocator);
        self.filtered.deinit(self.allocator);
        self.allocator.free(self.query);
    }

    pub fn clearEntries(self: *Picker) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
        self.filtered.clearRetainingCapacity();
    }

    pub fn openPicker(self: *Picker) !void {
        self.open = true;
        self.query_len = 0;
        self.selected = 0;
        try self.applyFilter();
    }

    pub fn close(self: *Picker) void {
        self.open = false;
        self.query_len = 0;
    }

    pub fn addChannel(self: *Picker, id: []const u8, name: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
        });
    }

    pub fn applyFilter(self: *Picker) !void {
        self.filtered.clearRetainingCapacity();
        const query_str = std.ascii.allocLowerString(self.allocator, self.query[0..self.query_len]) catch return;
        defer self.allocator.free(query_str);

        for (self.entries.items, 0..) |entry, i| {
            if (query_str.len == 0) {
                try self.filtered.append(self.allocator, i);
                continue;
            }
            const lower_name = std.ascii.allocLowerString(self.allocator, entry.name) catch continue;
            defer self.allocator.free(lower_name);
            if (std.mem.indexOf(u8, lower_name, query_str) != null) {
                try self.filtered.append(self.allocator, i);
            }
        }
        if (self.filtered.items.len > 0 and self.selected >= self.filtered.items.len) {
            self.selected = self.filtered.items.len - 1;
        } else if (self.filtered.items.len == 0) {
            self.selected = 0;
        }
    }

    pub fn insertChar(self: *Picker, chars: []const u8) !void {
        for (chars) |ch| {
            if (self.query_len < self.query.len) {
                self.query[self.query_len] = ch;
                self.query_len += 1;
            }
        }
        self.selected = 0;
        try self.applyFilter();
    }

    pub fn backspace(self: *Picker) !void {
        if (self.query_len > 0) {
            self.query_len -= 1;
            self.selected = 0;
            try self.applyFilter();
        }
    }

    pub fn moveSelection(self: *Picker, offset: isize) void {
        if (self.filtered.items.len == 0) return;
        var next: isize = @as(isize, @intCast(self.selected)) + offset;
        const total: isize = @intCast(self.filtered.items.len);
        if (next < 0) next = total - 1;
        if (next >= total) next = 0;
        self.selected = @intCast(next);
    }
};

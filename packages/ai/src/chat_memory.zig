//! AI Chat Memory — persistent conversation history per workspace.
//! Stores conversation summaries in .forge/memory/ so the agent can
//! recall context from previous sessions.
const std = @import("std");
const workspace = @import("forge-workspace");

pub const MemoryEntry = struct {
    id: u64,
    timestamp: i64,
    role: Role,
    summary: []const u8,
    tags: []const []const u8,
    file_context: ?[]const u8 = null,

    pub const Role = enum {
        user_query,
        agent_response,
        agent_action,
        user_feedback,
    };

    pub fn deinit(self: *MemoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        for (self.tags) |tag| allocator.free(tag);
        allocator.free(self.tags);
        if (self.file_context) |fc| allocator.free(fc);
    }
};

pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(MemoryEntry),
    next_id: u64 = 1,
    /// Maximum number of entries to keep (older ones are evicted).
    max_entries: usize = 100,

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Add a memory entry. Takes ownership of summary and tags.
    pub fn add(self: *MemoryStore, role: MemoryEntry.Role, summary: []const u8, tags: []const []const u8, file_context: ?[]const u8) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        // Copy tags
        const tags_copy = try self.allocator.alloc([]const u8, tags.len);
        for (tags, 0..) |tag, i| {
            tags_copy[i] = try self.allocator.dupe(u8, tag);
        }

        try self.entries.append(self.allocator, .{
            .id = id,
            .timestamp = 0, // Set by caller or persistence layer
            .role = role,
            .summary = try self.allocator.dupe(u8, summary),
            .tags = tags_copy,
            .file_context = if (file_context) |fc| try self.allocator.dupe(u8, fc) else null,
        });

        // Evict old entries if over limit
        if (self.entries.items.len > self.max_entries) {
            var old = self.entries.orderedRemove(0);
            old.deinit(self.allocator);
        }

        return id;
    }

    /// Search memory by keyword (case-insensitive substring match in summary).
    pub fn search(self: *const MemoryStore, query: []const u8, allocator: std.mem.Allocator) ![]const MemoryEntry {
        var results: std.ArrayList(MemoryEntry) = .empty;
        errdefer results.deinit(allocator);

        for (self.entries.items) |entry| {
            if (std.ascii.indexOfIgnoreCase(entry.summary, query) != null) {
                try results.append(allocator, entry);
            }
        }

        return results.toOwnedSlice(allocator);
    }

    /// Get recent N entries.
    pub fn recent(self: *const MemoryStore, count: usize) []const MemoryEntry {
        const start = if (self.entries.items.len > count) self.entries.items.len - count else 0;
        return self.entries.items[start..];
    }

    /// Format memory entries as a context string for the agent.
    /// Only includes entries matching the given tags (or all if tags is empty).
    pub fn formatContext(self: *const MemoryStore, tags: []const []const u8, allocator: std.mem.Allocator, max_chars: usize) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "## Previous Conversation Context\n\n");

        var char_count: usize = 0;
        // Iterate in reverse (most recent first)
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];

            // Filter by tags if provided
            if (tags.len > 0) {
                var has_tag = false;
                for (entry.tags) |entry_tag| {
                    for (tags) |filter_tag| {
                        if (std.mem.eql(u8, entry_tag, filter_tag)) {
                            has_tag = true;
                            break;
                        }
                    }
                    if (has_tag) break;
                }
                if (!has_tag) continue;
            }

            const role_label = switch (entry.role) {
                .user_query => "User asked",
                .agent_response => "Agent replied",
                .agent_action => "Agent did",
                .user_feedback => "User said",
            };

            const line = try std.fmt.allocPrint(allocator, "- [{s}] {s}\n", .{ role_label, entry.summary });
            defer allocator.free(line);

            if (char_count + line.len > max_chars) break;
            try buf.appendSlice(allocator, line);
            char_count += line.len;
        }

        if (char_count == 0) {
            try buf.appendSlice(allocator, "(no relevant previous context)\n");
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Clear all memory.
    pub fn clear(self: *MemoryStore) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }

    /// Serialize to TOML format for persistence.
    pub fn serialize(self: *const MemoryStore, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "# Forge AI Chat Memory\n");
        try buf.appendSlice(allocator, "# This file is auto-generated. Do not edit manually.\n\n");

        for (self.entries.items) |entry| {
            try buf.appendSlice(allocator, "[[memory]]\n");
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "id = {d}\n", .{entry.id}));
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "timestamp = {d}\n", .{entry.timestamp}));
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "role = \"{s}\"\n", .{@tagName(entry.role)}));
            try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "summary = \"{s}\"\n", .{entry.summary}));
            if (entry.file_context) |fc| {
                try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "file = \"{s}\"\n", .{fc}));
            }
            try buf.append(allocator, '\n');
        }

        return buf.toOwnedSlice(allocator);
    }
};

test "MemoryStore add and search" {
    const allocator = std.testing.allocator;
    var store = MemoryStore.init(allocator);
    defer store.deinit();

    const tags = [_][]const u8{"auth"};
    _ = try store.add(.user_query, "How does authentication work?", &tags, "src/auth.zig");
    _ = try store.add(.agent_response, "Authentication uses JWT tokens stored in .forge/auth", &tags, null);
    _ = try store.add(.user_query, "How to add a new endpoint?", &.{}, null);

    try std.testing.expectEqual(@as(usize, 3), store.entries.items.len);

    const results = try store.search("auth", allocator);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "MemoryStore formatContext" {
    const allocator = std.testing.allocator;
    var store = MemoryStore.init(allocator);
    defer store.deinit();

    const tags = [_][]const u8{"bug"};
    _ = try store.add(.user_query, "Fix the null pointer crash", &tags, null);
    _ = try store.add(.agent_response, "Added null check before dereferencing", &tags, null);

    const ctx = try store.formatContext(&.{}, allocator, 1000);
    defer allocator.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "null pointer") != null);
}

test "MemoryStore evicts old entries" {
    const allocator = std.testing.allocator;
    var store = MemoryStore.init(allocator);
    defer store.deinit();
    store.max_entries = 3;

    for (0..5) |i| {
        var buf: [32]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "entry {d}", .{i}) catch "entry";
        _ = try store.add(.user_query, summary, &.{}, null);
    }

    try std.testing.expectEqual(@as(usize, 3), store.entries.items.len);
}

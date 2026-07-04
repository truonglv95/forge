const std = @import("std");
const explorer_tree = @import("../explorer/tree.zig");
const ai = @import("forge-ai");

pub const pinned_codebase = ai.scope_resolver.codebase_marker;
pub const pinned_docs = ai.scope_resolver.docs_marker;
pub const pinned_web = ai.scope_resolver.web_marker;

pub const PinnedEntry = struct {
    marker: []const u8,
    label: []const u8,
    query_hint: []const u8,
};

pub const pinned_entries = [_]PinnedEntry{
    .{ .marker = pinned_codebase, .label = "@codebase  (semantic search)", .query_hint = "codebase" },
    .{ .marker = pinned_docs, .label = "@docs  (project documentation)", .query_hint = "docs" },
    .{ .marker = pinned_web, .label = "@web  (external documentation)", .query_hint = "web" },
};

pub fn collectFilePaths(
    allocator: std.mem.Allocator,
    explorer: *const explorer_tree.Tree,
    out: *std.ArrayList([]const u8),
) !void {
    for (explorer.entries) |entry| {
        switch (entry.kind) {
            .file => try out.append(allocator, try allocator.dupe(u8, entry.path)),
            .directory => {
                var buf: [512]u8 = undefined;
                const scoped = std.fmt.bufPrint(&buf, "{s}{s}", .{ ai.scope_resolver.folder_prefix, entry.path }) catch continue;
                try out.append(allocator, try allocator.dupe(u8, scoped));
            },
            else => {},
        }
    }
}

fn pinnedEntryVisible(query: []const u8, entry: PinnedEntry) bool {
    return query.len == 0 or matchesQuery(query, entry.query_hint) or matchesQuery(query, entry.marker);
}

pub fn pinnedCodebaseVisible(query: []const u8) bool {
    return pinnedEntryVisible(query, pinned_entries[0]);
}

pub fn pinnedVisibleCount(query: []const u8) usize {
    var count: usize = 0;
    for (pinned_entries) |entry| {
        if (pinnedEntryVisible(query, entry)) count += 1;
    }
    return count;
}

pub fn pinnedMarkerAt(query: []const u8, visible_index: usize) ?[]const u8 {
    var seen: usize = 0;
    for (pinned_entries) |entry| {
        if (!pinnedEntryVisible(query, entry)) continue;
        if (seen == visible_index) return entry.marker;
        seen += 1;
    }
    return null;
}

pub fn pinnedLabelAt(query: []const u8, visible_index: usize) ?[]const u8 {
    var seen: usize = 0;
    for (pinned_entries) |entry| {
        if (!pinnedEntryVisible(query, entry)) continue;
        if (seen == visible_index) return entry.label;
        seen += 1;
    }
    return null;
}

pub fn fileListIndex(selected: usize, query: []const u8) ?usize {
    const pinned = pinnedVisibleCount(query);
    if (selected < pinned) return null;
    return selected - pinned;
}

pub fn visibleRowCount(filtered_len: usize, query: []const u8) usize {
    return filtered_len + pinnedVisibleCount(query);
}

pub fn applyFilter(allocator: std.mem.Allocator, query: []const u8, paths: []const []const u8, out: *std.ArrayList(usize)) !void {
    out.clearRetainingCapacity();
    for (paths, 0..) |path, index| {
        if (query.len == 0 or matchesQuery(query, path) or matchesQuery(query, std.fs.path.basename(path))) {
            try out.append(allocator, index);
        }
    }
}

pub fn matchesQuery(query: []const u8, haystack: []const u8) bool {
    if (query.len == 0) return true;
    var h_index: usize = 0;
    for (query) |q| {
        const lower_q = std.ascii.toLower(q);
        while (h_index < haystack.len) : (h_index += 1) {
            if (std.ascii.toLower(haystack[h_index]) == lower_q) {
                h_index += 1;
                break;
            }
        } else return false;
    }
    return true;
}

test "scope picker fuzzy matches path" {
    const paths = [_][]const u8{ "apps/forge-ide/src/main.zig", "README.md" };
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(std.testing.allocator);
    try applyFilter(std.testing.allocator, "main", &paths, &indices);
    try std.testing.expectEqual(@as(usize, 1), indices.items.len);
    try std.testing.expectEqual(@as(usize, 0), indices.items[0]);
}

test "pinned docs visible when query matches docs" {
    try std.testing.expect(pinnedVisibleCount("docs") >= 1);
    try std.testing.expectEqualStrings(pinned_docs, pinnedMarkerAt("docs", 0).?);
}

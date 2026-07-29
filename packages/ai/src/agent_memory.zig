const std = @import("std");
const workspace = @import("forge-workspace");
const context_retrieval = @import("context_retrieval.zig");

pub const SelectOptions = struct {
    max_entries: usize = 8,
    max_entry_chars: usize = 512,
};

pub const ScoredEntry = struct {
    entry: workspace.agent_memory.Entry,
    score: f32,
    detail: []const u8,
};

pub fn selectForIntent(
    allocator: std.mem.Allocator,
    entries: []const workspace.agent_memory.Entry,
    intent: ?[]const u8,
    options: SelectOptions,
) ![]ScoredEntry {
    if (entries.len == 0) return &.{};

    var intent_terms: []const []const u8 = &.{};
    if (intent) |text| {
        intent_terms = context_retrieval.intentTerms(allocator, text, 6) catch &[_][]const u8{};
    }
    defer if (intent_terms.len > 0) context_retrieval.freeIntentTerms(allocator, intent_terms);

    var scored: std.ArrayList(ScoredEntry) = .empty;
    errdefer {
        for (scored.items) |item| allocator.free(item.detail);
        scored.deinit(allocator);
    }

    var newest_ms: i64 = 1;
    for (entries) |entry| newest_ms = @max(newest_ms, entry.updated_ms);

    for (entries) |entry| {
        const overlap = contentTermOverlap(entry.content, intent_terms) + tagTermOverlap(entry.tags, intent_terms);
        const recency = if (newest_ms > 0)
            @as(f32, @floatFromInt(entry.updated_ms)) / @as(f32, @floatFromInt(newest_ms))
        else
            0.5;
        const score = overlap * 3.0 + recency;

        const detail = if (intent != null and overlap > 0.01)
            try std.fmt.allocPrint(allocator, "relevance {d:.2} + recency {d:.2}", .{ overlap * 3.0, recency })
        else
            try std.fmt.allocPrint(allocator, "recency {d:.2}", .{recency});

        try scored.append(allocator, .{
            .entry = entry,
            .score = score,
            .detail = detail,
        });
    }

    std.sort.pdq(ScoredEntry, scored.items, {}, struct {
        fn less(_: void, a: ScoredEntry, b: ScoredEntry) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.entry.updated_ms > b.entry.updated_ms;
        }
    }.less);

    const take = @min(options.max_entries, scored.items.len);
    var out: std.ArrayList(ScoredEntry) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item.detail);
        out.deinit(allocator);
    }

    for (scored.items[0..take]) |item| {
        try out.append(allocator, .{
            .entry = item.entry,
            .score = item.score,
            .detail = try allocator.dupe(u8, item.detail),
        });
    }

    for (scored.items) |item| allocator.free(item.detail);
    scored.deinit(allocator);

    return try out.toOwnedSlice(allocator);
}

pub fn freeScoredEntries(allocator: std.mem.Allocator, items: []ScoredEntry) void {
    for (items) |item| allocator.free(item.detail);
    allocator.free(items);
}

pub fn formatBlock(allocator: std.mem.Allocator, selected: []const ScoredEntry, options: SelectOptions) !?[]const u8 {
    if (selected.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Agent memory (persistent project notes)\n\n");

    for (selected) |item| {
        const content = truncate(item.entry.content, options.max_entry_chars);
        const section = try std.fmt.allocPrint(allocator, "## [{s}] {s} ({s})\n{s}\n\n", .{
            item.entry.kind.label(),
            item.entry.id,
            item.detail,
            content,
        });
        defer allocator.free(section);
        try out.appendSlice(allocator, section);
    }

    return try out.toOwnedSlice(allocator);
}

fn truncate(text: []const u8, max_chars: usize) []const u8 {
    if (text.len <= max_chars) return text;
    return text[0..max_chars];
}

fn contentTermOverlap(content: []const u8, terms: []const []const u8) f32 {
    if (terms.len == 0) return 0;
    var hits: usize = 0;
    for (terms) |term| {
        if (term.len < 3) continue;
        const stem = if (term.len > 6) term[0..6] else term;
        if (std.ascii.findIgnoreCase(content, term) != null or std.ascii.findIgnoreCase(content, stem) != null) hits += 1;
    }
    return @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(terms.len));
}

fn tagTermOverlap(tags: []const []const u8, terms: []const []const u8) f32 {
    if (terms.len == 0 or tags.len == 0) return 0;
    var hits: usize = 0;
    for (terms) |term| {
        for (tags) |tag| {
            if (std.ascii.eqlIgnoreCase(term, tag)) {
                hits += 1;
                break;
            }
        }
    }
    return @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(terms.len));
}

test "selectForIntent prefers matching memory" {
    const allocator = std.testing.allocator;
    const entries = [_]workspace.agent_memory.Entry{
        .{
            .id = "mem_1",
            .kind = .fact,
            .content = "Authentication middleware lives in auth.zig",
            .tags = &[_][]const u8{"auth"},
            .created_ms = 10,
            .updated_ms = 10,
            .source = "agent",
        },
        .{
            .id = "mem_2",
            .kind = .preference,
            .content = "Use fmt allocPrint for dynamic strings",
            .tags = &[_][]const u8{"zig"},
            .created_ms = 20,
            .updated_ms = 20,
            .source = "agent",
        },
    };

    const selected = try selectForIntent(allocator, &entries, "fix authenticate flow", .{ .max_entries = 2 });
    defer freeScoredEntries(allocator, selected);

    try std.testing.expect(selected.len >= 1);
    try std.testing.expectEqualStrings("mem_1", selected[0].entry.id);
}

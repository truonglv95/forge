const std = @import("std");

pub const Source = enum {
    semantic,
    keyword,
};

pub const Input = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
    text: []const u8,
    source: Source,
    /// Normalized source score in [0, 1] for display only.
    source_score: f32,
    source_rank: usize,
};

pub const Signals = struct {
    active_file: ?[]const u8 = null,
    scoped_paths: []const []const u8 = &.{},
    recent_paths: []const []const u8 = &.{},
    import_paths: []const []const u8 = &.{},
    git_paths: []const []const u8 = &.{},
    intent_terms: []const []const u8 = &.{},
};

pub const Options = struct {
    rrf_k: f32 = 60.0,
    max_results: usize = 12,
    max_per_file: usize = 2,
    active_boost: f32 = 0.15,
    scoped_boost: f32 = 0.12,
    recent_boost: f32 = 0.08,
    import_boost: f32 = 0.10,
    git_boost: f32 = 0.12,
    path_overlap_max: f32 = 0.10,
};

pub const RankedHit = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
    text: []const u8,
    final_score: f32,
    detail: []const u8,
    had_semantic: bool,
    had_keyword: bool,
};

const Merged = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
    text: []const u8,
    semantic_rank: ?usize = null,
    keyword_rank: ?usize = null,
    semantic_score: f32 = 0,
    keyword_score: f32 = 0,
};

pub fn rerank(
    allocator: std.mem.Allocator,
    inputs: []const Input,
    signals: Signals,
    options: Options,
) ![]RankedHit {
    if (inputs.len == 0) return &.{};

    var merged: std.ArrayList(Merged) = .empty;
    errdefer {
        for (merged.items) |item| allocator.free(item.path);
        merged.deinit(allocator);
    }

    for (inputs) |item| {
        try upsertMerged(allocator, &merged, item);
    }

    var ranked: std.ArrayList(RankedHit) = .empty;
    errdefer {
        for (ranked.items) |hit| {
            allocator.free(hit.path);
            allocator.free(hit.text);
            allocator.free(hit.detail);
        }
        ranked.deinit(allocator);
    }

    for (merged.items) |item| {
        var rrf: f32 = 0;
        if (item.semantic_rank) |rank| rrf += 1.0 / (options.rrf_k + @as(f32, @floatFromInt(rank + 1)));
        if (item.keyword_rank) |rank| rrf += 1.0 / (options.rrf_k + @as(f32, @floatFromInt(rank + 1)));

        var boost: f32 = 0;
        var boost_parts: std.ArrayList(u8) = .empty;
        defer boost_parts.deinit(allocator);

        if (signals.active_file) |active| {
            if (std.mem.eql(u8, active, item.path)) {
                boost += options.active_boost;
                try boost_parts.appendSlice(allocator, "+active");
            }
        }
        if (containsPath(signals.scoped_paths, item.path)) {
            boost += options.scoped_boost;
            try appendBoostTag(allocator, &boost_parts, "+scoped");
        }
        if (containsPath(signals.recent_paths, item.path)) {
            boost += options.recent_boost;
            try appendBoostTag(allocator, &boost_parts, "+recent");
        }
        if (containsPath(signals.import_paths, item.path)) {
            boost += options.import_boost;
            try appendBoostTag(allocator, &boost_parts, "+import");
        }
        if (containsPath(signals.git_paths, item.path)) {
            boost += options.git_boost;
            try appendBoostTag(allocator, &boost_parts, "+git");
        }

        const overlap = pathTermOverlapScore(item.path, signals.intent_terms);
        const overlap_boost = overlap * options.path_overlap_max;
        boost += overlap_boost;
        if (overlap_boost > 0.001) try appendBoostTag(allocator, &boost_parts, "+path");

        const final_score = rrf + boost;
        const sources = blk: {
            if (item.semantic_rank != null and item.keyword_rank != null) break :blk "semantic+keyword";
            if (item.semantic_rank != null) break :blk "semantic";
            break :blk "keyword";
        };

        const detail = if (boost_parts.items.len > 0)
            try std.fmt.allocPrint(allocator, "RRF {d:.4} {s} → {d:.4} ({s})", .{
                rrf,
                boost_parts.items,
                final_score,
                sources,
            })
        else
            try std.fmt.allocPrint(allocator, "RRF {d:.4} → {d:.4} ({s})", .{
                rrf,
                final_score,
                sources,
            });

        try ranked.append(allocator, .{
            .path = try allocator.dupe(u8, item.path),
            .line_start = item.line_start,
            .line_end = item.line_end,
            .text = try allocator.dupe(u8, item.text),
            .final_score = final_score,
            .detail = detail,
            .had_semantic = item.semantic_rank != null,
            .had_keyword = item.keyword_rank != null,
        });
    }

    for (merged.items) |item| allocator.free(item.path);

    std.sort.pdq(RankedHit, ranked.items, {}, struct {
        fn less(_: void, a: RankedHit, b: RankedHit) bool {
            if (a.final_score != b.final_score) return a.final_score > b.final_score;
            if (a.line_start != b.line_start) return a.line_start < b.line_start;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);

    return try selectWithDiversity(allocator, ranked.items, options);
}

pub fn freeHits(allocator: std.mem.Allocator, hits: []RankedHit) void {
    for (hits) |hit| {
        allocator.free(hit.path);
        allocator.free(hit.text);
        allocator.free(hit.detail);
    }
    allocator.free(hits);
}

pub fn formatBlock(allocator: std.mem.Allocator, hits: []const RankedHit) !?[]const u8 {
    if (hits.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Fused context (RRF semantic + keyword)\n\n");

    for (hits) |hit| {
        const section = try std.fmt.allocPrint(allocator, "## {s}:{d}-{d} ({s})\n```\n{s}\n```\n\n", .{
            hit.path,
            hit.line_start,
            hit.line_end,
            hit.detail,
            hit.text,
        });
        defer allocator.free(section);
        try out.appendSlice(allocator, section);
    }

    return try out.toOwnedSlice(allocator);
}

fn upsertMerged(allocator: std.mem.Allocator, merged: *std.ArrayList(Merged), item: Input) !void {
    for (merged.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, item.path)) continue;
        if (!rangesOverlap(existing.line_start, existing.line_end, item.line_start, item.line_end)) continue;

        existing.line_start = @min(existing.line_start, item.line_start);
        existing.line_end = @max(existing.line_end, item.line_end);
        if (item.text.len > existing.text.len) {
            existing.text = item.text;
        }
        switch (item.source) {
            .semantic => {
                if (existing.semantic_rank == null or item.source_rank < existing.semantic_rank.?) {
                    existing.semantic_rank = item.source_rank;
                    existing.semantic_score = item.source_score;
                }
            },
            .keyword => {
                if (existing.keyword_rank == null or item.source_rank < existing.keyword_rank.?) {
                    existing.keyword_rank = item.source_rank;
                    existing.keyword_score = item.source_score;
                }
            },
        }
        return;
    }

    var entry = Merged{
        .path = try allocator.dupe(u8, item.path),
        .line_start = item.line_start,
        .line_end = item.line_end,
        .text = item.text,
    };
    switch (item.source) {
        .semantic => {
            entry.semantic_rank = item.source_rank;
            entry.semantic_score = item.source_score;
        },
        .keyword => {
            entry.keyword_rank = item.source_rank;
            entry.keyword_score = item.source_score;
        },
    }
    try merged.append(allocator, entry);
}

fn selectWithDiversity(allocator: std.mem.Allocator, ranked: []RankedHit, options: Options) ![]RankedHit {
    var out: std.ArrayList(RankedHit) = .empty;
    errdefer {
        for (out.items) |hit| {
            allocator.free(hit.path);
            allocator.free(hit.text);
            allocator.free(hit.detail);
        }
        out.deinit(allocator);
    }

    var per_file = std.StringHashMap(usize).init(allocator);
    defer {
        var key_it = per_file.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        per_file.deinit();
    }

    for (ranked) |hit| {
        const count = per_file.get(hit.path) orelse 0;
        if (count >= options.max_per_file) continue;
        try per_file.put(try allocator.dupe(u8, hit.path), count + 1);
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, hit.path),
            .line_start = hit.line_start,
            .line_end = hit.line_end,
            .text = try allocator.dupe(u8, hit.text),
            .final_score = hit.final_score,
            .detail = try allocator.dupe(u8, hit.detail),
            .had_semantic = hit.had_semantic,
            .had_keyword = hit.had_keyword,
        });
        if (out.items.len >= options.max_results) break;
    }

    for (ranked) |hit| {
        allocator.free(hit.path);
        allocator.free(hit.text);
        allocator.free(hit.detail);
    }

    return try out.toOwnedSlice(allocator);
}

fn rangesOverlap(a_start: u32, a_end: u32, b_start: u32, b_end: u32) bool {
    return a_start <= b_end and b_start <= a_end;
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |entry| {
        if (std.mem.eql(u8, entry, path)) return true;
    }
    return false;
}

fn pathTermOverlapScore(path: []const u8, terms: []const []const u8) f32 {
    if (terms.len == 0) return 0;
    var hits: usize = 0;
    for (terms) |term| {
        if (term.len < 3) continue;
        if (std.ascii.indexOfIgnoreCase(path, term) != null) hits += 1;
    }
    return @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(terms.len));
}

fn appendBoostTag(allocator: std.mem.Allocator, parts: *std.ArrayList(u8), tag: []const u8) !void {
    if (parts.items.len > 0) try parts.append(allocator, ' ');
    try parts.appendSlice(allocator, tag);
}

test "RRF fusion prefers dual-source hits" {
    const allocator = std.testing.allocator;
    const inputs = [_]Input{
        .{ .path = "a.zig", .line_start = 1, .line_end = 3, .text = "only semantic", .source = .semantic, .source_score = 0.9, .source_rank = 0 },
        .{ .path = "b.zig", .line_start = 10, .line_end = 12, .text = "only keyword", .source = .keyword, .source_score = 0.5, .source_rank = 0 },
        .{ .path = "c.zig", .line_start = 5, .line_end = 7, .text = "both", .source = .semantic, .source_score = 0.7, .source_rank = 1 },
        .{ .path = "c.zig", .line_start = 5, .line_end = 7, .text = "both", .source = .keyword, .source_score = 0.6, .source_rank = 0 },
    };

    const hits = try rerank(allocator, &inputs, .{}, .{});
    defer freeHits(allocator, hits);

    try std.testing.expect(hits.len >= 2);
    try std.testing.expect(hits[0].had_semantic and hits[0].had_keyword);
    try std.testing.expect(std.mem.eql(u8, hits[0].path, "c.zig"));
}

test "diversity caps chunks per file" {
    const allocator = std.testing.allocator;
    var inputs: [4]Input = undefined;
    for (0..4) |i| {
        inputs[i] = .{
            .path = "same.zig",
            .line_start = @intCast(i * 10 + 1),
            .line_end = @intCast(i * 10 + 3),
            .text = "x",
            .source = .semantic,
            .source_score = @as(f32, @floatFromInt(4 - i)) / 4.0,
            .source_rank = i,
        };
    }

    const hits = try rerank(allocator, &inputs, .{}, .{ .max_per_file = 2, .max_results = 4 });
    defer freeHits(allocator, hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "active file boost ranks higher" {
    const allocator = std.testing.allocator;
    const inputs = [_]Input{
        .{ .path = "other.zig", .line_start = 1, .line_end = 1, .text = "a", .source = .semantic, .source_score = 0.95, .source_rank = 0 },
        .{ .path = "open.zig", .line_start = 1, .line_end = 1, .text = "b", .source = .semantic, .source_score = 0.80, .source_rank = 1 },
    };

    const hits = try rerank(allocator, &inputs, .{ .active_file = "open.zig" }, .{});
    defer freeHits(allocator, hits);

    try std.testing.expectEqualStrings("open.zig", hits[0].path);
}

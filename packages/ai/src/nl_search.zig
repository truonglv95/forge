//! Natural Language Code Search — search code using natural language queries.
//! Uses RAG index (embeddings) + BM25 keyword matching for hybrid search.
const std = @import("std");
const rag = @import("rag/index.zig");

pub const SearchResult = struct {
    file_path: []const u8,
    start_line: u32,
    end_line: u32,
    content: []const u8,
    score: f32,
    symbol_name: ?[]const u8 = null,

    pub fn deinit(_: *SearchResult, _: std.mem.Allocator) void {}
};

pub const SearchOptions = struct {
    max_results: usize = 10,
    min_score: f32 = 0.1,
    /// Weight for semantic (embedding) score vs keyword (BM25) score.
    /// 0.0 = pure keyword, 1.0 = pure semantic, 0.5 = balanced.
    semantic_weight: f32 = 0.6,
};

/// Search the RAG index using a natural language query.
/// Requires the query to be embedded first (via embedding provider).
pub fn semanticSearch(
    index: *const rag.RagIndex,
    query_embedding: []const f32,
    options: SearchOptions,
    allocator: std.mem.Allocator,
) ![]SearchResult {
    const scored = try index.query(query_embedding, options.max_results, allocator);
    defer allocator.free(scored);

    var results: std.ArrayList(SearchResult) = .empty;
    errdefer results.deinit(allocator);

    for (scored) |s| {
        if (s.score < options.min_score) continue;
        const chunk = index.chunks.items[s.index];
        try results.append(allocator, .{
            .file_path = chunk.file_path,
            .start_line = chunk.start_line,
            .end_line = chunk.end_line,
            .content = chunk.content,
            .score = s.score,
            .symbol_name = chunk.symbol_name,
        });
    }

    return results.toOwnedSlice(allocator);
}

/// BM25-style keyword search over the RAG index content.
/// Used as a fallback when embeddings are not available, or combined
/// with semantic search for hybrid ranking.
pub fn keywordSearch(
    index: *const rag.RagIndex,
    query: []const u8,
    options: SearchOptions,
    allocator: std.mem.Allocator,
) ![]SearchResult {
    var scored: std.ArrayList(SearchResult) = .empty;
    defer scored.deinit(allocator);

    // Tokenize query
    var query_terms: std.ArrayList([]const u8) = .empty;
    defer query_terms.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, query, " \t\n.,;:!?()[]{}\"'");
    while (it.next()) |term| {
        if (term.len >= 2) try query_terms.append(allocator, term);
    }

    if (query_terms.items.len == 0) return &.{};

    // Score each chunk by term frequency
    for (index.chunks.items) |chunk| {
        var score: f32 = 0;
        for (query_terms.items) |term| {
            // Count occurrences (case-insensitive)
            var count: f32 = 0;
            var pos: usize = 0;
            while (pos < chunk.content.len) {
                if (std.ascii.startsWithIgnoreCase(chunk.content[pos..], term)) {
                    count += 1;
                    pos += term.len;
                } else {
                    pos += 1;
                }
            }
            // BM25-like scoring: tf * idf approximation
            if (count > 0) {
                score += count / (count + 1.5); // Saturation
            }
        }

        if (score >= options.min_score) {
            try scored.append(allocator, .{
                .file_path = chunk.file_path,
                .start_line = chunk.start_line,
                .end_line = chunk.end_line,
                .content = chunk.content,
                .score = score / @as(f32, @floatFromInt(query_terms.items.len)),
                .symbol_name = chunk.symbol_name,
            });
        }
    }

    // Sort by score descending
    std.sort.block(SearchResult, scored.items, {}, struct {
        fn less(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score > b.score;
        }
    }.less);

    // Limit results
    const result_count = @min(options.max_results, scored.items.len);
    const result = try allocator.alloc(SearchResult, result_count);
    @memcpy(result, scored.items[0..result_count]);
    return result;
}

/// Hybrid search — combines semantic and keyword search results.
pub fn hybridSearch(
    index: *const rag.RagIndex,
    query: []const u8,
    query_embedding: ?[]const f32,
    options: SearchOptions,
    allocator: std.mem.Allocator,
) ![]SearchResult {
    // Get keyword results
    const kw_results = try keywordSearch(index, query, options, allocator);
    defer allocator.free(kw_results);

    // Get semantic results if embedding available
    var sem_results: []SearchResult = &.{};
    if (query_embedding) |emb| {
        sem_results = try semanticSearch(index, emb, options, allocator);
    }
    defer if (sem_results.len > 0) allocator.free(sem_results);

    // Merge and re-rank
    var merged: std.ArrayList(SearchResult) = .empty;
    errdefer merged.deinit(allocator);

    const sem_w = options.semantic_weight;
    const kw_w = 1.0 - sem_w;

    // Add keyword results with weighted score
    for (kw_results) |r| {
        try merged.append(allocator, .{
            .file_path = r.file_path,
            .start_line = r.start_line,
            .end_line = r.end_line,
            .content = r.content,
            .score = r.score * kw_w,
            .symbol_name = r.symbol_name,
        });
    }

    // Add semantic results (boost if already in merged)
    for (sem_results) |r| {
        var found = false;
        for (merged.items) |*m| {
            if (m.start_line == r.start_line and std.mem.eql(u8, m.file_path, r.file_path)) {
                m.score += r.score * sem_w;
                found = true;
                break;
            }
        }
        if (!found) {
            try merged.append(allocator, .{
                .file_path = r.file_path,
                .start_line = r.start_line,
                .end_line = r.end_line,
                .content = r.content,
                .score = r.score * sem_w,
                .symbol_name = r.symbol_name,
            });
        }
    }

    // Sort by combined score
    std.sort.block(SearchResult, merged.items, {}, struct {
        fn less(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score > b.score;
        }
    }.less);

    // Limit and return
    const result_count = @min(options.max_results, merged.items.len);
    const result = try allocator.alloc(SearchResult, result_count);
    @memcpy(result, merged.items[0..result_count]);
    return result;
}

test "keywordSearch finds matching chunks" {
    const allocator = std.testing.allocator;
    var index = rag.RagIndex.init(allocator);
    defer index.deinit();

    try index.addChunk(.{
        .file_path = try allocator.dupe(u8, "auth.zig"),
        .start_line = 0,
        .end_line = 10,
        .content = try allocator.dupe(u8, "pub fn authenticateUser(username: []const u8, password: []const u8) bool"),
    });
    try index.addChunk(.{
        .file_path = try allocator.dupe(u8, "render.zig"),
        .start_line = 0,
        .end_line = 10,
        .content = try allocator.dupe(u8, "pub fn drawRectangle(x: f32, y: f32, w: f32, h: f32) void"),
    });

    const results = try keywordSearch(&index, "authenticate user", .{ .max_results = 5, .min_score = 0.01 }, allocator);
    defer allocator.free(results);

    try std.testing.expect(results.len > 0);
    // Results point into index chunks, so just check the path matches
    // without freeing — index.deinit() will clean up.
    var found_auth = false;
    for (results) |r| {
        if (std.mem.indexOf(u8, r.file_path, "auth") != null) {
            found_auth = true;
            break;
        }
    }
    try std.testing.expect(found_auth);
}

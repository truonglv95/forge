//! RAG (Retrieval-Augmented Generation) indexing pipeline.
//!
//! Builds a semantic index of the workspace by:
//! 1. Parsing files into chunks (by function/class/section)
//! 2. Embedding each chunk using a local or remote embedding model
//! 3. Storing vectors in a persistent vector DB (.forge/vectors/)
//! 4. Providing a query interface: embed query → cosine similarity → top-K

const std = @import("std");
const workspace = @import("forge-workspace");

/// A code chunk — a semantically meaningful piece of code (function, class, etc.)
pub const Chunk = struct {
    file_path: []const u8,
    start_line: u32,
    end_line: u32,
    content: []const u8,
    /// Embedding vector (dimension depends on model, typically 768-1024).
    embedding: ?[]f32 = null,
    /// Symbol name if available (e.g. "main", "Buffer.insertString").
    symbol_name: ?[]const u8 = null,
    /// Chunk type for filtering.
    chunk_type: ChunkType = .code,

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.content);
        if (self.embedding) |e| allocator.free(e);
        if (self.symbol_name) |s| allocator.free(s);
    }
};

pub const ChunkType = enum {
    code,
    comment,
    doc,
    @"test",
    config,
};

/// Indexing status — shown in the UI during background indexing.
pub const IndexStatus = struct {
    total_files: usize = 0,
    indexed_files: usize = 0,
    total_chunks: usize = 0,
    is_indexing: bool = false,
    last_error: ?[]const u8 = null,

    pub fn progress(self: IndexStatus) f32 {
        if (self.total_files == 0) return 0;
        return @as(f32, @floatFromInt(self.indexed_files)) / @as(f32, @floatFromInt(self.total_files));
    }
};

/// The RAG index — stores all chunks and provides query interface.
pub const RagIndex = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList(Chunk),
    status: IndexStatus,
    /// Vector dimension (depends on embedding model).
    vector_dim: usize = 1024,

    pub fn init(allocator: std.mem.Allocator) RagIndex {
        return .{
            .allocator = allocator,
            .chunks = .empty,
            .status = .{},
        };
    }

    pub fn deinit(self: *RagIndex) void {
        for (self.chunks.items) |*chunk| chunk.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        if (self.status.last_error) |err| self.allocator.free(err);
    }

    /// Add a chunk to the index. Takes ownership of all fields.
    pub fn addChunk(self: *RagIndex, chunk: Chunk) !void {
        try self.chunks.append(self.allocator, chunk);
        self.status.total_chunks = self.chunks.items.len;
    }

    /// Query the index: find the top-K most similar chunks to a query vector.
    /// Returns indices into the chunks array, sorted by similarity (best first).
    pub fn query(
        self: *const RagIndex,
        query_embedding: []const f32,
        k: usize,
        allocator: std.mem.Allocator,
    ) ![]ScoredChunk {
        if (self.chunks.items.len == 0) return &.{};

        var scored: std.ArrayList(ScoredChunk) = .empty;
        defer scored.deinit(allocator);

        for (self.chunks.items, 0..) |chunk, i| {
            if (chunk.embedding) |emb| {
                const score = cosineSimilarity(query_embedding, emb);
                try scored.append(allocator, .{ .index = i, .score = score });
            }
        }

        // Sort by score descending
        std.sort.block(ScoredChunk, scored.items, {}, struct {
            fn less(_: void, a: ScoredChunk, b: ScoredChunk) bool {
                return a.score > b.score;
            }
        }.less);

        // Return top-K
        const result_count = @min(k, scored.items.len);
        const result = try allocator.alloc(ScoredChunk, result_count);
        @memcpy(result, scored.items[0..result_count]);
        return result;
    }

    /// Get chunks by file path — useful for showing indexed content.
    pub fn chunksForFile(self: *const RagIndex, file_path: []const u8) []const Chunk {
        var start: ?usize = null;
        var end: usize = 0;
        for (self.chunks.items, 0..) |chunk, i| {
            if (std.mem.eql(u8, chunk.file_path, file_path)) {
                if (start == null) start = i;
                end = i + 1;
            }
        }
        if (start) |s| return self.chunks.items[s..end];
        return &.{};
    }

    /// Clear the index (used when re-indexing).
    pub fn clear(self: *RagIndex) void {
        for (self.chunks.items) |*chunk| chunk.deinit(self.allocator);
        self.chunks.clearRetainingCapacity();
        self.status = .{};
    }
};

pub const ScoredChunk = struct {
    index: usize,
    score: f32,
};

/// Cosine similarity between two vectors.
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len or a.len == 0) return 0;
    var dot: f32 = 0;
    var norm_a: f32 = 0;
    var norm_b: f32 = 0;
    for (a, b) |av, bv| {
        dot += av * bv;
        norm_a += av * av;
        norm_b += bv * bv;
    }
    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (denom == 0) return 0;
    return dot / denom;
}

/// Chunk a source file into semantic pieces.
/// Strategy: split by function/class boundaries (heuristic: lines starting
/// with "pub fn", "fn", "const", "struct", "class", "def ", etc.)
pub fn chunkFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
) ![]Chunk {
    var chunks: std.ArrayList(Chunk) = .empty;
    errdefer {
        for (chunks.items) |*c| c.deinit(allocator);
        chunks.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_start: u32 = 0;
    var current_content: std.ArrayList(u8) = .empty;
    defer current_content.deinit(allocator);
    var line_num: u32 = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        // Check if this line starts a new top-level definition
        const is_new_chunk = isChunkStart(trimmed);

        if (is_new_chunk and current_content.items.len > 0) {
            // Save previous chunk
            const owned_content = try allocator.dupe(u8, current_content.items);
            try chunks.append(allocator, .{
                .file_path = try allocator.dupe(u8, file_path),
                .start_line = current_start,
                .end_line = line_num,
                .content = owned_content,
            });
            current_content.clearRetainingCapacity();
            current_start = line_num;
        }

        try current_content.appendSlice(allocator, line);
        try current_content.append(allocator, '\n');
        line_num += 1;
    }

    // Don't forget the last chunk
    if (current_content.items.len > 0) {
        const owned_content = try allocator.dupe(u8, current_content.items);
        try chunks.append(allocator, .{
            .file_path = try allocator.dupe(u8, file_path),
            .start_line = current_start,
            .end_line = line_num,
            .content = owned_content,
        });
    }

    return chunks.toOwnedSlice(allocator);
}

/// Check if a line starts a new chunk (function, class, struct, etc.)
fn isChunkStart(line: []const u8) bool {
    if (line.len == 0) return false;
    // Zig
    if (std.mem.startsWith(u8, line, "pub fn ") or
        std.mem.startsWith(u8, line, "fn ") or
        std.mem.startsWith(u8, line, "pub const ") or
        std.mem.startsWith(u8, line, "pub var ") or
        std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "test \""))
    {
        return true;
    }
    // Python
    if (std.mem.startsWith(u8, line, "def ") or
        std.mem.startsWith(u8, line, "class "))
    {
        return true;
    }
    // JS/TS
    if (std.mem.startsWith(u8, line, "function ") or
        std.mem.startsWith(u8, line, "export function ") or
        std.mem.startsWith(u8, line, "class ") or
        std.mem.startsWith(u8, line, "export class ") or
        std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "export const "))
    {
        return true;
    }
    // C/C++
    if (std.mem.startsWith(u8, line, "void ") or
        std.mem.startsWith(u8, line, "int ") or
        std.mem.startsWith(u8, line, "static ") or
        std.mem.startsWith(u8, line, "struct "))
    {
        return true;
    }
    return false;
}

test "cosineSimilarity identical vectors" {
    const a = [_]f32{ 1, 2, 3 };
    try std.testing.expect(std.math.approxEqAbs(f32, cosineSimilarity(&a, &a), 1.0, 0.001));
}

test "cosineSimilarity orthogonal vectors" {
    const a = [_]f32{ 1, 0 };
    const b = [_]f32{ 0, 1 };
    try std.testing.expect(std.math.approxEqAbs(f32, cosineSimilarity(&a, &b), 0.0, 0.001));
}

test "chunkFile splits by function" {
    const allocator = std.testing.allocator;
    const content =
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    std.debug.print("hello", .{});
        \\}
        \\
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    ;
    const chunks = try chunkFile(allocator, "test.zig", content);
    defer {
        for (chunks) |*c| c.deinit(allocator);
        allocator.free(chunks);
    }
    try std.testing.expect(chunks.len >= 2);
}

test "RagIndex query returns top-K" {
    const allocator = std.testing.allocator;
    var index = RagIndex.init(allocator);
    defer index.deinit();

    // Add chunks with known embeddings
    const emb1 = try allocator.alloc(f32, 3);
    @memcpy(emb1, &[_]f32{ 1, 0, 0 });
    try index.addChunk(.{
        .file_path = try allocator.dupe(u8, "a.zig"),
        .start_line = 0,
        .end_line = 5,
        .content = try allocator.dupe(u8, "fn a()"),
        .embedding = emb1,
    });

    const emb2 = try allocator.alloc(f32, 3);
    @memcpy(emb2, &[_]f32{ 0, 1, 0 });
    try index.addChunk(.{
        .file_path = try allocator.dupe(u8, "b.zig"),
        .start_line = 0,
        .end_line = 5,
        .content = try allocator.dupe(u8, "fn b()"),
        .embedding = emb2,
    });

    // Query with [1, 0, 0] → should return a.zig first
    const query = [_]f32{ 1, 0, 0 };
    const results = try index.query(&query, 2, allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[0].score > results[1].score);
}

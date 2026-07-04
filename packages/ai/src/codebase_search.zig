const std = @import("std");
const workspace = @import("forge-workspace");
const local_vector = @import("local_vector.zig");
const credentials = @import("credentials.zig");
const gemini_embedder = @import("gemini_embedder.zig");

pub const scope_resolver = @import("scope_resolver.zig");

pub const SearchOptions = struct {
    top_k: usize = 10,
    max_bytes: usize = 24 * 1024,
    prefer_gemini: bool = true,
    environ_map: ?*const std.process.Environ.Map = null,
};

pub const ScoredChunk = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
    score: f32,
    text: []const u8,
};

const LoadedIndex = struct {
    allocator: std.mem.Allocator,
    dim: u32,
    chunks: []StoredChunk,
    vectors: []f32,

    pub fn deinit(self: *LoadedIndex) void {
        for (self.chunks) |chunk| {
            self.allocator.free(chunk.id);
            self.allocator.free(chunk.path);
            self.allocator.free(chunk.text);
        }
        self.allocator.free(self.chunks);
        if (self.vectors.len > 0) self.allocator.free(self.vectors);
        self.* = undefined;
    }
};

const StoredChunk = struct {
    id: []const u8,
    path: []const u8,
    line_start: u32,
    line_end: u32,
    file_hash: u64,
    text: []const u8,
};

const EmbedBackend = struct {
    dim: u32,
    embed: *const fn (std.mem.Allocator, []const u8, []f32) anyerror!void,
    creds: ?credentials.Credentials = null,

    pub fn deinit(self: *EmbedBackend) void {
        if (self.creds) |*owned| owned.deinit();
    }
};

fn resolveEmbedBackend(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SearchOptions,
) !EmbedBackend {
    if (options.prefer_gemini) {
        if (options.environ_map) |map| {
            if (credentials.Credentials.loadGemini(allocator, io, map)) |creds| {
                return .{
                    .dim = @intCast(gemini_embedder.dim),
                    .embed = geminiEmbedAdapter,
                    .creds = creds,
                };
            } else |_| {}
        }
    }

    return .{
        .dim = @intCast(local_vector.dim),
        .embed = localEmbedAdapter,
    };
}

fn localEmbedAdapter(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    return local_vector.embedInto(allocator, text, out);
}

const GeminiEmbedContext = struct {
    io: std.Io,
    creds: *credentials.Credentials,
};

threadlocal var gemini_embed_ctx: ?GeminiEmbedContext = null;

fn geminiEmbedAdapter(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    const ctx = gemini_embed_ctx orelse return error.ProviderFailed;
    return gemini_embedder.embedInto(allocator, ctx.io, ctx.creds.*, text, out);
}

pub fn ensureIndex(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, options: SearchOptions) !void {
    var backend = try resolveEmbedBackend(allocator, io, options);
    defer backend.deinit();

    const manifest_dim = readManifestDim(allocator, io, root) catch null;
    const needs = try workspace.codebase_index.needsRebuild(allocator, io, root);
    if (needs or manifest_dim == null or manifest_dim.? != backend.dim) {
        if (backend.creds) |*owned| {
            gemini_embed_ctx = .{ .io = io, .creds = owned };
            defer gemini_embed_ctx = null;
            _ = try workspace.codebase_index.refresh(allocator, io, root, backend.dim, geminiEmbedAdapter);
        } else {
            _ = try workspace.codebase_index.refresh(allocator, io, root, backend.dim, localEmbedAdapter);
        }
    }
}

const ScoreItem = struct { index: usize, score: f32 };

pub fn search(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    query: []const u8,
    skip_paths: []const []const u8,
    options: SearchOptions,
) ![]ScoredChunk {
    try ensureIndex(allocator, io, root, options);

    var index = try loadIndex(allocator, io, root);
    defer index.deinit();

    if (index.chunks.len == 0) return &.{};

    var backend = try resolveEmbedBackend(allocator, io, options);
    defer backend.deinit();

    const query_vec = try allocator.alloc(f32, index.dim);
    defer allocator.free(query_vec);
    @memset(query_vec, 0);

    if (backend.creds) |*owned| {
        gemini_embed_ctx = .{ .io = io, .creds = owned };
        defer gemini_embed_ctx = null;
        try geminiEmbedAdapter(allocator, query, query_vec);
    } else {
        try localEmbedAdapter(allocator, query, query_vec);
    }

    var scores: std.ArrayList(ScoreItem) = .empty;
    defer scores.deinit(allocator);

    const dim: usize = @intCast(index.dim);
    for (index.chunks, 0..) |chunk, chunk_index| {
        if (shouldSkip(chunk.path, skip_paths)) continue;
        const offset = chunk_index * dim;
        if (offset + dim > index.vectors.len) continue;
        const vec = index.vectors[offset .. offset + dim];
        const score = cosineSlices(query_vec, vec);
        if (score <= 0.01) continue;
        try scores.append(allocator, .{ .index = chunk_index, .score = score });
    }

    std.sort.pdq(ScoreItem, scores.items, {}, struct {
        fn less(_: void, a: ScoreItem, b: ScoreItem) bool {
            return a.score > b.score;
        }
    }.less);

    const take = @min(options.top_k, scores.items.len);
    var out: std.ArrayList(ScoredChunk) = .empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.path);
            allocator.free(item.text);
        }
        out.deinit(allocator);
    }

    for (scores.items[0..take]) |item| {
        const chunk = index.chunks[item.index];
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, chunk.path),
            .line_start = chunk.line_start,
            .line_end = chunk.line_end,
            .score = item.score,
            .text = try allocator.dupe(u8, chunk.text),
        });
    }

    return try out.toOwnedSlice(allocator);
}

fn cosineSlices(a: []const f32, b: []const f32) f32 {
    const len = @min(a.len, b.len);
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (0..len) |i| {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    const denom = @sqrt(na * nb);
    if (denom == 0) return 0;
    return dot / denom;
}

pub fn freeResults(allocator: std.mem.Allocator, results: []ScoredChunk) void {
    for (results) |item| {
        allocator.free(item.path);
        allocator.free(item.text);
    }
    allocator.free(results);
}

pub fn formatBlock(allocator: std.mem.Allocator, results: []const ScoredChunk) !?[]const u8 {
    if (results.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Semantic codebase search\n\n");

    for (results) |item| {
        const section = try std.fmt.allocPrint(allocator, "## {s}:{d}-{d} (score {d:.3})\n```\n{s}\n```\n\n", .{
            item.path,
            item.line_start,
            item.line_end,
            item.score,
            item.text,
        });
        defer allocator.free(section);
        try out.appendSlice(allocator, section);
    }

    return try out.toOwnedSlice(allocator);
}

fn shouldSkip(path: []const u8, skip_paths: []const []const u8) bool {
    if (std.mem.startsWith(u8, path, ".forge/")) return true;
    for (skip_paths) |skip| {
        if (std.mem.eql(u8, skip, path)) return true;
    }
    return false;
}

fn readManifestDim(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !?u32 {
    const manifest_bytes = readRelative(allocator, io, root, workspace.codebase_index.manifest_file) catch return null;
    defer allocator.free(manifest_bytes);

    const ManifestJson = struct { dim: u32 };
    var manifest_parsed = try std.json.parseFromSlice(ManifestJson, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    return manifest_parsed.value.dim;
}

fn loadIndex(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !LoadedIndex {
    const manifest_bytes = readRelative(allocator, io, root, workspace.codebase_index.manifest_file) catch return emptyIndex(allocator);
    defer allocator.free(manifest_bytes);

    const ManifestJson = struct {
        dim: u32,
        chunk_count: u32,
    };
    var manifest_parsed = try std.json.parseFromSlice(ManifestJson, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();

    const chunks_bytes = readRelative(allocator, io, root, workspace.codebase_index.chunks_file) catch return emptyIndex(allocator);
    defer allocator.free(chunks_bytes);

    const vectors_bytes = readRelative(allocator, io, root, workspace.codebase_index.vectors_file) catch return emptyIndex(allocator);
    defer allocator.free(vectors_bytes);

    var chunks: std.ArrayList(StoredChunk) = .empty;
    errdefer {
        for (chunks.items) |chunk| {
            allocator.free(chunk.id);
            allocator.free(chunk.path);
            allocator.free(chunk.text);
        }
        chunks.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, chunks_bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const Row = struct {
            id: []const u8,
            path: []const u8,
            line_start: u32,
            line_end: u32,
            file_hash: u64,
            text: []const u8,
        };
        var parsed = try std.json.parseFromSlice(Row, allocator, line, .{});
        defer parsed.deinit();
        try chunks.append(allocator, .{
            .id = try allocator.dupe(u8, parsed.value.id),
            .path = try allocator.dupe(u8, parsed.value.path),
            .line_start = parsed.value.line_start,
            .line_end = parsed.value.line_end,
            .file_hash = parsed.value.file_hash,
            .text = try allocator.dupe(u8, parsed.value.text),
        });
    }

    const dim: usize = @intCast(manifest_parsed.value.dim);
    const expected_vector_bytes = chunks.items.len * dim * @sizeOf(f32);
    if (vectors_bytes.len < expected_vector_bytes) return emptyIndex(allocator);

    const vector_count = chunks.items.len * dim;
    const vectors = try allocator.alloc(f32, vector_count);
    errdefer allocator.free(vectors);
    @memcpy(std.mem.sliceAsBytes(vectors), vectors_bytes[0 .. vector_count * @sizeOf(f32)]);

    return LoadedIndex{
        .allocator = allocator,
        .dim = manifest_parsed.value.dim,
        .chunks = try chunks.toOwnedSlice(allocator),
        .vectors = vectors,
    };
}

fn emptyIndex(allocator: std.mem.Allocator) LoadedIndex {
    return .{
        .allocator = allocator,
        .dim = @intCast(local_vector.dim),
        .chunks = &.{},
        .vectors = &.{},
    };
}

fn readRelative(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, rel: []const u8) ![]u8 {
    var file = try root.dir.openFile(io, rel, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

test "formatBlock renders semantic hits" {
    const allocator = std.testing.allocator;
    const results = [_]ScoredChunk{
        .{ .path = "auth.zig", .line_start = 1, .line_end = 3, .score = 0.82, .text = "pub fn auth() {}" },
    };
    const block = try formatBlock(allocator, &results);
    defer allocator.free(block.?);
    try std.testing.expect(std.mem.indexOf(u8, block.?, "Semantic codebase search") != null);
}

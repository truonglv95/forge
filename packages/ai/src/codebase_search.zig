const std = @import("std");
const workspace = @import("forge-workspace");
const local_vector = @import("local_vector.zig");
const credentials = @import("credentials.zig");
const gemini_embedder = @import("gemini_embedder.zig");
const ollama_embedder = @import("ollama_embedder.zig");
const ollama_provider = @import("ollama_provider.zig");
const builtin = @import("builtin");

pub const EmbeddingProvider = enum {
    auto,
    gemini,
    ollama,
    local,

    pub fn parse(name: ?[]const u8) EmbeddingProvider {
        const value = name orelse return .auto;
        if (std.mem.eql(u8, value, "gemini")) return .gemini;
        if (std.mem.eql(u8, value, "ollama")) return .ollama;
        if (std.mem.eql(u8, value, "local")) return .local;
        if (std.mem.eql(u8, value, "auto")) return .auto;
        return .auto;
    }
};

pub const EmbeddingOptions = struct {
    provider: EmbeddingProvider = .auto,
    model: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const scope_resolver = @import("scope_resolver.zig");

pub const SearchOptions = struct {
    top_k: usize = 10,
    max_bytes: usize = 24 * 1024,
    prefer_gemini: bool = true,
    embedding: EmbeddingOptions = .{},
    environ_map: ?*const std.process.Environ.Map = null,
    allow_rebuild: bool = true,
    /// Minimum cosine similarity to include a chunk.
    /// When 0 (default), an adaptive threshold of max(0.01, top_score * 0.20) is used.
    score_floor: f32 = 0,
};

pub const ScoredChunk = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
    score: f32,
    text: []const u8,
    symbol: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    language: ?[]const u8 = null,
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
            self.allocator.free(chunk.symbol);
            self.allocator.free(chunk.kind);
            self.allocator.free(chunk.language);
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
    symbol: []const u8,
    kind: []const u8,
    language: []const u8,
};

const EmbedBackend = struct {
    allocator: std.mem.Allocator,
    dim: u32,
    provider_name: []const u8,
    model_name: []const u8,
    embed: *const fn (std.mem.Allocator, []const u8, []f32) anyerror!void,
    creds: ?credentials.Credentials = null,
    ollama_base_url: ?[]u8 = null,

    pub fn deinit(self: *EmbedBackend) void {
        if (self.creds) |*owned| owned.deinit();
        if (self.ollama_base_url) |url| self.allocator.free(url);
    }
};

fn resolveEmbedBackend(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SearchOptions,
) !EmbedBackend {
    if (options.embedding.provider == .ollama) {
        return try resolveOllamaBackend(allocator, io, options);
    }

    if (options.embedding.provider == .auto and options.embedding.url != null) {
        if (resolveOllamaBackend(allocator, io, options)) |backend| return backend else |_| {}
    }

    if (options.embedding.provider != .local and options.prefer_gemini) {
        if (options.environ_map) |map| {
            if (credentials.Credentials.loadGemini(allocator, io, map)) |creds| {
                return .{
                    .allocator = allocator,
                    .dim = @intCast(gemini_embedder.dim),
                    .provider_name = "gemini",
                    .model_name = gemini_embedder.default_model,
                    .embed = geminiEmbedAdapter,
                    .creds = creds,
                };
            } else |_| {}
        }
    }

    return .{
        .allocator = allocator,
        .dim = @intCast(local_vector.dim),
        .provider_name = "local",
        .model_name = "hashed-token-vector",
        .embed = localEmbedAdapter,
    };
}

fn resolveOllamaBackend(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SearchOptions,
) !EmbedBackend {
    const host = try ollama_provider.resolveHost(allocator, options.environ_map, options.embedding.url);
    errdefer allocator.free(host);
    const model = options.embedding.model orelse ollama_embedder.default_model;
    const probe = try ollama_embedder.embedAlloc(allocator, io, .{ .base_url = host, .model = model }, "forge embedding dimension probe");
    defer allocator.free(probe);
    return .{
        .allocator = allocator,
        .dim = @intCast(probe.len),
        .provider_name = "ollama",
        .model_name = model,
        .embed = ollamaEmbedAdapter,
        .ollama_base_url = host,
    };
}

fn localEmbedAdapter(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    return local_vector.embedInto(allocator, text, out);
}

const GeminiEmbedContext = struct {
    io: std.Io,
    creds: *credentials.Credentials,
    task_type: gemini_embedder.TaskType = .retrieval_document,
};

threadlocal var gemini_embed_ctx: ?GeminiEmbedContext = null;

const OllamaEmbedContext = struct {
    io: std.Io,
    base_url: []const u8,
    model: []const u8,
};

threadlocal var ollama_embed_ctx: ?OllamaEmbedContext = null;

/// Adapter used when BUILDING the index — embeds chunks as RETRIEVAL_DOCUMENT.
fn geminiEmbedAdapter(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    const ctx = gemini_embed_ctx orelse return error.ProviderFailed;
    return gemini_embedder.embedIntoWithTaskType(allocator, ctx.io, ctx.creds.*, text, out, .retrieval_document);
}

/// Adapter used at QUERY time — embeds the search query as RETRIEVAL_QUERY.
fn geminiQueryEmbedAdapter(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    const ctx = gemini_embed_ctx orelse return error.ProviderFailed;
    return gemini_embedder.embedIntoWithTaskType(allocator, ctx.io, ctx.creds.*, text, out, .retrieval_query);
}

fn ollamaEmbedAdapter(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    const ctx = ollama_embed_ctx orelse return error.ProviderFailed;
    return ollama_embedder.embedInto(allocator, ctx.io, .{ .base_url = ctx.base_url, .model = ctx.model }, text, out);
}

pub fn ensureIndex(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, options: SearchOptions) !void {
    if (!options.allow_rebuild) return;

    var backend = try resolveEmbedBackend(allocator, io, options);
    defer backend.deinit();

    const embedding_matches = manifestEmbeddingMatches(allocator, io, root, backend) catch false;
    const needs = try workspace.codebase_index.needsRebuild(allocator, io, root);
    if (needs or !embedding_matches) {
        clearSearchCaches(allocator);
        const metadata: workspace.codebase_index.EmbeddingMetadata = .{
            .provider = backend.provider_name,
            .model = backend.model_name,
        };
        const force_full_rebuild = !embedding_matches;
        if (backend.creds) |*owned| {
            gemini_embed_ctx = .{ .io = io, .creds = owned };
            defer gemini_embed_ctx = null;
            _ = if (force_full_rebuild)
                try workspace.codebase_index.buildWithMetadata(allocator, io, root, backend.dim, geminiEmbedAdapter, metadata)
            else
                try workspace.codebase_index.refreshWithMetadata(allocator, io, root, backend.dim, geminiEmbedAdapter, metadata);
        } else if (backend.ollama_base_url) |base_url| {
            ollama_embed_ctx = .{ .io = io, .base_url = base_url, .model = backend.model_name };
            defer ollama_embed_ctx = null;
            _ = if (force_full_rebuild)
                try workspace.codebase_index.buildWithMetadata(allocator, io, root, backend.dim, ollamaEmbedAdapter, metadata)
            else
                try workspace.codebase_index.refreshWithMetadata(allocator, io, root, backend.dim, ollamaEmbedAdapter, metadata);
        } else {
            _ = if (force_full_rebuild)
                try workspace.codebase_index.buildWithMetadata(allocator, io, root, backend.dim, localEmbedAdapter, metadata)
            else
                try workspace.codebase_index.refreshWithMetadata(allocator, io, root, backend.dim, localEmbedAdapter, metadata);
        }
    }
}

const ScoreItem = struct { index: usize, score: f32 };

const IndexCacheEntry = struct {
    fingerprint: u64,
    index: LoadedIndex,
};

var index_cache: ?IndexCacheEntry = null;

const QueryCacheSlot = struct {
    key: u64 = 0,
    dim: u32 = 0,
    vec: ?[]f32 = null,
};

var query_cache_slots: [8]QueryCacheSlot = [_]QueryCacheSlot{.{}} ** 8;
var query_cache_cursor: u8 = 0;

pub fn clearSearchCaches(allocator: std.mem.Allocator) void {
    if (index_cache) |*entry| {
        entry.index.deinit();
        index_cache = null;
    }
    for (&query_cache_slots) |*slot| {
        if (slot.vec) |vec| allocator.free(vec);
        slot.* = .{};
    }
    query_cache_cursor = 0;
}

pub fn search(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    query: []const u8,
    skip_paths: []const []const u8,
    options: SearchOptions,
) ![]ScoredChunk {
    defer if (builtin.is_test) clearSearchCaches(allocator);

    ensureIndex(allocator, io, root, options) catch {};

    var local_index: LoadedIndex = undefined;
    const index: *const LoadedIndex = if (builtin.is_test) blk: {
        local_index = try loadIndex(allocator, io, root);
        break :blk &local_index;
    } else try getOrLoadIndex(allocator, io, root);
    defer if (builtin.is_test) local_index.deinit();
    if (index.chunks.len == 0) return &.{};

    var backend = try resolveEmbedBackend(allocator, io, options);
    defer backend.deinit();

    const query_vec = try allocator.alloc(f32, index.dim);
    defer allocator.free(query_vec);
    @memset(query_vec, 0);

    try embedQueryCached(allocator, io, &backend, query, index.dim, query_vec);

    var scores: std.ArrayList(ScoreItem) = .empty;
    defer scores.deinit(allocator);

    const dim: usize = @intCast(index.dim);
    for (index.chunks, 0..) |chunk, chunk_index| {
        if (shouldSkip(chunk.path, skip_paths)) continue;
        const offset = chunk_index * dim;
        if (offset + dim > index.vectors.len) continue;
        const vec = index.vectors[offset .. offset + dim];
        const score = cosineSlices(query_vec, vec);
        if (score <= 0.001) continue; // pre-filter obvious misses only
        try scores.append(allocator, .{ .index = chunk_index, .score = score });
    }

    std.sort.pdq(ScoreItem, scores.items, {}, struct {
        fn less(_: void, a: ScoreItem, b: ScoreItem) bool {
            return a.score > b.score;
        }
    }.less);

    // Adaptive threshold: keep chunks within 20% of top score.
    // Falls back to a fixed floor when caller sets score_floor explicitly.
    const effective_floor = if (options.score_floor > 0)
        options.score_floor
    else if (scores.items.len > 0)
        @max(@as(f32, 0.01), scores.items[0].score * 0.20)
    else
        @as(f32, 0.01);

    // Remove items below the adaptive threshold.
    var write: usize = 0;
    for (scores.items) |item| {
        if (item.score >= effective_floor) {
            scores.items[write] = item;
            write += 1;
        }
    }
    scores.shrinkRetainingCapacity(write);

    const take = @min(options.top_k, scores.items.len);
    var out: std.ArrayList(ScoredChunk) = .empty;
    var selected_bytes: usize = 0;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.path);
            allocator.free(item.text);
            if (item.symbol) |value| allocator.free(value);
            if (item.kind) |value| allocator.free(value);
            if (item.language) |value| allocator.free(value);
        }
        out.deinit(allocator);
    }

    for (scores.items[0..take]) |item| {
        const chunk = index.chunks[item.index];
        if (out.items.len > 0 and selected_bytes + chunk.text.len > options.max_bytes) break;
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, chunk.path),
            .line_start = chunk.line_start,
            .line_end = chunk.line_end,
            .score = item.score,
            .text = try allocator.dupe(u8, chunk.text),
            .symbol = try allocator.dupe(u8, chunk.symbol),
            .kind = try allocator.dupe(u8, chunk.kind),
            .language = try allocator.dupe(u8, chunk.language),
        });
        selected_bytes += chunk.text.len;
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
        if (item.symbol) |value| allocator.free(value);
        if (item.kind) |value| allocator.free(value);
        if (item.language) |value| allocator.free(value);
    }
    allocator.free(results);
}

pub fn formatBlock(allocator: std.mem.Allocator, results: []const ScoredChunk) !?[]const u8 {
    if (results.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Semantic codebase search\n\n");

    for (results) |item| {
        const section = try std.fmt.allocPrint(allocator, "## {s}:{d}-{d} [{s}/{s} {s}] (score {d:.3})\n```\n{s}\n```\n\n", .{
            item.path,
            item.line_start,
            item.line_end,
            item.kind orelse "chunk",
            item.language orelse "text",
            item.symbol orelse "",
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

fn manifestEmbeddingMatches(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, backend: EmbedBackend) !bool {
    const manifest_bytes = ((blk: {
        const p = workspace.codebase_index.getManifestFile(allocator, io, root) catch return false;
        defer allocator.free(p);
        break :blk workspace.global_store.readAbsoluteFile(allocator, io, p);
    }) catch return false);
    defer allocator.free(manifest_bytes);

    const ManifestJson = struct {
        dim: u32,
        embedding_provider: []const u8 = "",
        embedding_model: []const u8 = "",
    };
    var manifest_parsed = try std.json.parseFromSlice(ManifestJson, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    return manifest_parsed.value.dim == backend.dim and
        std.mem.eql(u8, manifest_parsed.value.embedding_provider, backend.provider_name) and
        std.mem.eql(u8, manifest_parsed.value.embedding_model, backend.model_name);
}

fn loadIndex(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !LoadedIndex {
    const manifest_bytes = ((blk: {
        const p = workspace.codebase_index.getManifestFile(allocator, io, root) catch return emptyIndex(allocator);
        defer allocator.free(p);
        break :blk workspace.global_store.readAbsoluteFile(allocator, io, p);
    }) catch return emptyIndex(allocator));
    defer allocator.free(manifest_bytes);

    const ManifestJson = struct {
        dim: u32,
        chunk_count: u32,
    };
    var manifest_parsed = try std.json.parseFromSlice(ManifestJson, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();

    const chunks_bytes = ((blk: {
        const p = workspace.codebase_index.getChunksFile(allocator, io, root) catch return emptyIndex(allocator);
        defer allocator.free(p);
        break :blk workspace.global_store.readAbsoluteFile(allocator, io, p);
    }) catch return emptyIndex(allocator));
    defer allocator.free(chunks_bytes);

    const vectors_bytes = ((blk: {
        const p = workspace.codebase_index.getVectorsFile(allocator, io, root) catch return emptyIndex(allocator);
        defer allocator.free(p);
        break :blk workspace.global_store.readAbsoluteFile(allocator, io, p);
    }) catch return emptyIndex(allocator));
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
            symbol: []const u8 = "",
            kind: []const u8 = "line_window",
            language: []const u8 = "text",
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
            .symbol = try allocator.dupe(u8, parsed.value.symbol),
            .kind = try allocator.dupe(u8, parsed.value.kind),
            .language = try allocator.dupe(u8, parsed.value.language),
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

fn indexFingerprint(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !?u64 {
    const manifest_bytes = ((blk: {
        const p = workspace.codebase_index.getManifestFile(allocator, io, root) catch return null;
        defer allocator.free(p);
        break :blk workspace.global_store.readAbsoluteFile(allocator, io, p);
    }) catch return null);
    defer allocator.free(manifest_bytes);
    return std.hash.Wyhash.hash(0, manifest_bytes);
}

fn getOrLoadIndex(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !*const LoadedIndex {
    const fingerprint = indexFingerprint(allocator, io, root) catch null orelse 0;
    if (index_cache) |*entry| {
        if (entry.fingerprint == fingerprint) return &entry.index;
        entry.index.deinit();
        index_cache = null;
    }
    const loaded = try loadIndex(allocator, io, root);
    index_cache = .{ .fingerprint = fingerprint, .index = loaded };
    return &index_cache.?.index;
}

fn hashQuery(query: []const u8, dim: u32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(query);
    hasher.update(std.mem.asBytes(&dim));
    return hasher.final();
}

fn embedQueryCached(
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: *EmbedBackend,
    query: []const u8,
    dim: u32,
    out: []f32,
) !void {
    const key = hashQuery(query, dim);
    if (!builtin.is_test) {
        for (query_cache_slots) |slot| {
            if (slot.key == key and slot.dim == dim) {
                if (slot.vec) |cached| {
                    @memcpy(out, cached[0..@min(out.len, cached.len)]);
                    return;
                }
            }
        }
    }

    // Use RETRIEVAL_QUERY task type for query embeddings so Gemini
    // optimises them for retrieval against RETRIEVAL_DOCUMENT chunks.
    if (backend.creds) |*owned| {
        gemini_embed_ctx = .{ .io = io, .creds = owned };
        defer gemini_embed_ctx = null;
        try geminiQueryEmbedAdapter(allocator, query, out);
    } else if (backend.ollama_base_url) |base_url| {
        ollama_embed_ctx = .{ .io = io, .base_url = base_url, .model = backend.model_name };
        defer ollama_embed_ctx = null;
        try ollamaEmbedAdapter(allocator, query, out);
    } else {
        try localEmbedAdapter(allocator, query, out);
    }

    const owned = try allocator.dupe(f32, out);
    if (!builtin.is_test) {
        const slot = &query_cache_slots[query_cache_cursor % query_cache_slots.len];
        query_cache_cursor +%= 1;
        if (slot.vec) |old| allocator.free(old);
        slot.* = .{ .key = key, .dim = dim, .vec = owned };
    } else {
        allocator.free(owned);
    }
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

test "local semantic index achieves recall at one on symbol corpus" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("auth.zig"),
        \\/// Validate user credentials and create a login session.
        \\pub fn authenticateUserSession() void {}
    );
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("recovery.zig"),
        \\/// Restore transaction backups after an interrupted apply.
        \\pub fn recoverPendingTransaction() void {}
    );
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("renderer.zig"),
        \\/// Draw editor tabs and colored layout rectangles.
        \\pub fn renderEditorLayout() void {}
    );
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("billing.py"),
        \\# Calculate invoice totals and apply customer discounts.
        \\def calculate_invoice_total(items):
        \\    return sum(items)
    );
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("router.ts"),
        \\// Register HTTP routes and dispatch incoming requests.
        \\export function registerHttpRoutes() { return true; }
    );

    const Query = struct { text: []const u8, expected: []const u8 };
    const corpus = [_]Query{
        .{ .text = "authentication login for a user", .expected = "auth.zig" },
        .{ .text = "recover interrupted transaction backup", .expected = "recovery.zig" },
        .{ .text = "draw editor tab layout", .expected = "renderer.zig" },
        .{ .text = "calculate customer invoice total", .expected = "billing.py" },
        .{ .text = "register and dispatch HTTP routes", .expected = "router.ts" },
    };
    var recalled: usize = 0;
    for (corpus) |query| {
        const results = try search(allocator, io, root, query.text, &.{}, .{
            .top_k = 1,
            .prefer_gemini = false,
        });
        defer freeResults(allocator, results);
        if (results.len == 1 and std.mem.eql(u8, results[0].path, query.expected)) recalled += 1;
    }
    try std.testing.expectEqual(corpus.len, recalled);
}

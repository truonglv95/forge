const std = @import("std");
const workspace = @import("forge-workspace");
const local_vector = @import("local_vector.zig");
const credentials = @import("credentials.zig");
const gemini_embedder = @import("providers/gemini/embedder.zig");
const ollama_embedder = @import("providers/ollama/embedder.zig");
const ollama_provider = @import("providers/ollama/provider.zig");
const builtin = @import("builtin");

pub const EmbeddingProvider = enum {
    auto,
    gemini,
    ollama,
    local,
    openrouter,

    pub fn parse(name: ?[]const u8) EmbeddingProvider {
        const value = name orelse return .auto;
        if (std.mem.eql(u8, value, "gemini")) return .gemini;
        if (std.mem.eql(u8, value, "ollama")) return .ollama;
        if (std.mem.eql(u8, value, "openrouter")) return .openrouter;
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
    enable_hyde: bool = false,
    hyde_text_generator: ?*const fn (allocator: std.mem.Allocator, ctx: ?*anyopaque, prompt: []const u8) anyerror![]u8 = null,
    hyde_text_generator_ctx: ?*anyopaque = null,
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
    vectors: []u8,

    pub fn deinit(self: *LoadedIndex) void {
        for (self.chunks) |chunk| {
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
    path: []const u8,
    line_start: u32,
    line_end: u32,
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

    if (options.embedding.provider == .openrouter) {
        return try resolveOpenrouterBackend(allocator, io, options);
    }

    if (options.embedding.provider == .auto and options.embedding.url != null) {
        if (resolveOllamaBackend(allocator, io, options)) |backend| return backend else |_| {}
    }

    if (options.embedding.provider != .local and options.prefer_gemini) {
        if (options.environ_map) |map| {
            if (credentials.Credentials.load(allocator, io, map, &[_][]const u8{ "GEMINI_API_KEY", "GOOGLE_API_KEY" }, "forge-gemini", "default")) |creds_val| {
                return .{
                    .allocator = allocator,
                    .dim = @intCast(gemini_embedder.dim),
                    .provider_name = "gemini",
                    .model_name = gemini_embedder.default_model,
                    .embed = geminiEmbedAdapter,
                    .creds = creds_val,
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

const openrouter_embedder = @import("providers/openrouter/embedder.zig");
fn resolveOpenrouterBackend(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SearchOptions,
) !EmbedBackend {
    var creds = try credentials.Credentials.load(
        allocator,
        io,
        options.environ_map orelse return error.MissingCredentials,
        &[_][]const u8{"OPENROUTER_API_KEY"},
        "forge-openrouter",
        "default",
    );
    errdefer creds.deinit();

    const host = if (options.embedding.url) |u| try allocator.dupe(u8, u) else try allocator.dupe(u8, openrouter_embedder.default_url);
    errdefer allocator.free(host);

    const model = options.embedding.model orelse openrouter_embedder.default_model;
    const probe = try openrouter_embedder.embedAlloc(allocator, io, .{ .base_url = host, .model = model, .api_key = creds.api_key }, "forge embedding dimension probe");
    defer allocator.free(probe);

    return .{
        .allocator = allocator,
        .dim = @intCast(probe.len),
        .provider_name = "openrouter",
        .model_name = model,
        .embed = openrouterEmbedAdapter,
        .ollama_base_url = host,
        .creds = creds,
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

const OpenrouterEmbedContext = struct {
    io: std.Io,
    base_url: []const u8,
    model: []const u8,
    api_key: []const u8,
};

threadlocal var openrouter_embed_ctx: ?OpenrouterEmbedContext = null;

fn openrouterEmbedAdapter(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    const ctx = openrouter_embed_ctx orelse return error.ProviderFailed;
    return openrouter_embedder.embedInto(allocator, ctx.io, .{ .base_url = ctx.base_url, .model = ctx.model, .api_key = ctx.api_key }, text, out);
}

pub fn ensureIndex(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, options: SearchOptions) !void {
    if (!options.allow_rebuild) return;

    var backend = try resolveEmbedBackend(allocator, io, options);
    defer backend.deinit();

    const backend_hash = hashEmbeddingBackend(backend);
    const fingerprint = indexFingerprint(allocator, io, root) catch null orelse 0;
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    if (!builtin.is_test and index_health_cache.fresh and
        index_health_cache.fingerprint == fingerprint and
        index_health_cache.backend_hash == backend_hash and
        now_ms - index_health_cache.checked_ms < 3000)
    {
        return;
    }

    const embedding_matches = manifestEmbeddingMatches(allocator, io, root, backend) catch false;
    const needs = try workspace.codebase_index.needsRebuild(allocator, io, root);
    if (!needs and embedding_matches) {
        index_health_cache = .{
            .fingerprint = fingerprint,
            .backend_hash = backend_hash,
            .checked_ms = now_ms,
            .fresh = true,
        };
    }
    if (needs or !embedding_matches) {
        clearSearchCaches(allocator);
        const metadata: workspace.codebase_index.EmbeddingMetadata = .{
            .provider = backend.provider_name,
            .model = backend.model_name,
        };
        const force_full_rebuild = !embedding_matches;
        if (std.mem.eql(u8, backend.provider_name, "gemini")) {
            gemini_embed_ctx = .{ .io = io, .creds = &backend.creds.? };
            defer gemini_embed_ctx = null;
            _ = if (force_full_rebuild)
                try workspace.codebase_index.buildWithMetadata(allocator, io, root, backend.dim, geminiEmbedAdapter, metadata)
            else
                try workspace.codebase_index.refreshWithMetadata(allocator, io, root, backend.dim, geminiEmbedAdapter, metadata);
        } else if (std.mem.eql(u8, backend.provider_name, "openrouter")) {
            openrouter_embed_ctx = .{
                .io = io,
                .base_url = backend.ollama_base_url orelse return error.InvalidProviderState,
                .model = backend.model_name,
                .api_key = backend.creds.?.api_key,
            };
            defer openrouter_embed_ctx = null;
            _ = if (force_full_rebuild)
                try workspace.codebase_index.buildWithMetadata(allocator, io, root, backend.dim, openrouterEmbedAdapter, metadata)
            else
                try workspace.codebase_index.refreshWithMetadata(allocator, io, root, backend.dim, openrouterEmbedAdapter, metadata);
        } else if (std.mem.eql(u8, backend.provider_name, "ollama")) {
            ollama_embed_ctx = .{ .io = io, .base_url = backend.ollama_base_url.?, .model = backend.model_name };
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
        const refreshed_fingerprint = indexFingerprint(allocator, io, root) catch null orelse 0;
        index_health_cache = .{
            .fingerprint = refreshed_fingerprint,
            .backend_hash = backend_hash,
            .checked_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
            .fresh = true,
        };
    }
}

fn hashEmbeddingBackend(backend: EmbedBackend) u64 {
    var hasher = std.hash.Wyhash.init(0x4652475f454d4244);
    hasher.update(backend.provider_name);
    hasher.update("\n");
    hasher.update(backend.model_name);
    hasher.update("\n");
    if (backend.ollama_base_url) |url| hasher.update(url);
    hasher.update(std.mem.asBytes(&backend.dim));
    return hasher.final();
}

const ScoreItem = struct { index: usize, score: f32 };

const IndexCacheEntry = struct {
    fingerprint: u64,
    index: LoadedIndex,
};

var index_cache: ?IndexCacheEntry = null;

const IndexHealthCache = struct {
    fingerprint: u64 = 0,
    backend_hash: u64 = 0,
    checked_ms: i64 = 0,
    fresh: bool = false,
};

var index_health_cache: IndexHealthCache = .{};

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
    index_health_cache = .{};
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

    var effective_query: []const u8 = query;
    var hyde_expanded: ?[]u8 = null;
    if (options.enable_hyde and options.environ_map != null) {
        if (generateHydeQuery(allocator, io, options, query)) |expanded| {
            hyde_expanded = expanded;
            effective_query = expanded;
        } else |_| {} // fallback to standard query on failure
    }
    defer if (hyde_expanded) |expanded| allocator.free(expanded);

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

    try embedQueryCached(allocator, io, &backend, effective_query, index.dim, query_vec);
    const query_norm_sq = normSquared(query_vec);
    if (query_norm_sq == 0) return &.{};

    var scores: std.ArrayList(ScoreItem) = .empty;
    defer scores.deinit(allocator);
    const score_cap = @max(options.top_k * 4, @as(usize, 64));

    const dim: usize = @intCast(index.dim);
    for (index.chunks, 0..) |chunk, chunk_index| {
        if (shouldSkip(chunk.path, skip_paths)) continue;
        const offset = chunk_index * dim * @sizeOf(f32);
        const byte_len = dim * @sizeOf(f32);
        if (offset + byte_len > index.vectors.len) continue;
        const vec = index.vectors[offset .. offset + byte_len];
        const score = cosineBytesWithNorm(query_vec, query_norm_sq, vec);
        if (score <= 0.001) continue; // pre-filter obvious misses only
        try insertTopScore(allocator, &scores, .{ .index = chunk_index, .score = score }, score_cap);
    }

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

fn normSquared(values: []const f32) f32 {
    var total: f32 = 0;
    for (values) |value| total += value * value;
    return total;
}

fn cosineBytes(a: []const f32, b_bytes: []const u8) f32 {
    return cosineBytesWithNorm(a, normSquared(a), b_bytes);
}

fn cosineBytesWithNorm(a: []const f32, a_norm_sq: f32, b_bytes: []const u8) f32 {
    const len = @min(a.len, b_bytes.len / @sizeOf(f32));
    var dot: f32 = 0;
    var nb: f32 = 0;
    for (0..len) |i| {
        const start = i * @sizeOf(f32);
        const bits = std.mem.readInt(u32, b_bytes[start..][0..4], .little);
        const b: f32 = @bitCast(bits);
        dot += a[i] * b;
        nb += b * b;
    }
    const denom = @sqrt(a_norm_sq * nb);
    if (denom == 0) return 0;
    return dot / denom;
}

fn insertTopScore(allocator: std.mem.Allocator, scores: *std.ArrayList(ScoreItem), item: ScoreItem, cap: usize) !void {
    if (cap == 0) return;
    if (scores.items.len == cap and item.score <= scores.items[scores.items.len - 1].score) return;

    var pos: usize = 0;
    while (pos < scores.items.len and scores.items[pos].score >= item.score) : (pos += 1) {}

    if (scores.items.len < cap) {
        try scores.append(allocator, item);
        var i = scores.items.len - 1;
        while (i > pos) : (i -= 1) {
            scores.items[i] = scores.items[i - 1];
        }
        scores.items[pos] = item;
        return;
    }

    var i = scores.items.len - 1;
    while (i > pos) : (i -= 1) {
        scores.items[i] = scores.items[i - 1];
    }
    scores.items[pos] = item;
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
    errdefer allocator.free(vectors_bytes);

    var chunks: std.ArrayList(StoredChunk) = .empty;
    errdefer {
        for (chunks.items) |chunk| {
            allocator.free(chunk.path);
            allocator.free(chunk.text);
            allocator.free(chunk.symbol);
            allocator.free(chunk.kind);
            allocator.free(chunk.language);
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
            .path = try allocator.dupe(u8, parsed.value.path),
            .line_start = parsed.value.line_start,
            .line_end = parsed.value.line_end,
            .text = try allocator.dupe(u8, parsed.value.text),
            .symbol = try allocator.dupe(u8, parsed.value.symbol),
            .kind = try allocator.dupe(u8, parsed.value.kind),
            .language = try allocator.dupe(u8, parsed.value.language),
        });
    }

    const dim: usize = @intCast(manifest_parsed.value.dim);
    const expected_vector_bytes = chunks.items.len * dim * @sizeOf(f32);
    if (vectors_bytes.len < expected_vector_bytes) {
        for (chunks.items) |chunk| {
            allocator.free(chunk.path);
            allocator.free(chunk.text);
            allocator.free(chunk.symbol);
            allocator.free(chunk.kind);
            allocator.free(chunk.language);
        }
        chunks.deinit(allocator);
        allocator.free(vectors_bytes);
        return emptyIndex(allocator);
    }

    return LoadedIndex{
        .allocator = allocator,
        .dim = manifest_parsed.value.dim,
        .chunks = try chunks.toOwnedSlice(allocator),
        .vectors = vectors_bytes,
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
    if (std.mem.eql(u8, backend.provider_name, "gemini")) {
        gemini_embed_ctx = .{ .io = io, .creds = &backend.creds.? };
        defer gemini_embed_ctx = null;
        try geminiQueryEmbedAdapter(allocator, query, out);
    } else if (std.mem.eql(u8, backend.provider_name, "openrouter")) {
        openrouter_embed_ctx = .{
            .io = io,
            .base_url = backend.ollama_base_url orelse return error.InvalidProviderState,
            .model = backend.model_name,
            .api_key = backend.creds.?.api_key,
        };
        defer openrouter_embed_ctx = null;
        try openrouterEmbedAdapter(allocator, query, out);
    } else if (std.mem.eql(u8, backend.provider_name, "ollama")) {
        ollama_embed_ctx = .{ .io = io, .base_url = backend.ollama_base_url.?, .model = backend.model_name };
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

fn generateHydeQuery(allocator: std.mem.Allocator, io: std.Io, options: SearchOptions, query: []const u8) ![]u8 {
    _ = io;
    if (options.hyde_text_generator) |generator| {
        const prompt = try std.fmt.allocPrint(allocator, "Write a hypothetical code snippet that answers this query. Only return code, no markdown block, no explanation. Query: {s}", .{query});
        defer allocator.free(prompt);

        const text = generator(allocator, options.hyde_text_generator_ctx, prompt) catch return error.ProviderFailed;
        defer allocator.free(text);

        return try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ query, text });
    }
    return error.HydeNotConfigured;
}

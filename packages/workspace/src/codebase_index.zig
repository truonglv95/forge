const std = @import("std");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");
const edit = @import("edit.zig");
const tree = @import("tree.zig");
const ignore = @import("ignore.zig");
const atomic = @import("atomic.zig");

pub const index_dir = ".forge/index/v1";
pub const chunks_file = ".forge/index/v1/chunks.jsonl";
pub const vectors_file = ".forge/index/v1/vectors.bin";
pub const manifest_file = ".forge/index/v1/manifest.json";
pub const file_hashes_file = ".forge/index/v1/file_hashes.json";

pub const max_chunk_lines: u32 = 48;
pub const max_chunk_bytes: usize = 2048;
pub const max_files: u32 = 800;
pub const max_chunks: u32 = 2500;

pub const Chunk = struct {
    id: []const u8,
    path: []const u8,
    line_start: u32,
    line_end: u32,
    file_hash: u64,
    text: []const u8,
};

pub const Manifest = struct {
    schema_version: u32 = 1,
    dim: u32,
    chunk_count: u32,
    built_ms: i64,
};

pub const BuildResult = struct {
    chunk_count: u32,
    file_count: u32,
};

pub const IndexError = error{
    IndexMissing,
};

pub fn chunkContent(allocator: std.mem.Allocator, path: []const u8, file_hash: u64, content: []const u8) ![]Chunk {
    var chunks: std.ArrayList(Chunk) = .empty;
    errdefer {
        for (chunks.items) |chunk| freeChunk(allocator, chunk);
        chunks.deinit(allocator);
    }

    var line_start: u32 = 1;
    var line_end: u32 = 0;
    var chunk_start_idx: usize = 0;
    var chunk_bytes: usize = 0;
    var line_start_idx: usize = 0;

    for (content, 0..) |byte, index| {
        if (byte == '\n') {
            line_end += 1;
            const line_len = index - line_start_idx + 1;
            chunk_bytes += line_len;

            const lines_in_chunk = line_end - line_start + 1;
            if (lines_in_chunk >= max_chunk_lines or chunk_bytes >= max_chunk_bytes) {
                try appendChunk(allocator, &chunks, path, file_hash, content, line_start, line_end, chunk_start_idx, index + 1);
                line_start = line_end + 1;
                chunk_start_idx = index + 1;
                chunk_bytes = 0;
            }
            line_start_idx = index + 1;
        }
    }

    if (chunk_start_idx < content.len or line_start <= line_end) {
        if (line_end < line_start) line_end = line_start;
        try appendChunk(allocator, &chunks, path, file_hash, content, line_start, line_end, chunk_start_idx, content.len);
    } else if (content.len == 0) {
        try appendChunk(allocator, &chunks, path, file_hash, content, 1, 1, 0, 0);
    }

    return try chunks.toOwnedSlice(allocator);
}

fn appendChunk(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Chunk),
    path: []const u8,
    file_hash: u64,
    content: []const u8,
    line_start: u32,
    line_end: u32,
    start_idx: usize,
    end_idx: usize,
) !void {
    const text = try allocator.dupe(u8, content[start_idx..end_idx]);
    errdefer allocator.free(text);
    var id_buf: [512]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{s}:{d}:{d}", .{ path, line_start, line_end });
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    try out.append(allocator, .{
        .id = owned_id,
        .path = try allocator.dupe(u8, path),
        .line_start = line_start,
        .line_end = line_end,
        .file_hash = file_hash,
        .text = text,
    });
}

pub fn freeChunk(allocator: std.mem.Allocator, chunk: Chunk) void {
    allocator.free(chunk.id);
    allocator.free(chunk.path);
    allocator.free(chunk.text);
}

pub fn freeChunks(allocator: std.mem.Allocator, chunks: []Chunk) void {
    for (chunks) |chunk| freeChunk(allocator, chunk);
    allocator.free(chunks);
}

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    vector_dim: u32,
    embedFn: *const fn (std.mem.Allocator, []const u8, []f32) anyerror!void,
) !BuildResult {
    try root.dir.createDirPath(io, index_dir);

    var summary = try tree.scan(allocator, io, root, ".");
    defer summary.deinit();

    var all_chunks: std.ArrayList(Chunk) = .empty;
    errdefer freeChunks(allocator, all_chunks.items);
    errdefer all_chunks.deinit(allocator);

    var file_count: u32 = 0;
    var hash_lines: std.ArrayList(u8) = .empty;
    defer hash_lines.deinit(allocator);

    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (file_count >= max_files or all_chunks.items.len >= max_chunks) break;
        if (std.mem.startsWith(u8, entry.path, ".forge/")) continue;
        if (std.mem.endsWith(u8, entry.path, ".proposal.json")) continue;

        var skip = false;
        var it = std.mem.splitScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |component| {
            if (ignore.IgnoreRules.isIgnored(component)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        const wp = try path_mod.WorkspacePath.parse(entry.path);
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();
        if (snap.content.len > ignore.Limits.max_file_size) continue;
        if (!std.unicode.utf8ValidateSlice(snap.content)) continue;

        const file_chunks = try chunkContent(allocator, entry.path, snap.hash, snap.content);
        defer freeChunks(allocator, file_chunks);
        for (file_chunks) |chunk| {
            if (all_chunks.items.len >= max_chunks) break;
            try all_chunks.append(allocator, .{
                .id = try allocator.dupe(u8, chunk.id),
                .path = try allocator.dupe(u8, chunk.path),
                .line_start = chunk.line_start,
                .line_end = chunk.line_end,
                .file_hash = chunk.file_hash,
                .text = try allocator.dupe(u8, chunk.text),
            });
        }
        file_count += 1;

        const hash_line = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"hash\":{d}}}\n", .{ entry.path, snap.hash });
        defer allocator.free(hash_line);
        try hash_lines.appendSlice(allocator, hash_line);
    }

    var chunks_buf: std.ArrayList(u8) = .empty;
    defer chunks_buf.deinit(allocator);
    for (all_chunks.items) |chunk| {
        const line_prefix = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"path\":\"{s}\",\"line_start\":{d},\"line_end\":{d},\"file_hash\":{d},\"text\":", .{
            chunk.id, chunk.path, chunk.line_start, chunk.line_end, chunk.file_hash,
        });
        defer allocator.free(line_prefix);
        try chunks_buf.appendSlice(allocator, line_prefix);
        try appendJsonString(allocator, &chunks_buf, chunk.text);
        try chunks_buf.appendSlice(allocator, "}\n");
    }

    var vectors_buf: std.ArrayList(u8) = .empty;
    defer vectors_buf.deinit(allocator);
    const vec = try allocator.alloc(f32, vector_dim);
    defer allocator.free(vec);
    for (all_chunks.items) |chunk| {
        @memset(vec, 0);
        try embedFn(allocator, chunk.text, vec);
        const bytes = std.mem.sliceAsBytes(vec);
        try vectors_buf.appendSlice(allocator, bytes);
    }

    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(chunks_file), chunks_buf.items);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(vectors_file), vectors_buf.items);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(file_hashes_file), hash_lines.items);

    const built_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var manifest_buf: [256]u8 = undefined;
    const manifest_text = try std.fmt.bufPrint(&manifest_buf, "{{\"schema_version\":1,\"dim\":{d},\"chunk_count\":{d},\"built_ms\":{d}}}\n", .{
        vector_dim,
        all_chunks.items.len,
        built_ms,
    });
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(manifest_file), manifest_text);

    const count: u32 = @intCast(all_chunks.items.len);
    for (all_chunks.items) |chunk| freeChunk(allocator, chunk);
    all_chunks.deinit(allocator);

    return .{ .chunk_count = count, .file_count = file_count };
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

pub fn needsRebuild(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !bool {
    _ = readRelative(allocator, io, root, manifest_file) catch return true;
    const hashes = readRelative(allocator, io, root, file_hashes_file) catch return true;
    defer allocator.free(hashes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var stored = std.StringHashMap(u64).init(arena.allocator());

    var lines = std.mem.splitScalar(u8, hashes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const Row = struct { path: []const u8, hash: u64 };
        var parsed = std.json.parseFromSlice(Row, allocator, line, .{}) catch return true;
        defer parsed.deinit();
        try stored.put(parsed.value.path, parsed.value.hash);
    }

    var summary = try tree.scan(allocator, io, root, ".");
    defer summary.deinit();

    var checked: u32 = 0;
    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, ".forge/")) continue;
        if (checked >= max_files) break;

        var skip = false;
        var it = std.mem.splitScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |component| {
            if (ignore.IgnoreRules.isIgnored(component)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        checked += 1;
        const wp = try path_mod.WorkspacePath.parse(entry.path);
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();

        const prev = stored.get(entry.path) orelse return true;
        if (prev != snap.hash) return true;
    }
    return false;
}

pub fn collectStalePaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
) ![]const []const u8 {
    _ = readRelative(allocator, io, root, manifest_file) catch return IndexError.IndexMissing;
    const hashes = readRelative(allocator, io, root, file_hashes_file) catch return IndexError.IndexMissing;
    defer allocator.free(hashes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var stored = std.StringHashMap(u64).init(arena.allocator());

    var lines = std.mem.splitScalar(u8, hashes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const Row = struct { path: []const u8, hash: u64 };
        var parsed = try std.json.parseFromSlice(Row, allocator, line, .{});
        defer parsed.deinit();
        try stored.put(parsed.value.path, parsed.value.hash);
    }

    var stale: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (stale.items) |path| allocator.free(path);
        stale.deinit(allocator);
    }

    var summary = try tree.scan(allocator, io, root, ".");
    defer summary.deinit();

    var seen = std.StringHashMap(void).init(arena.allocator());
    var checked: u32 = 0;
    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, ".forge/")) continue;
        if (checked >= max_files) break;

        var skip = false;
        var it = std.mem.splitScalar(u8, entry.path, std.fs.path.sep);
        while (it.next()) |component| {
            if (ignore.IgnoreRules.isIgnored(component)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        checked += 1;
        try seen.put(entry.path, {});
        const wp = try path_mod.WorkspacePath.parse(entry.path);
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();

        const prev = stored.get(entry.path) orelse {
            try stale.append(allocator, try allocator.dupe(u8, entry.path));
            continue;
        };
        if (prev != snap.hash) {
            try stale.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    var stored_it = stored.iterator();
    while (stored_it.next()) |entry| {
        if (!seen.contains(entry.key_ptr.*)) {
            try stale.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
        }
    }

    return try stale.toOwnedSlice(allocator);
}

pub fn freeStalePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

const LoadedChunk = struct {
    chunk: Chunk,
    vector: []f32,
};

pub fn refresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    vector_dim: u32,
    embedFn: *const fn (std.mem.Allocator, []const u8, []f32) anyerror!void,
) !BuildResult {
    if (!(try needsRebuild(allocator, io, root))) {
        const manifest_bytes = readRelative(allocator, io, root, manifest_file) catch return try build(allocator, io, root, vector_dim, embedFn);
        defer allocator.free(manifest_bytes);
        const ManifestJson = struct { chunk_count: u32, file_count: u32 };
        var parsed = try std.json.parseFromSlice(ManifestJson, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        return .{
            .chunk_count = parsed.value.chunk_count,
            .file_count = parsed.value.file_count,
        };
    }

    const stale_paths = collectStalePaths(allocator, io, root) catch {
        return try build(allocator, io, root, vector_dim, embedFn);
    };
    defer freeStalePaths(allocator, stale_paths);

    if (stale_paths.len == 0) {
        return try build(allocator, io, root, vector_dim, embedFn);
    }

    if (stale_paths.len > 64) {
        return try build(allocator, io, root, vector_dim, embedFn);
    }

    return updateIncremental(allocator, io, root, vector_dim, embedFn, stale_paths) catch {
        return try build(allocator, io, root, vector_dim, embedFn);
    };
}

fn updateIncremental(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    vector_dim: u32,
    embedFn: *const fn (std.mem.Allocator, []const u8, []f32) anyerror!void,
    stale_paths: []const []const u8,
) !BuildResult {
    var stale_set = std.StringHashMap(void).init(allocator);
    defer stale_set.deinit();
    for (stale_paths) |path| try stale_set.put(path, {});

    var loaded = try loadExistingIndex(allocator, io, root, vector_dim);
    defer freeLoadedIndex(allocator, &loaded);

    var kept: std.ArrayList(LoadedChunk) = .empty;
    errdefer {
        for (kept.items) |item| {
            freeChunk(allocator, item.chunk);
            allocator.free(item.vector);
        }
        kept.deinit(allocator);
    }

    for (loaded.items) |item| {
        if (stale_set.contains(item.chunk.path)) continue;
        const wp = path_mod.WorkspacePath.parse(item.chunk.path) catch continue;
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();
        if (snap.hash != item.chunk.file_hash) continue;

        const vector = try allocator.alloc(f32, vector_dim);
        errdefer allocator.free(vector);
        @memcpy(vector, item.vector);

        try kept.append(allocator, .{
            .chunk = .{
                .id = try allocator.dupe(u8, item.chunk.id),
                .path = try allocator.dupe(u8, item.chunk.path),
                .line_start = item.chunk.line_start,
                .line_end = item.chunk.line_end,
                .file_hash = item.chunk.file_hash,
                .text = try allocator.dupe(u8, item.chunk.text),
            },
            .vector = vector,
        });
    }

    var hash_lines: std.ArrayList(u8) = .empty;
    defer hash_lines.deinit(allocator);

    for (stale_paths) |path| {
        const wp = path_mod.WorkspacePath.parse(path) catch continue;
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();
        if (snap.content.len > ignore.Limits.max_file_size) continue;
        if (!std.unicode.utf8ValidateSlice(snap.content)) continue;

        const file_chunks = try chunkContent(allocator, path, snap.hash, snap.content);
        defer freeChunks(allocator, file_chunks);

        for (file_chunks) |chunk| {
            if (kept.items.len >= max_chunks) break;
            const vector = try allocator.alloc(f32, vector_dim);
            errdefer allocator.free(vector);
            @memset(vector, 0);
            try embedFn(allocator, chunk.text, vector);
            try kept.append(allocator, .{
                .chunk = .{
                    .id = try allocator.dupe(u8, chunk.id),
                    .path = try allocator.dupe(u8, chunk.path),
                    .line_start = chunk.line_start,
                    .line_end = chunk.line_end,
                    .file_hash = chunk.file_hash,
                    .text = try allocator.dupe(u8, chunk.text),
                },
                .vector = vector,
            });
        }
    }

    var unique_paths = std.StringHashMap(void).init(allocator);
    defer unique_paths.deinit();
    for (kept.items) |item| {
        try unique_paths.put(item.chunk.path, {});
    }
    const file_count: u32 = @intCast(unique_paths.count());
    var path_it = unique_paths.keyIterator();
    while (path_it.next()) |key| {
        const wp = path_mod.WorkspacePath.parse(key.*) catch continue;
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();
        const hash_line = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"hash\":{d}}}\n", .{ key.*, snap.hash });
        defer allocator.free(hash_line);
        try hash_lines.appendSlice(allocator, hash_line);
    }

    try writeIndex(allocator, io, root, vector_dim, kept.items, hash_lines.items);

    const count: u32 = @intCast(kept.items.len);
    for (kept.items) |item| {
        freeChunk(allocator, item.chunk);
        allocator.free(item.vector);
    }
    kept.deinit(allocator);

    return .{ .chunk_count = count, .file_count = file_count };
}

const ExistingIndex = struct {
    items: []LoadedChunk,
};

fn loadExistingIndex(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, expected_dim: u32) !ExistingIndex {
    const manifest_bytes = try readRelative(allocator, io, root, manifest_file);
    defer allocator.free(manifest_bytes);
    const ManifestJson = struct { dim: u32 };
    var manifest_parsed = try std.json.parseFromSlice(ManifestJson, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest_parsed.deinit();
    if (manifest_parsed.value.dim != expected_dim) return IndexError.IndexMissing;

    const chunks_bytes = try readRelative(allocator, io, root, chunks_file);
    defer allocator.free(chunks_bytes);
    const vectors_bytes = try readRelative(allocator, io, root, vectors_file);
    defer allocator.free(vectors_bytes);

    var items: std.ArrayList(LoadedChunk) = .empty;
    errdefer {
        for (items.items) |item| {
            freeChunk(allocator, item.chunk);
            allocator.free(item.vector);
        }
        items.deinit(allocator);
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
        const vector = try allocator.alloc(f32, expected_dim);
        errdefer allocator.free(vector);
        try items.append(allocator, .{
            .chunk = .{
                .id = try allocator.dupe(u8, parsed.value.id),
                .path = try allocator.dupe(u8, parsed.value.path),
                .line_start = parsed.value.line_start,
                .line_end = parsed.value.line_end,
                .file_hash = parsed.value.file_hash,
                .text = try allocator.dupe(u8, parsed.value.text),
            },
            .vector = vector,
        });
    }

    const dim: usize = @intCast(expected_dim);
    const expected_bytes = items.items.len * dim * @sizeOf(f32);
    if (vectors_bytes.len < expected_bytes) return IndexError.IndexMissing;

    const vectors = try allocator.alloc(f32, items.items.len * dim);
    errdefer allocator.free(vectors);
    @memcpy(std.mem.sliceAsBytes(vectors), vectors_bytes[0..expected_bytes]);

    for (items.items, 0..) |*item, index| {
        @memcpy(item.vector, vectors[index * dim .. index * dim + dim]);
    }
    allocator.free(vectors);

    return .{
        .items = try items.toOwnedSlice(allocator),
    };
}

fn freeLoadedIndex(allocator: std.mem.Allocator, loaded: *ExistingIndex) void {
    for (loaded.items) |item| {
        freeChunk(allocator, item.chunk);
        allocator.free(item.vector);
    }
    allocator.free(loaded.items);
    loaded.* = undefined;
}

fn writeIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    vector_dim: u32,
    items: []const LoadedChunk,
    hash_lines: []const u8,
) !void {
    var chunks_buf: std.ArrayList(u8) = .empty;
    defer chunks_buf.deinit(allocator);
    var vectors_buf: std.ArrayList(u8) = .empty;
    defer vectors_buf.deinit(allocator);

    for (items) |item| {
        const line_prefix = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"path\":\"{s}\",\"line_start\":{d},\"line_end\":{d},\"file_hash\":{d},\"text\":", .{
            item.chunk.id, item.chunk.path, item.chunk.line_start, item.chunk.line_end, item.chunk.file_hash,
        });
        defer allocator.free(line_prefix);
        try chunks_buf.appendSlice(allocator, line_prefix);
        try appendJsonString(allocator, &chunks_buf, item.chunk.text);
        try chunks_buf.appendSlice(allocator, "}\n");
        const bytes = std.mem.sliceAsBytes(item.vector);
        try vectors_buf.appendSlice(allocator, bytes);
    }

    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(chunks_file), chunks_buf.items);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(vectors_file), vectors_buf.items);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(file_hashes_file), hash_lines);

    const built_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var manifest_buf: [256]u8 = undefined;
    const manifest_text = try std.fmt.bufPrint(&manifest_buf, "{{\"schema_version\":1,\"dim\":{d},\"chunk_count\":{d},\"built_ms\":{d}}}\n", .{
        vector_dim,
        items.len,
        built_ms,
    });
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(manifest_file), manifest_text);
}

fn readRelative(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, rel: []const u8) ![]u8 {
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

test "chunkContent splits long files" {
    const allocator = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var line: u32 = 0;
    while (line < 100) : (line += 1) {
        try content.appendSlice(allocator, "line content\n");
    }
    const chunks = try chunkContent(allocator, "sample.zig", edit.contentHash(content.items), content.items);
    defer freeChunks(allocator, chunks);
    try std.testing.expect(chunks.len >= 2);
}

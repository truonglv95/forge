const std = @import("std");
const workspace = @import("forge-workspace");

pub const Options = struct {
    max_terms: usize = 3,
    max_chunks: usize = 12,
    context_lines: u32 = 2,
};

const ScoredChunk = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
    score: u32,
    term: []const u8,
};

pub const CandidateChunk = struct {
    path: []const u8,
    line_start: u32,
    line_end: u32,
    score: u32,
    term: []const u8,
    preview: []const u8,
};

pub fn freeCandidates(allocator: std.mem.Allocator, chunks: []CandidateChunk) void {
    for (chunks) |chunk| {
        allocator.free(chunk.path);
        allocator.free(chunk.term);
        allocator.free(chunk.preview);
    }
    allocator.free(chunks);
}

/// Keyword grep candidates ranked by match score (caller owns returned slice).
pub fn collectFromIntent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    skip_paths: []const []const u8,
    options: Options,
) ![]CandidateChunk {
    var terms: std.ArrayList([]const u8) = .empty;
    defer {
        for (terms.items) |term| allocator.free(term);
        terms.deinit(allocator);
    }
    try extractTerms(allocator, intent, &terms, options.max_terms);
    if (terms.items.len == 0) return &.{};

    var chunks: std.ArrayList(ScoredChunk) = .empty;
    errdefer {
        for (chunks.items) |chunk| allocator.free(chunk.path);
        chunks.deinit(allocator);
    }

    for (terms.items) |term| {
        var result = workspace.search.searchContent(allocator, io, root, ".", term) catch continue;
        defer result.deinit();

        for (result.matches) |match| {
            if (shouldSkipPath(match.path, skip_paths)) continue;
            const score = scoreMatch(match.path, match.line_text, term);
            const line_start = if (match.line > options.context_lines) match.line - options.context_lines else 1;
            const line_end = match.line + options.context_lines;
            try chunks.append(allocator, .{
                .path = try allocator.dupe(u8, match.path),
                .line_start = line_start,
                .line_end = line_end,
                .score = score,
                .term = try allocator.dupe(u8, term),
            });
        }
    }

    if (chunks.items.len == 0) return &.{};

    std.sort.pdq(ScoredChunk, chunks.items, {}, struct {
        fn less(_: void, a: ScoredChunk, b: ScoredChunk) bool {
            if (a.score != b.score) return a.score > b.score;
            if (a.line_start != b.line_start) return a.line_start < b.line_start;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);

    var selected: std.ArrayList(CandidateChunk) = .empty;
    errdefer freeCandidates(allocator, selected.items);

    var used_keys = std.StringHashMap(void).init(allocator);
    defer {
        var iter = used_keys.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        used_keys.deinit();
    }

    for (chunks.items) |chunk| {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}-{d}", .{ chunk.path, chunk.line_start, chunk.line_end }) catch continue;
        if (used_keys.contains(key)) continue;
        const owned_key = try allocator.dupe(u8, key);
        used_keys.putNoClobber(owned_key, {}) catch |err| {
            allocator.free(owned_key);
            return err;
        };

        const snippet = try readLineWindow(allocator, io, root, chunk.path, chunk.line_start, chunk.line_end);
        errdefer allocator.free(snippet);
        if (snippet.len == 0) continue;

        try selected.append(allocator, .{
            .path = try allocator.dupe(u8, chunk.path),
            .line_start = chunk.line_start,
            .line_end = chunk.line_end,
            .score = chunk.score,
            .term = try allocator.dupe(u8, chunk.term),
            .preview = snippet,
        });
        if (selected.items.len >= options.max_chunks) break;
    }

    for (chunks.items) |chunk| {
        allocator.free(chunk.path);
        allocator.free(chunk.term);
    }
    chunks.deinit(allocator);

    return try selected.toOwnedSlice(allocator);
}

/// Builds a ranked snippet block from intent keyword search, or null if nothing relevant.
pub fn retrieveFromIntent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    skip_paths: []const []const u8,
    options: Options,
) !?[]const u8 {
    const candidates = try collectFromIntent(allocator, io, root, intent, skip_paths, options);
    defer freeCandidates(allocator, candidates);
    if (candidates.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Retrieved context (intent search)\n\n");

    for (candidates) |chunk| {
        const header = try std.fmt.allocPrint(allocator, "## {s}:{d}-{d} (score {d}, term: {s})\n```\n{s}\n```\n\n", .{
            chunk.path, chunk.line_start, chunk.line_end, chunk.score, chunk.term, chunk.preview,
        });
        defer allocator.free(header);
        try out.appendSlice(allocator, header);
    }

    if (out.items.len <= "# Retrieved context (intent search)\n\n".len) return null;
    return try out.toOwnedSlice(allocator);
}

/// Returns deduped intent terms for rerank path overlap (caller frees with `freeIntentTerms`).
pub fn intentTerms(allocator: std.mem.Allocator, intent: []const u8, max_terms: usize) ![]const []const u8 {
    var terms: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (terms.items) |term| allocator.free(term);
        terms.deinit(allocator);
    }
    try extractTerms(allocator, intent, &terms, max_terms);
    return try terms.toOwnedSlice(allocator);
}

pub fn freeIntentTerms(allocator: std.mem.Allocator, terms: []const []const u8) void {
    for (terms) |term| allocator.free(term);
    allocator.free(terms);
}

const stop_words = [_][]const u8{
    "the",    "a",    "an",     "is",       "are",   "was",    "were",      "be",     "been",   "being",
    "fix",    "add",  "update", "make",     "how",   "what",   "where",     "when",   "why",    "who",
    "for",    "to",   "in",     "on",       "at",    "of",     "and",       "or",     "not",    "this",
    "that",   "with", "from",   "me",       "my",    "i",      "please",    "can",    "could",  "would",
    "should", "do",   "does",   "did",      "it",    "its",    "we",        "you",    "your",   "them",
    "they",   "file", "code",   "function", "class", "method", "implement", "create", "change",
};

fn shouldSkipPath(path: []const u8, skip_paths: []const []const u8) bool {
    if (std.mem.startsWith(u8, path, ".forge/")) return true;
    if (std.mem.endsWith(u8, path, ".proposal.json")) return true;
    for (skip_paths) |skip| {
        if (std.mem.eql(u8, skip, path)) return true;
    }
    return false;
}

fn scoreMatch(path: []const u8, line_text: []const u8, term: []const u8) u32 {
    var score: u32 = 1;
    if (term.len >= 5) score += 2;
    if (term.len >= 8) score += 1;
    if (std.ascii.indexOfIgnoreCase(path, term) != null) score += 3;
    if (std.ascii.indexOfIgnoreCase(line_text, term) != null) score += 2;
    return score;
}

const TermCandidate = struct {
    term: []const u8,
    len: usize,
};

fn extractTerms(allocator: std.mem.Allocator, intent: []const u8, out: *std.ArrayList([]const u8), max_terms: usize) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var seen = std.StringHashMap(void).init(arena.allocator());

    var candidates: std.ArrayList(TermCandidate) = .empty;
    defer candidates.deinit(allocator);

    var start: usize = 0;
    while (start <= intent.len) {
        const end = blk: {
            var i = start;
            while (i < intent.len and !isTermBoundary(intent[i])) : (i += 1) {}
            break :blk i;
        };
        if (end > start) {
            const raw = intent[start..end];
            const lower = try allocator.dupe(u8, raw);
            for (lower) |*c| c.* = std.ascii.toLower(c.*);

            if (lower.len >= 3 and !isStopWord(lower) and !seen.contains(lower)) {
                try seen.put(lower, {});
                try candidates.append(allocator, .{ .term = lower, .len = lower.len });
            } else {
                allocator.free(lower);
            }
        }
        if (end >= intent.len) break;
        start = end + 1;
        while (start < intent.len and isTermBoundary(intent[start])) : (start += 1) {}
    }

    std.sort.pdq(TermCandidate, candidates.items, {}, struct {
        fn less(_: void, a: TermCandidate, b: TermCandidate) bool {
            return a.len > b.len;
        }
    }.less);

    const take = @min(max_terms, candidates.items.len);
    for (candidates.items[0..take]) |item| {
        try out.append(allocator, item.term);
    }

    for (candidates.items[take..]) |item| allocator.free(item.term);
}

fn isTermBoundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '.' or c == ',' or c == ';' or c == ':' or c == '?' or c == '!' or c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}' or c == '"' or c == '\'';
}

fn isStopWord(word: []const u8) bool {
    for (stop_words) |stop| {
        if (std.mem.eql(u8, word, stop)) return true;
    }
    return false;
}

fn readLineWindow(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    path: []const u8,
    line_start: u32,
    line_end: u32,
) ![]u8 {
    const wp = workspace.WorkspacePath.parse(path) catch return allocator.dupe(u8, "");
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return allocator.dupe(u8, "");
    defer snap.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_number: u32 = 1;
    var line_start_idx: usize = 0;
    for (snap.content, 0..) |byte, index| {
        if (byte == '\n') {
            if (line_number >= line_start and line_number <= line_end) {
                const line = try std.fmt.allocPrint(allocator, "{d:>4} | {s}\n", .{ line_number, snap.content[line_start_idx..index] });
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
            }
            line_start_idx = index + 1;
            line_number += 1;
            if (line_number > line_end) break;
        }
    }
    if (line_number <= line_end and line_start_idx <= snap.content.len) {
        const tail = snap.content[line_start_idx..];
        if (line_number >= line_start) {
            const line = try std.fmt.allocPrint(allocator, "{d:>4} | {s}\n", .{ line_number, tail });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "extractTerms skips stop words and prefers longer tokens" {
    const allocator = std.testing.allocator;
    var terms: std.ArrayList([]const u8) = .empty;
    defer {
        for (terms.items) |term| allocator.free(term);
        terms.deinit(allocator);
    }

    try extractTerms(allocator, "fix authentication middleware bug", &terms, 2);
    try std.testing.expect(terms.items.len >= 1);
    var found_auth = false;
    for (terms.items) |term| {
        if (std.mem.eql(u8, term, "authentication")) found_auth = true;
        try std.testing.expect(!std.mem.eql(u8, term, "fix"));
    }
    try std.testing.expect(found_auth);
}

test "retrieveFromIntent finds matching snippet" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("auth.zig"), "pub fn authenticate() void {}\n");

    const block = try retrieveFromIntent(allocator, io, root, "fix authenticate flow", &.{}, .{});
    defer if (block) |text| allocator.free(text);

    try std.testing.expect(block != null);
    try std.testing.expect(std.mem.indexOf(u8, block.?, "authenticate") != null);
}

test "collectFromIntent deduplicates many repeated windows without hash map crash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    for (0..256) |i| {
        const line = try std.fmt.allocPrint(allocator, "pub fn repeated_{d}() void {{ semantic semantic semantic }}\n", .{i});
        defer allocator.free(line);
        try content.appendSlice(allocator, line);
    }
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("many.zig"), content.items);

    const candidates = try collectFromIntent(allocator, io, root, "semantic repeated", &.{}, .{
        .max_terms = 2,
        .max_chunks = 24,
        .context_lines = 0,
    });
    defer freeCandidates(allocator, candidates);

    try std.testing.expect(candidates.len > 0);
    try std.testing.expect(candidates.len <= 24);

    for (candidates, 0..) |candidate, index| {
        for (candidates[0..index]) |previous| {
            try std.testing.expect(!std.mem.eql(u8, candidate.path, previous.path) or
                candidate.line_start != previous.line_start or
                candidate.line_end != previous.line_end);
        }
    }
}

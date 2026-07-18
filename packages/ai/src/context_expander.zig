const std = @import("std");
const workspace = @import("forge-workspace");
const context = @import("context.zig");
const context_retrieval = @import("context_retrieval.zig");
const import_graph = @import("import_graph.zig");

pub const Options = struct {
    max_paths: usize = 24,
    max_keyword_hits: usize = 8,
    max_import_neighbors: usize = 8,
    max_test_candidates: usize = 8,
};

const PathReason = struct {
    path: []const u8,
    reason: []const u8,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    paths: []PathReason,
    gaps: []const []const u8,
    confidence: u8,

    pub fn deinit(self: *Plan) void {
        for (self.paths) |item| {
            self.allocator.free(item.path);
            self.allocator.free(item.reason);
        }
        self.allocator.free(self.paths);
        for (self.gaps) |gap| self.allocator.free(gap);
        self.allocator.free(self.gaps);
        self.* = undefined;
    }
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    builder: *const context.ContextBuilder,
    intent: []const u8,
    seed_paths: []const []const u8,
    options: Options,
) !Plan {
    var paths: std.ArrayList(PathReason) = .empty;
    errdefer freePathReasons(allocator, paths.items);
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    for (seed_paths) |path| {
        try appendPath(allocator, &paths, &seen, path, "explicit scope or active file", options.max_paths);
    }

    try collectBuilderPaths(allocator, builder, &paths, &seen, options.max_paths);

    const loaded_snapshot_len = paths.items.len;
    if (intent.len > 0 and paths.items.len < options.max_paths) {
        const keyword_opt = context_retrieval.collectFromIntent(allocator, io, root, intent, &.{}, .{
            .max_chunks = options.max_keyword_hits,
            .context_lines = 2,
        }) catch null;
        if (keyword_opt) |keyword| {
            defer context_retrieval.freeCandidates(allocator, keyword);
            for (keyword) |hit| {
                var reason_buf: [160]u8 = undefined;
                const reason = std.fmt.bufPrint(&reason_buf, "keyword hit `{s}` score={d}", .{ hit.term, hit.score }) catch "keyword hit";
                try appendPath(allocator, &paths, &seen, hit.path, reason, options.max_paths);
            }
        }
    }

    if (paths.items.len < options.max_paths) {
        const seeds = try pathSliceFromReasons(allocator, paths.items, @max(loaded_snapshot_len, seed_paths.len));
        defer freeStringSlice(allocator, seeds);
        const neighbors = import_graph.collectNeighborPaths(allocator, io, root, seeds, &.{}, .{
            .max_files = options.max_import_neighbors,
            .preview_bytes = 0,
        }) catch &[_][]const u8{};
        defer if (neighbors.len > 0) import_graph.freePaths(allocator, neighbors);
        for (neighbors) |path| {
            try appendPath(allocator, &paths, &seen, path, "import/dependency neighbor", options.max_paths);
        }
    }

    if (paths.items.len < options.max_paths) {
        const test_basis = try pathSliceFromReasons(allocator, paths.items, paths.items.len);
        defer freeStringSlice(allocator, test_basis);
        try collectLikelyTests(allocator, io, root, test_basis, &paths, &seen, options);
    }

    var gaps: std.ArrayList([]const u8) = .empty;
    errdefer freeStringSlice(allocator, gaps.items);
    const has_seed = seed_paths.len > 0;
    const has_retrieval = hasBlock(builder, .fused) or hasBlock(builder, .semantic) or hasBlock(builder, .retrieval);
    const has_tests = hasReason(paths.items, "test");
    const has_imports = hasReason(paths.items, "import");

    if (!has_seed) try gaps.append(allocator, try allocator.dupe(u8, "No explicit @file/active file; start with find_files/search before editing."));
    if (!has_retrieval) try gaps.append(allocator, try allocator.dupe(u8, "No retrieval block included; use search or codebase_search to ground the task."));
    if (!has_imports) try gaps.append(allocator, try allocator.dupe(u8, "No dependency neighbors found; inspect imports/callers before cross-file changes."));
    if (!has_tests) try gaps.append(allocator, try allocator.dupe(u8, "No likely tests found; use find_files for test/spec files before validation-sensitive edits."));

    var confidence: u8 = 20;
    if (has_seed) confidence += 20;
    if (has_retrieval) confidence += 25;
    if (has_imports) confidence += 15;
    if (has_tests) confidence += 10;
    if (paths.items.len >= 6) confidence += 10;
    confidence = @min(confidence, 95);

    return .{
        .allocator = allocator,
        .paths = try paths.toOwnedSlice(allocator),
        .gaps = try gaps.toOwnedSlice(allocator),
        .confidence = confidence,
    };
}

pub fn formatPlan(allocator: std.mem.Allocator, plan: Plan) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendPrint(allocator, &out, "# Context expansion plan\n\nConfidence: {d}/100\n\n", .{plan.confidence});
    try out.appendSlice(allocator, "## Priority paths\n");
    if (plan.paths.len == 0) {
        try out.appendSlice(allocator, "- (none yet)\n");
    } else {
        for (plan.paths) |item| {
            try appendPrint(allocator, &out, "- `{s}` — {s}\n", .{ item.path, item.reason });
        }
    }

    try out.appendSlice(allocator, "\n## Gaps and next tools\n");
    if (plan.gaps.len == 0) {
        try out.appendSlice(allocator, "- Context looks sufficiently grounded for the next action.\n");
    } else {
        for (plan.gaps) |gap| {
            try appendPrint(allocator, &out, "- {s}\n", .{gap});
        }
    }
    try out.appendSlice(allocator, "\n## Agent contract\n");
    try out.appendSlice(allocator, "- Before editing a file, call read_file for that exact path in this session.\n");
    try out.appendSlice(allocator, "- Before cross-file refactors, inspect references/import neighbors and likely tests.\n");
    try out.appendSlice(allocator, "- After validation failure, add failing output, git diff, and affected files to context before repair.\n");
    return out.toOwnedSlice(allocator);
}

fn collectBuilderPaths(
    allocator: std.mem.Allocator,
    builder: *const context.ContextBuilder,
    paths: *std.ArrayList(PathReason),
    seen: *std.StringHashMap(void),
    max_paths: usize,
) !void {
    for (builder.blocks.items) |block| {
        const reason = switch (block.block_type) {
            .file => "loaded file",
            .recent => "recent workspace file",
            .git_diff => "changed in working tree",
            .fused => "fused retrieval block",
            .semantic => "semantic retrieval block",
            .retrieval => "keyword retrieval block",
            else => continue,
        };
        if (pathFromName(block.name)) |path| {
            try appendPath(allocator, paths, seen, path, reason, max_paths);
        }
    }
    for (builder.manifest_extras.items) |extra| {
        const reason = switch (extra.kind) {
            .fused => "fused retrieval hit",
            .semantic => "semantic retrieval hit",
            .imports => "import/dependency neighbor",
            .diagnostic => "diagnostic source",
            .lsp => "LSP hint",
            else => continue,
        };
        if (pathFromName(extra.name)) |path| {
            try appendPath(allocator, paths, seen, path, reason, max_paths);
        }
    }
}

fn collectLikelyTests(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    basis: []const []const u8,
    paths: *std.ArrayList(PathReason),
    seen: *std.StringHashMap(void),
    options: Options,
) !void {
    if (basis.len == 0) return;
    var tree = workspace.tree.scan(allocator, io, root, ".") catch return;
    defer tree.deinit();

    var added: usize = 0;
    for (basis) |path| {
        const stem = fileStem(path);
        if (stem.len < 3) continue;
        for (tree.entries) |entry| {
            if (entry.kind != .file) continue;
            if (!looksLikeTestPath(entry.path)) continue;
            if (std.ascii.indexOfIgnoreCase(entry.path, stem) == null) continue;
            try appendPath(allocator, paths, seen, entry.path, "likely test/spec for related source", options.max_paths);
            added += 1;
            if (added >= options.max_test_candidates or paths.items.len >= options.max_paths) return;
        }
    }
}

fn appendPath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList(PathReason),
    seen: *std.StringHashMap(void),
    raw_path: []const u8,
    reason: []const u8,
    max_paths: usize,
) !void {
    if (paths.items.len >= max_paths) return;
    const path = std.mem.trim(u8, raw_path, " \t\r\n`");
    if (path.len == 0 or shouldIgnorePath(path)) return;
    const owned_key = try allocator.dupe(u8, path);
    const gop = try seen.getOrPut(owned_key);
    if (gop.found_existing) {
        allocator.free(owned_key);
        return;
    }
    try paths.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .reason = try allocator.dupe(u8, reason),
    });
}

fn pathFromName(name: []const u8) ?[]const u8 {
    var end = name.len;
    if (std.mem.indexOfScalar(u8, name, ':')) |idx| end = idx;
    const path = std.mem.trim(u8, name[0..end], " \t\r\n`");
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, '/') == null and std.mem.indexOfScalar(u8, path, '.') == null) return null;
    return path;
}

fn pathSliceFromReasons(allocator: std.mem.Allocator, paths: []const PathReason, limit: usize) ![]const []const u8 {
    const take = @min(paths.len, limit);
    var out = try allocator.alloc([]const u8, take);
    errdefer allocator.free(out);
    for (paths[0..take], 0..) |item, i| out[i] = try allocator.dupe(u8, item.path);
    return out;
}

fn freePathReasons(allocator: std.mem.Allocator, paths: []PathReason) void {
    for (paths) |item| {
        allocator.free(item.path);
        allocator.free(item.reason);
    }
}

fn freeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn hasBlock(builder: *const context.ContextBuilder, kind: context.BlockType) bool {
    for (builder.blocks.items) |block| {
        if (block.block_type == kind) return true;
    }
    return false;
}

fn hasReason(paths: []const PathReason, needle: []const u8) bool {
    for (paths) |item| {
        if (std.ascii.indexOfIgnoreCase(item.reason, needle) != null) return true;
    }
    return false;
}

fn shouldIgnorePath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, ".git/")) return true;
    if (std.mem.startsWith(u8, path, ".zig-cache/")) return true;
    if (std.mem.startsWith(u8, path, "zig-out/")) return true;
    if (std.mem.startsWith(u8, path, "node_modules/")) return true;
    if (std.mem.startsWith(u8, path, "vendor/")) return true;
    return false;
}

fn looksLikeTestPath(path: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(path, "test") != null or
        std.ascii.indexOfIgnoreCase(path, "spec") != null or
        std.mem.startsWith(u8, path, "fixtures/");
}

fn fileStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

fn appendPrint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

test "context expander finds keyword hits and likely tests" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "tests");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/auth.zig"), "pub fn authenticateUser() void {}\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("tests/auth_test.zig"), "test \"auth\" {}\n");

    var builder = context.ContextBuilder.init(allocator, 64 * 1024);
    defer builder.deinit();
    try builder.addBlock(.intent, "intent", "fix authenticate user");

    var plan = try buildPlan(allocator, io, root, &builder, "fix authenticate user", &.{"src/auth.zig"}, .{});
    defer plan.deinit();
    const text = try formatPlan(allocator, plan);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "src/auth.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tests/auth_test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Before editing a file") != null);
}

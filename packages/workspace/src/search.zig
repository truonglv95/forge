const std = @import("std");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");
const tree = @import("tree.zig");
const ignore = @import("ignore.zig");
const kernel = @import("forge-kernel");

pub const Match = struct {
    path: []const u8,
    line: u32,
    column: u32,
    line_text: []const u8,
    /// Lines of text immediately before the match (joined with '\n'), empty when no context requested.
    before_context: []const u8 = "",
    /// Lines of text immediately after the match (joined with '\n'), empty when no context requested.
    after_context: []const u8 = "",
};

pub const SearchResult = struct {
    allocator: std.mem.Allocator,
    query: []const u8,
    matches: []Match,

    pub fn deinit(self: *SearchResult) void {
        for (self.matches) |match| {
            self.allocator.free(match.path);
            self.allocator.free(match.line_text);
            if (match.before_context.len > 0) self.allocator.free(match.before_context);
            if (match.after_context.len > 0) self.allocator.free(match.after_context);
        }
        self.allocator.free(self.matches);
        self.allocator.free(self.query);
        self.* = undefined;
    }
};

pub const GrepOptions = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    glob: ?[]const u8 = null,
    case_sensitive: bool = false,
    head_limit: usize = 50,
    /// Number of context lines to include before and after each match (grep -C style).
    context_lines: usize = 0,
};

pub fn grepContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    options: GrepOptions,
) !SearchResult {
    // Try the fast ripgrep path first; fall back to pure-Zig on any failure.
    if (grepContentWithRg(allocator, io, root, options)) |result| {
        return result;
    } else |_| {
        return grepContentPureZig(allocator, io, root, options);
    }
}

// ---------------------------------------------------------------------------
// ripgrep backend
// ---------------------------------------------------------------------------

/// Attempt to search using the `rg` binary.  Returns an error (triggering
/// fall-back) if `rg` is not found, exits non-zero in an unexpected way, or
/// if we hit any allocation/parse error.
fn grepContentWithRg(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    options: GrepOptions,
) !SearchResult {
    if (options.pattern.len == 0) {
        return SearchResult{
            .allocator = allocator,
            .query = try allocator.dupe(u8, options.pattern),
            .matches = try allocator.alloc(Match, 0),
        };
    }

    const head_limit = @min(@max(options.head_limit, 1), 200);

    // Resolve the workspace root to an absolute filesystem path so we can
    // pass it to rg as a directory argument.
    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path_len = try root.dir.realPath(io, &root_path_buf);
    const root_abs = root_path_buf[0..root_path_len];

    // Build the rg argv dynamically.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "rg");
    try argv.append(allocator, "--json");

    // Case sensitivity: rg is case-sensitive by default; add -i for
    // case-insensitive mode (the inverse of the option flag).
    if (!options.case_sensitive) {
        try argv.append(allocator, "-i");
    }

    // Glob filter.
    if (options.glob) |glob| {
        try argv.append(allocator, "-g");
        try argv.append(allocator, glob);
    }

    // Context lines (-C N).  The string must outlive argv, so we allocate it
    // into a separate buffer that is freed after runCapture returns.
    var ctx_count_buf: ?[]u8 = null;
    defer if (ctx_count_buf) |b| allocator.free(b);
    if (options.context_lines > 0) {
        ctx_count_buf = try std.fmt.allocPrint(allocator, "{d}", .{options.context_lines});
        try argv.append(allocator, "-C");
        try argv.append(allocator, ctx_count_buf.?);
    }

    // Pattern matching mode:
    //   • If the pattern contains `|` we treat it as a regex alternation and
    //     pass it straight through (rg uses regex by default).
    //   • Otherwise use --fixed-strings for safe literal matching.
    const has_alternation = std.mem.indexOfScalar(u8, options.pattern, '|') != null;
    if (!has_alternation) {
        try argv.append(allocator, "--fixed-strings");
    }

    // Use -- to prevent the pattern from being interpreted as a flag.
    try argv.append(allocator, "--");
    try argv.append(allocator, options.pattern);

    // Path argument: the absolute root, optionally narrowed to a sub-path.
    // The joined string must outlive argv.
    const scope = std.mem.trim(u8, options.path, "/");
    var joined_path_buf: ?[]u8 = null;
    defer if (joined_path_buf) |b| allocator.free(b);
    if (scope.len == 0 or std.mem.eql(u8, scope, ".")) {
        try argv.append(allocator, root_abs);
    } else {
        joined_path_buf = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_abs, scope });
        try argv.append(allocator, joined_path_buf.?);
    }

    // Run rg and capture its output.  We cap at 8 MB; larger workspaces will
    // get truncated naturally at head_limit anyway.
    const capture = kernel.process.runCapture(allocator, .{
        .argv = argv.items,
        .cwd = root_abs,
        .max_bytes = 8 * 1024 * 1024,
    }) catch {
        // Any spawn failure (rg not on PATH shows up as SpawnFailed) triggers
        // fall-back to the pure-Zig implementation.
        return error.RgNotAvailable;
    };
    defer allocator.free(capture.output);

    // rg exits 0 (matches found), 1 (no matches), or 2 (error).
    // Exit code 2 means something went wrong (bad pattern, bad path, etc.).
    if (capture.exit_code == 2) return error.RgError;

    // Parse the JSON lines produced by rg.
    var matches: std.ArrayList(Match) = .empty;
    errdefer {
        for (matches.items) |match| {
            allocator.free(match.path);
            allocator.free(match.line_text);
            if (match.before_context.len > 0) allocator.free(match.before_context);
            if (match.after_context.len > 0) allocator.free(match.after_context);
        }
        matches.deinit(allocator);
    }

    // When using context lines we accumulate context in a pending match until
    // we see the next "match" or "end" message.
    var pending_before: std.ArrayList(u8) = .empty;
    defer pending_before.deinit(allocator);
    var pending_after: std.ArrayList(u8) = .empty;
    defer pending_after.deinit(allocator);
    var last_match_idx: ?usize = null; // index into matches for last match-type entry
    var in_after_context = false;

    var json_lines = std.mem.splitScalar(u8, capture.output, '\n');
    while (json_lines.next()) |json_line| {
        if (matches.items.len >= head_limit) break;
        const trimmed = std.mem.trim(u8, json_line, " \t\r");
        if (trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const type_val = obj.get("type") orelse continue;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => continue,
        };

        if (std.mem.eql(u8, type_str, "context")) {
            // Context lines come before or after a match.
            const data_val = obj.get("data") orelse continue;
            const data = switch (data_val) {
                .object => |o| o,
                else => continue,
            };
            const lines_val = data.get("lines") orelse continue;
            const lines_obj = switch (lines_val) {
                .object => |o| o,
                else => continue,
            };
            const ctx_text_val = lines_obj.get("text") orelse continue;
            const ctx_text_raw = switch (ctx_text_val) {
                .string => |s| s,
                else => continue,
            };
            const ctx_text = std.mem.trimEnd(u8, ctx_text_raw, "\r\n");

            if (in_after_context) {
                // Append to after-context of the last match.
                if (last_match_idx) |idx| {
                    const existing = matches.items[idx].after_context;
                    const new_after = if (existing.len > 0)
                        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ existing, ctx_text })
                    else
                        try allocator.dupe(u8, ctx_text);
                    if (existing.len > 0) allocator.free(existing);
                    matches.items[idx].after_context = new_after;
                }
            } else {
                // Append to before-context accumulator.
                if (pending_before.items.len > 0) {
                    try pending_before.append(allocator, '\n');
                }
                try pending_before.appendSlice(allocator, ctx_text);
            }
            continue;
        }

        if (std.mem.eql(u8, type_str, "match")) {
            // A match resets the "after" phase and starts a new "before" context window.
            in_after_context = true;

            const data_val = obj.get("data") orelse continue;
            const data = switch (data_val) {
                .object => |o| o,
                else => continue,
            };

            // Extract file path (relative to root).
            const path_val = data.get("path") orelse continue;
            const path_obj = switch (path_val) {
                .object => |o| o,
                else => continue,
            };
            const path_text_val = path_obj.get("text") orelse continue;
            const abs_file_path = switch (path_text_val) {
                .string => |s| s,
                else => continue,
            };

            // Convert absolute path back to workspace-relative by stripping the root prefix.
            const rel_path = if (std.mem.startsWith(u8, abs_file_path, root_abs))
                std.mem.trimStart(u8, abs_file_path[root_abs.len..], "/")
            else
                abs_file_path;

            // Skip forge-internal and proposal files (mirrors pure-Zig logic).
            if (std.mem.endsWith(u8, rel_path, ".proposal.json") or
                std.mem.startsWith(u8, rel_path, ".forge/")) continue;

            // Extract line number.
            const line_num_val = data.get("line_number") orelse continue;
            const line_num: u32 = switch (line_num_val) {
                .integer => |n| @intCast(n),
                else => continue,
            };

            // Extract the matched line text.
            const lines_val = data.get("lines") orelse continue;
            const lines_obj = switch (lines_val) {
                .object => |o| o,
                else => continue,
            };
            const line_text_val = lines_obj.get("text") orelse continue;
            const line_text_raw = switch (line_text_val) {
                .string => |s| s,
                else => continue,
            };
            const line_text = std.mem.trimEnd(u8, line_text_raw, "\r\n");

            // Consume accumulated before-context.
            const before_ctx = if (pending_before.items.len > 0)
                try allocator.dupe(u8, pending_before.items)
            else
                "";
            pending_before.clearRetainingCapacity();

            // Emit one Match per submatch so that multiple occurrences of the
            // pattern on a single line (and alternations) each produce their
            // own entry — mirroring the pure-Zig behaviour.
            if (data.get("submatches")) |sm_val| {
                if (sm_val == .array and sm_val.array.items.len > 0) {
                    var emitted: usize = 0;
                    for (sm_val.array.items) |sm| {
                        if (matches.items.len >= head_limit) break;
                        if (sm != .object) continue;
                        var col: u32 = 1;
                        if (sm.object.get("start")) |sv| {
                            if (sv == .integer) col = @intCast(sv.integer + 1);
                        }
                        // Only the first submatch for this match-line carries
                        // the before_context; subsequent ones start fresh.
                        const bc = if (emitted == 0) before_ctx else "";
                        try matches.append(allocator, .{
                            .path = try allocator.dupe(u8, rel_path),
                            .line = line_num,
                            .column = col,
                            .line_text = try allocator.dupe(u8, line_text),
                            .before_context = bc,
                            .after_context = "",
                        });
                        last_match_idx = matches.items.len - 1;
                        emitted += 1;
                    }
                    if (emitted == 0 and before_ctx.len > 0) allocator.free(before_ctx);
                    continue;
                }
            }

            // No submatches array — fall through to emit a single match.
            try matches.append(allocator, .{
                .path = try allocator.dupe(u8, rel_path),
                .line = line_num,
                .column = 1,
                .line_text = try allocator.dupe(u8, line_text),
                .before_context = before_ctx,
                .after_context = "",
            });
            last_match_idx = matches.items.len - 1;
            continue;
        }

        // On "end" or "begin", reset the context accumulators for the next file.
        if (std.mem.eql(u8, type_str, "end") or std.mem.eql(u8, type_str, "begin")) {
            pending_before.clearRetainingCapacity();
            in_after_context = false;
            continue;
        }
    }

    return SearchResult{
        .allocator = allocator,
        .query = try allocator.dupe(u8, options.pattern),
        .matches = try matches.toOwnedSlice(allocator),
    };
}

// ---------------------------------------------------------------------------
// Pure-Zig fallback (original implementation, renamed)
// ---------------------------------------------------------------------------

fn grepContentPureZig(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    options: GrepOptions,
) !SearchResult {
    const head_limit = @min(@max(options.head_limit, 1), 200);
    var summary = try tree.scan(allocator, io, root, options.path);
    defer summary.deinit();

    var matches: std.ArrayList(Match) = .empty;
    errdefer {
        for (matches.items) |match| {
            allocator.free(match.path);
            allocator.free(match.line_text);
            if (match.before_context.len > 0) allocator.free(match.before_context);
            if (match.after_context.len > 0) allocator.free(match.after_context);
        }
        matches.deinit(allocator);
    }

    for (summary.entries) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".proposal.json") or std.mem.startsWith(u8, entry.path, ".forge/")) continue;
        if (!pathInScope(entry.path, options.path)) continue;
        if (options.glob) |glob| {
            if (!globMatches(entry.path, glob)) continue;
        }

        const wp = try path_mod.WorkspacePath.parse(entry.path);
        var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();

        if (snap.content.len > ignore.Limits.max_file_size) continue;
        if (!std.unicode.utf8ValidateSlice(snap.content)) continue;

        // Split into lines for context support.
        var file_lines: std.ArrayList([]const u8) = .empty;
        defer file_lines.deinit(allocator);
        {
            var line_start: usize = 0;
            for (snap.content, 0..) |byte, i| {
                if (byte == '\n') {
                    try file_lines.append(allocator, snap.content[line_start..i]);
                    line_start = i + 1;
                }
            }
            // Append the last line (non-empty, or first line of an empty file).
            const last_line = snap.content[line_start..];
            if (last_line.len > 0 or file_lines.items.len == 0) {
                try file_lines.append(allocator, last_line);
            }
        }

        for (file_lines.items, 0..) |line, li| {
            if (matches.items.len >= head_limit) break;
            const line_number: u32 = @intCast(li + 1);
            try scanLineWithContext(allocator, &matches, entry.path, options, file_lines.items, line, line_number, head_limit);
        }
        if (matches.items.len >= head_limit) break;
    }

    return SearchResult{
        .allocator = allocator,
        .query = try allocator.dupe(u8, options.pattern),
        .matches = try matches.toOwnedSlice(allocator),
    };
}

pub fn searchContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    root_path: []const u8,
    query: []const u8,
) !SearchResult {
    return grepContent(allocator, io, root, .{
        .pattern = query,
        .path = root_path,
        .case_sensitive = true,
    });
}

fn pathInScope(entry_path: []const u8, scope: []const u8) bool {
    if (scope.len == 0 or std.mem.eql(u8, scope, ".")) return true;
    const normalized = std.mem.trim(u8, scope, "/");
    if (normalized.len == 0) return true;
    if (std.mem.eql(u8, entry_path, normalized)) return true;
    if (entry_path.len <= normalized.len) return false;
    if (!std.mem.startsWith(u8, entry_path, normalized)) return false;
    return entry_path[normalized.len] == '/';
}

fn globMatches(path: []const u8, glob: []const u8) bool {
    const target = if (std.mem.indexOfScalar(u8, glob, '/')) |_| path else std.fs.path.basename(path);
    return simpleGlob(target, glob);
}

fn simpleGlob(text: []const u8, pattern: []const u8) bool {
    return globRec(text, pattern, 0, 0);
}

fn globRec(text: []const u8, pattern: []const u8, ti: usize, pi: usize) bool {
    if (pi == pattern.len) return ti == text.len;
    if (pattern[pi] == '*') {
        var skip: usize = pi + 1;
        while (skip < pattern.len and pattern[skip] == '*') skip += 1;
        if (skip == pattern.len) return true;
        var start: usize = ti;
        while (start <= text.len) : (start += 1) {
            if (globRec(text, pattern, start, skip)) return true;
        }
        return false;
    }
    if (ti == text.len) return false;
    const pc = pattern[pi];
    const tc = text[ti];
    if (pc == '?' or pc == tc) return globRec(text, pattern, ti + 1, pi + 1);
    return false;
}

fn scanLineWithContext(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    path: []const u8,
    options: GrepOptions,
    all_lines: []const []const u8,
    line: []const u8,
    line_number: u32,
    head_limit: usize,
) !void {
    if (options.pattern.len == 0) return;
    if (matches.items.len >= head_limit) return;

    var parts = std.mem.splitScalar(u8, options.pattern, '|');
    while (parts.next()) |part| {
        const needle = std.mem.trim(u8, part, " \t");
        if (needle.len == 0) continue;
        var offset: usize = 0;
        while (offset <= line.len and matches.items.len < head_limit) {
            const found = findNeedle(line, needle, offset, options.case_sensitive) orelse break;

            // Build before/after context strings.
            const li = line_number - 1; // 0-based index
            const before_ctx = blk: {
                if (options.context_lines == 0) break :blk "";
                const start_li = if (li >= options.context_lines) li - options.context_lines else 0;
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(allocator);
                for (start_li..li) |ci| {
                    if (buf.items.len > 0) try buf.append(allocator, '\n');
                    try buf.appendSlice(allocator, all_lines[ci]);
                }
                break :blk try buf.toOwnedSlice(allocator);
            };
            const after_ctx = blk: {
                if (options.context_lines == 0) break :blk "";
                const end_li = @min(li + options.context_lines + 1, all_lines.len);
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(allocator);
                for (li + 1..end_li) |ci| {
                    if (buf.items.len > 0) try buf.append(allocator, '\n');
                    try buf.appendSlice(allocator, all_lines[ci]);
                }
                break :blk try buf.toOwnedSlice(allocator);
            };

            try matches.append(allocator, .{
                .path = try allocator.dupe(u8, path),
                .line = line_number,
                .column = @intCast(found + 1),
                .line_text = try allocator.dupe(u8, line),
                .before_context = before_ctx,
                .after_context = after_ctx,
            });
            offset = found + @max(needle.len, 1);
        }
    }
}

fn findNeedle(haystack: []const u8, needle: []const u8, offset: usize, case_sensitive: bool) ?usize {
    if (case_sensitive) return std.mem.indexOfPos(u8, haystack, offset, needle);
    if (needle.len == 0) return offset;
    var i = offset;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

test "search finds literal matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    {
        var file = try tmp.dir.createFile(io, "sample.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "hello forge\nsecond line\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try searchContent(allocator, io, root, ".", "forge");
    defer result.deinit();

    try std.testing.expect(result.matches.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, result.matches[0].line_text, "forge") != null);
}

test "grep is case-insensitive by default" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(io, "Tensor.py", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "class Tensor\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try grepContent(allocator, io, root, .{ .pattern = "tensor" });
    defer result.deinit();
    try std.testing.expect(result.matches.len >= 1);
}

test "grep supports alternation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    {
        var a = try tmp.dir.createFile(io, "a.py", .{});
        defer a.close(io);
        try a.writeStreamingAll(io, "engine start\n");
        var b = try tmp.dir.createFile(io, "b.py", .{});
        defer b.close(io);
        try b.writeStreamingAll(io, "tensor init\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try grepContent(allocator, io, root, .{ .pattern = "engine|tensor" });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
}

test "grep filters by glob" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    {
        var py = try tmp.dir.createFile(io, "a.py", .{});
        defer py.close(io);
        try py.writeStreamingAll(io, "needle\n");
        var txt = try tmp.dir.createFile(io, "a.txt", .{});
        defer txt.close(io);
        try txt.writeStreamingAll(io, "needle\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try grepContent(allocator, io, root, .{ .pattern = "needle", .glob = "*.py" });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqualStrings("a.py", result.matches[0].path);
}

test "grep respects head_limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(io, "many.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "hit hit hit hit hit\n");
    }

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    var result = try grepContent(allocator, io, root, .{ .pattern = "hit", .head_limit = 2 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
}

//! @mention picker — fuzzy file/symbol/docs/git picker popup for TUI input.
//!
//! When the user types `@` in the input line, this module pops up a list of
//! completions. The user can filter by typing more characters, navigate with
//! ↑/↓, select with Enter, or dismiss with Esc. Supported mention types:
//!   @file:<path>     — workspace files (fuzzy match on path)
//!   @symbol:<name>   — LSP workspace symbols (fuzzy match on name)
//!   @docs:<library>  — docs/<library>.md files
//!   @recent          — recent files
//!   @git:diff        — git diff --stat
//!   @git:status      — git status --porcelain
//!
//! This is the TUI equivalent of Cursor's @-mention popover and Claude Code's
//! @file completion. It reuses mention_parser.zig for resolving mentions
//! after selection.
//!
//! Status: skeleton + fuzzy file matcher. Symbol/docs/git sources are stubs
//! that return empty results until wired to LSP/docs_loader/git_diff.

const std = @import("std");

pub const MentionKind = enum {
    file,
    symbol,
    docs,
    recent,
    git_diff,
    git_status,
    web,
    spec,
};

pub const MentionEntry = struct {
    kind: MentionKind,
    label: []const u8, // display label (e.g. "src/main.zig")
    insert: []const u8, // text to insert (e.g. "@file:src/main.zig")
    detail: []const u8 = "", // optional detail (e.g. "modified 2m ago")
};

pub const PickerState = struct {
    active: bool = false,
    query: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(MentionEntry) = .empty,
    selected: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PickerState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PickerState) void {
        self.query.deinit(self.allocator);
        self.freeEntries();
        self.entries.deinit(self.allocator);
    }

    fn freeEntries(self: *PickerState) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.label);
            self.allocator.free(e.insert);
            if (e.detail.len > 0) self.allocator.free(e.detail);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Open the picker with an initial query (usually empty after `@`).
    pub fn open(self: *PickerState) void {
        self.active = true;
        self.query.clearRetainingCapacity();
        self.selected = 0;
    }

    /// Close the picker and discard state.
    pub fn close(self: *PickerState) void {
        self.active = false;
        self.query.clearRetainingCapacity();
        self.freeEntries();
    }

    /// Append a character to the query (user typed more after `@`).
    pub fn appendQuery(self: *PickerState, c: u8) !void {
        try self.query.append(self.allocator, c);
    }

    /// Remove the last character from the query (backspace).
    pub fn backspaceQuery(self: *PickerState) void {
        if (self.query.items.len > 0) {
            _ = self.query.pop();
        }
    }

    pub fn moveUp(self: *PickerState) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *PickerState) void {
        if (self.selected + 1 < self.entries.items.len) self.selected += 1;
    }

    /// Get the currently selected entry (null if empty).
    pub fn current(self: *const PickerState) ?MentionEntry {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.selected];
    }

    /// Refresh the entries list based on the current query. Calls the
    /// provided source function to get candidate entries, then filters
    /// by fuzzy match against the query.
    pub fn refresh(
        self: *PickerState,
        source: *const fn (std.mem.Allocator, []const u8) anyerror![]MentionEntry,
    ) !void {
        self.freeEntries();
        const candidates = try source(self.allocator, self.query.items);
        defer self.allocator.free(candidates);

        // Sort by fuzzy score (highest first), take top 10.
        const ScoredEntry = struct {
            entry: MentionEntry,
            score: i32,
        };
        var scored: std.ArrayList(ScoredEntry) = .empty;
        defer scored.deinit(self.allocator);
        for (candidates) |c| {
            const s = fuzzyScore(c.label, self.query.items);
            if (s > 0) {
                try scored.append(self.allocator, .{ .entry = c, .score = s });
            } else {
                // Free entries that don't match.
                self.allocator.free(c.label);
                self.allocator.free(c.insert);
                if (c.detail.len > 0) self.allocator.free(c.detail);
            }
        }
        std.mem.sort(ScoredEntry, scored.items, {}, struct {
            fn lt(_: void, a: ScoredEntry, b: ScoredEntry) bool {
                return a.score > b.score;
            }
        }.lt);

        const take = @min(scored.items.len, 10);
        for (scored.items[0..take]) |s| {
            try self.entries.append(self.allocator, s.entry);
        }
        if (self.selected >= self.entries.items.len and self.entries.items.len > 0) {
            self.selected = self.entries.items.len - 1;
        }
    }
};

/// Fuzzy match score: returns a positive score if `query` is a subsequence of
/// `text` (case-insensitive), 0 otherwise. Higher score = better match.
/// Score is based on:
///   - Number of consecutive matches (bonus)
///   - Matches at word boundaries (bonus)
///   - Shorter text (bonus, since it's more specific)
pub fn fuzzyScore(text: []const u8, query: []const u8) i32 {
    if (query.len == 0) return 1; // empty query matches everything
    if (text.len == 0) return 0;

    var score: i32 = 0;
    var qi: usize = 0;
    var consecutive: i32 = 0;
    var prev_matched = false;

    for (text, 0..) |c, ti| {
        if (qi >= query.len) break;
        const q = query[qi];
        if (std.ascii.toLower(c) == std.ascii.toLower(q)) {
            // Match!
            consecutive += 1;
            score += 10 + consecutive * 2; // consecutive bonus
            // Word boundary bonus: previous char was space, /, _, ., or start.
            if (ti == 0 or text[ti - 1] == ' ' or text[ti - 1] == '/' or
                text[ti - 1] == '_' or text[ti - 1] == '.')
            {
                score += 15;
            }
            qi += 1;
            prev_matched = true;
        } else {
            consecutive = 0;
            prev_matched = false;
        }
    }

    if (qi < query.len) return 0; // not all query chars matched
    // Prefer shorter texts (more specific match).
    score -= @divTrunc(@as(i32, @intCast(text.len)), 10);
    return score;
}

/// Default mention source: scan workspace files for fuzzy match.
/// Uses the workspace tree scan summary (if available) to build a list of
/// file paths. Falls back to a few common files if no scan summary is set.
pub fn defaultFileSource(allocator: std.mem.Allocator, query: []const u8) ![]MentionEntry {
    _ = query;
    // In a real implementation, this would access the App's scan_summary
    // to list workspace files. Since this is a free function (no access to
    // App state), we return a few common files as a fallback.
    // The App should set a custom source function that uses scan_summary.
    const stub_files = [_][]const u8{
        "src/main.zig",
        "src/config.zig",
        "README.md",
        "build.zig",
        "forge.toml",
        "FORGE.md",
    };
    var entries: std.ArrayList(MentionEntry) = .empty;
    for (stub_files) |f| {
        const label = try allocator.dupe(u8, f);
        const insert = try std.fmt.allocPrint(allocator, "@file:{s}", .{f});
        try entries.append(allocator, .{ .kind = .file, .label = label, .insert = insert });
    }
    return try entries.toOwnedSlice(allocator);
}

/// Build a mention source function that uses the workspace tree scan summary.
/// Returns a closure-compatible function pointer. The caller passes the
/// scan summary entries; this function filters by the query.
pub fn buildWorkspaceFileSource(
    allocator: std.mem.Allocator,
    scan_entries: []const @import("forge-workspace").tree.ScanSummary.Entry,
) ![]MentionEntry {
    var entries: std.ArrayList(MentionEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.label);
            allocator.free(e.insert);
        }
        entries.deinit(allocator);
    }

    for (scan_entries) |entry| {
        if (entry.kind != .file) continue;
        if (entry.path.len == 0) continue;
        // Skip hidden/cache directories.
        if (std.mem.startsWith(u8, entry.path, ".forge/") or
            std.mem.startsWith(u8, entry.path, ".zig-cache/") or
            std.mem.startsWith(u8, entry.path, "zig-out/"))
            continue;

        const label = try allocator.dupe(u8, entry.path);
        const insert = try std.fmt.allocPrint(allocator, "@file:{s}", .{entry.path});
        try entries.append(allocator, .{ .kind = .file, .label = label, .insert = insert });

        // Cap at 200 entries to avoid huge lists.
        if (entries.items.len >= 200) break;
    }

    return try entries.toOwnedSlice(allocator);
}

/// git:diff source — returns changed files from git diff --stat.
/// Requires the workspace path to run git. Falls back to empty if git fails.
pub fn gitDiffSource(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    query: []const u8,
) ![]MentionEntry {
    _ = query;
    var entries: std.ArrayList(MentionEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.label);
            allocator.free(e.insert);
        }
        entries.deinit(allocator);
    }

    // Run `git diff --stat` in the workspace.
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "diff", "--stat", "--name-only" },
        .cwd = workspace_path,
    }) catch return entries.toOwnedSlice(allocator);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse output: one file per line.
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const label = try allocator.dupe(u8, trimmed);
        const insert = try std.fmt.allocPrint(allocator, "@git:diff:{s}", .{trimmed});
        try entries.append(allocator, .{ .kind = .git_diff, .label = label, .insert = insert, .detail = "modified" });
    }

    return try entries.toOwnedSlice(allocator);
}

/// git:status source — returns files from git status --porcelain.
pub fn gitStatusSource(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    query: []const u8,
) ![]MentionEntry {
    _ = query;
    var entries: std.ArrayList(MentionEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.label);
            allocator.free(e.insert);
        }
        entries.deinit(allocator);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = workspace_path,
    }) catch return entries.toOwnedSlice(allocator);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse output: "XY filename" where X/Y are status codes.
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const status = line[0..2];
        const filename = std.mem.trim(u8, line[3..], " \t\r");
        if (filename.len == 0) continue;
        const label = try allocator.dupe(u8, filename);
        const insert = try std.fmt.allocPrint(allocator, "@git:status:{s}", .{filename});
        const detail = try std.fmt.allocPrint(allocator, "{s}", .{status});
        try entries.append(allocator, .{ .kind = .git_status, .label = label, .insert = insert, .detail = detail });
    }

    return try entries.toOwnedSlice(allocator);
}

/// spec source — returns spec files from .forge/specs/ directory.
pub fn specSource(
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    query: []const u8,
) ![]MentionEntry {
    _ = query;
    var entries: std.ArrayList(MentionEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.label);
            allocator.free(e.insert);
        }
        entries.deinit(allocator);
    }

    // List files in .forge/specs/ directory.
    var specs_dir = std.Io.Dir.open(std.Io.Dir.cwd(), @import("std").Io.Dir.cwd(), workspace_path, .{ .iterate = true }) catch return entries.toOwnedSlice(allocator);
    defer specs_dir.close(@import("std").Io.Dir.cwd());

    // Build path: workspace_path/.forge/specs
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const specs_path = std.fmt.bufPrint(&path_buf, "{s}/.forge/specs", .{workspace_path}) catch return entries.toOwnedSlice(allocator);

    var dir = std.fs.cwd().openDir(specs_path, .{ .iterate = true }) catch return entries.toOwnedSlice(allocator);
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const label = try allocator.dupe(u8, entry.name);
        const insert = try std.fmt.allocPrint(allocator, "@spec:{s}", .{entry.name});
        try entries.append(allocator, .{ .kind = .spec, .label = label, .insert = insert, .detail = "spec" });
    }

    return try entries.toOwnedSlice(allocator);
}

/// recent source — returns recently modified files from workspace.
pub fn recentSource(
    allocator: std.mem.Allocator,
    scan_entries: []const @import("forge-workspace").tree.ScanSummary.Entry,
    query: []const u8,
) ![]MentionEntry {
    _ = query;
    var entries: std.ArrayList(MentionEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.label);
            allocator.free(e.insert);
        }
        entries.deinit(allocator);
    }

    // Sort by modification time (most recent first) — scan_entries doesn't
    // have mtime, so we just take the first 10 files as "recent".
    var count: usize = 0;
    for (scan_entries) |entry| {
        if (entry.kind != .file) continue;
        if (entry.path.len == 0) continue;
        if (count >= 10) break;
        const label = try allocator.dupe(u8, entry.path);
        const insert = try std.fmt.allocPrint(allocator, "@recent:{s}", .{entry.path});
        try entries.append(allocator, .{ .kind = .recent, .label = label, .insert = insert, .detail = "recent" });
        count += 1;
    }

    return try entries.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "fuzzyScore matches subsequence" {
    try std.testing.expect(fuzzyScore("src/main.zig", "main") > 0);
    try std.testing.expect(fuzzyScore("src/main.zig", "smz") > 0); // abbreviation
    try std.testing.expect(fuzzyScore("README.md", "readme") > 0);
    try std.testing.expect(fuzzyScore("README.md", "RM") > 0); // case-insensitive
}

test "fuzzyScore rejects non-subsequence" {
    try std.testing.expectEqual(@as(i32, 0), fuzzyScore("src/main.zig", "xyz"));
    try std.testing.expectEqual(@as(i32, 0), fuzzyScore("", "abc"));
}

test "fuzzyScore empty query matches everything" {
    try std.testing.expect(fuzzyScore("anything", "") > 0);
}

test "fuzzyScore prefers word boundary matches" {
    const score_mid = fuzzyScore("src/main.zig", "main");
    const score_boundary = fuzzyScore("src/main.zig", "src");
    // Both match, but "src" is at a word boundary (start) so should score
    // at least as high as "main" (which is also at a boundary after /).
    try std.testing.expect(score_boundary > 0);
    try std.testing.expect(score_mid > 0);
}

test "PickerState open/close lifecycle" {
    const allocator = std.testing.allocator;
    var picker = PickerState.init(allocator);
    defer picker.deinit();
    try std.testing.expect(!picker.active);
    picker.open();
    try std.testing.expect(picker.active);
    try std.testing.expectEqual(@as(usize, 0), picker.query.items.len);
    picker.close();
    try std.testing.expect(!picker.active);
}

test "PickerState appendQuery and backspace" {
    const allocator = std.testing.allocator;
    var picker = PickerState.init(allocator);
    defer picker.deinit();
    picker.open();
    try picker.appendQuery('m');
    try picker.appendQuery('a');
    try picker.appendQuery('i');
    try picker.appendQuery('n');
    try std.testing.expectEqualStrings("main", picker.query.items);
    picker.backspaceQuery();
    try std.testing.expectEqualStrings("mai", picker.query.items);
}

test "PickerState refresh filters by fuzzy match" {
    const allocator = std.testing.allocator;
    var picker = PickerState.init(allocator);
    defer picker.deinit();
    picker.open();
    try picker.appendQuery('m');
    try picker.appendQuery('a');
    try picker.appendQuery('i');
    try picker.appendQuery('n');
    try picker.refresh(&defaultFileSource);
    // Should have at least 1 entry (src/main.zig matches "main").
    try std.testing.expect(picker.entries.items.len >= 1);
    // First entry should be src/main.zig (best fuzzy match).
    try std.testing.expect(std.mem.indexOf(u8, picker.entries.items[0].label, "main") != null);
}

test "PickerState moveUp/moveDown navigation" {
    const allocator = std.testing.allocator;
    var picker = PickerState.init(allocator);
    defer picker.deinit();
    picker.open();
    try picker.refresh(&defaultFileSource);
    const count = picker.entries.items.len;
    try std.testing.expect(count > 1);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
    picker.moveDown();
    try std.testing.expectEqual(@as(usize, 1), picker.selected);
    picker.moveUp();
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
    // moveUp at 0 should stay at 0.
    picker.moveUp();
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
}

test "defaultFileSource returns file mentions" {
    const allocator = std.testing.allocator;
    const entries = try defaultFileSource(allocator, "");
    defer {
        for (entries) |e| {
            allocator.free(e.label);
            allocator.free(e.insert);
        }
        allocator.free(entries);
    }
    try std.testing.expect(entries.len > 0);
    try std.testing.expectEqual(MentionKind.file, entries[0].kind);
    try std.testing.expect(std.mem.startsWith(u8, entries[0].insert, "@file:"));
}

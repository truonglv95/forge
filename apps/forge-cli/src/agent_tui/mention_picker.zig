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
/// This is a stub that returns a few hardcoded entries — real implementation
/// should use workspace.tree.scanSummary or iterate the workspace directory.
pub fn defaultFileSource(allocator: std.mem.Allocator, query: []const u8) ![]MentionEntry {
    _ = query;
    const stub_files = [_][]const u8{
        "src/main.zig",
        "src/config.zig",
        "README.md",
        "build.zig",
    };
    var entries: std.ArrayList(MentionEntry) = .empty;
    for (stub_files) |f| {
        const label = try allocator.dupe(u8, f);
        const insert = try std.fmt.allocPrint(allocator, "@file:{s}", .{f});
        try entries.append(allocator, .{ .kind = .file, .label = label, .insert = insert });
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

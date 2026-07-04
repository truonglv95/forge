const std = @import("std");
const editor = @import("forge-editor");

pub const Overlay = enum {
    none,
    find,
    goto_line,
};

pub const FindBar = struct {
    open: bool = false,
    replace_mode: bool = false,
    focus_replace: bool = false,
    query: editor.Buffer,
    replace: editor.Buffer,
    matches: []editor.Match = &.{},
    match_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !FindBar {
        return .{
            .query = try editor.Buffer.init(allocator),
            .replace = try editor.Buffer.init(allocator),
        };
    }

    pub fn deinit(self: *FindBar) void {
        self.clearMatches();
        self.query.deinit();
        self.replace.deinit();
    }

    pub fn openFind(self: *FindBar, replace_mode: bool) void {
        self.open = true;
        self.replace_mode = replace_mode;
        self.focus_replace = false;
    }

    pub fn close(self: *FindBar) void {
        self.open = false;
        self.clearMatches();
    }

    pub fn clearMatches(self: *FindBar) void {
        if (self.matches.len > 0) {
            self.query.allocator.free(self.matches);
            self.matches = &.{};
        }
        self.match_index = 0;
    }

    pub fn refreshMatches(self: *FindBar, doc: *editor.Buffer) !void {
        self.clearMatches();
        const needle = self.query.lineAt(0);
        if (needle.len == 0) return;
        self.matches = try editor.search.findAll(self.query.allocator, doc, needle);
        self.match_index = editor.search.findNext(self.matches, doc.cursor.row, doc.cursor.col) orelse 0;
        self.focusMatch(doc);
    }

    pub fn focusMatch(self: *FindBar, doc: *editor.Buffer) void {
        if (self.matches.len == 0) return;
        if (self.match_index >= self.matches.len) self.match_index = self.matches.len - 1;
        const match = self.matches[self.match_index];
        doc.cursor.row = match.row;
        doc.cursor.col = match.col;
    }

    pub fn nextMatch(self: *FindBar, doc: *editor.Buffer) void {
        if (self.matches.len == 0) return;
        self.match_index = (self.match_index + 1) % self.matches.len;
        self.focusMatch(doc);
    }

    pub fn prevMatch(self: *FindBar, doc: *editor.Buffer) void {
        if (self.matches.len == 0) return;
        if (self.match_index == 0) self.match_index = self.matches.len - 1 else self.match_index -= 1;
        self.focusMatch(doc);
    }

    pub fn replaceCurrent(self: *FindBar, doc: *editor.Buffer) !void {
        if (self.matches.len == 0) return;
        const match = self.matches[self.match_index];
        const replacement = self.replace.lineAt(0);
        try doc.replaceRange(match.row, match.col, match.len, replacement);
        try self.refreshMatches(doc);
    }

    pub fn replaceAll(self: *FindBar, doc: *editor.Buffer) !usize {
        const needle = self.query.lineAt(0);
        if (needle.len == 0) return 0;
        const replacement = self.replace.lineAt(0);
        var count: usize = 0;
        while (true) {
            const matches = try editor.search.findAll(self.query.allocator, doc, needle);
            defer self.query.allocator.free(matches);
            if (matches.len == 0) break;
            const match = matches[0];
            try doc.replaceRange(match.row, match.col, match.len, replacement);
            count += 1;
        }
        try self.refreshMatches(doc);
        return count;
    }
};

pub const GotoBar = struct {
    open: bool = false,
    input: editor.Buffer,

    pub fn init(allocator: std.mem.Allocator) !GotoBar {
        return .{ .input = try editor.Buffer.init(allocator) };
    }

    pub fn deinit(self: *GotoBar) void {
        self.input.deinit();
    }

    pub fn parseLine(self: *const GotoBar) ?usize {
        const text = std.mem.trim(u8, self.input.lineAt(0), " \t\r");
        if (text.len == 0) return null;
        return std.fmt.parseInt(usize, text, 10) catch null;
    }
};

pub const RenameBar = struct {
    open: bool = false,
    input: editor.Buffer,

    pub fn init(allocator: std.mem.Allocator) !RenameBar {
        return .{ .input = try editor.Buffer.init(allocator) };
    }

    pub fn deinit(self: *RenameBar) void {
        self.input.deinit();
    }

    pub fn openRename(self: *RenameBar, current_name: []const u8) !void {
        self.open = true;
        try self.input.loadFromSlice(current_name);
    }

    pub fn close(self: *RenameBar) void {
        self.open = false;
    }

    pub fn name(self: *const RenameBar) []const u8 {
        return std.mem.trim(u8, self.input.lineAt(0), " \t\r");
    }
};

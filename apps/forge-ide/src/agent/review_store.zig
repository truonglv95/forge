const std = @import("std");
const workspace = @import("forge-workspace");
const edit = workspace.edit;
const preview = workspace.preview;

pub const InlineSpan = struct {
    line: usize,
    start_col: usize,
    end_col: usize,
    kind: enum { deletion, insertion_preview },
};

pub const Hunk = struct {
    file_index: usize,
    edit_index: ?usize,
    path: []const u8,
    label: []const u8,
    accepted: bool = true,
    diff_lines: []const []const u8,
    edit_start: ?u64 = null,
    edit_end: ?u64 = null,
    replacement: ?[]const u8 = null,

    pub fn deinit(self: *Hunk, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.label);
        for (self.diff_lines) |line| allocator.free(line);
        allocator.free(self.diff_lines);
        if (self.replacement) |text| allocator.free(text);
        self.* = undefined;
    }
};

pub const Store = struct {
    hunks: []Hunk = &.{},
    revision: u64 = 0,

    pub fn clear(self: *Store, allocator: std.mem.Allocator) void {
        for (self.hunks) |*hunk| hunk.deinit(allocator);
        allocator.free(self.hunks);
        self.hunks = &.{};
        self.revision += 1;
    }

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn toggle(self: *Store, index: usize) void {
        if (index >= self.hunks.len) return;
        self.hunks[index].accepted = !self.hunks[index].accepted;
        self.revision += 1;
    }

    pub fn acceptAll(self: *Store) void {
        for (self.hunks) |*hunk| hunk.accepted = true;
        self.revision += 1;
    }

    pub fn rejectAll(self: *Store) void {
        for (self.hunks) |*hunk| hunk.accepted = false;
        self.revision += 1;
    }

    pub fn acceptedCount(self: Store) usize {
        var count: usize = 0;
        for (self.hunks) |hunk| {
            if (hunk.accepted) count += 1;
        }
        return count;
    }

    pub fn buildFromProposal(
        self: *Store,
        allocator: std.mem.Allocator,
        io: std.Io,
        root: workspace.WorkspaceRoot,
        proposal: *const workspace.OwnedProposal,
    ) !void {
        self.clear(allocator);

        var list: std.ArrayList(Hunk) = .empty;
        errdefer {
            for (list.items) |*hunk| hunk.deinit(allocator);
            list.deinit(allocator);
        }

        for (proposal.files, 0..) |file_edit, file_index| {
            switch (file_edit.operation) {
                .create, .delete => {
                    try appendFileHunk(allocator, io, root, &list, file_index, null, file_edit);
                },
                .modify => {
                    if (file_edit.edits.len == 0) {
                        try appendFileHunk(allocator, io, root, &list, file_index, null, file_edit);
                    } else {
                        for (file_edit.edits, 0..) |text_edit, edit_index| {
                            try appendEditHunk(allocator, io, root, &list, file_index, edit_index, file_edit, text_edit);
                        }
                    }
                },
            }
        }

        self.hunks = try list.toOwnedSlice(allocator);
        self.revision += 1;
    }

    pub fn hitTestHunk(
        self: Store,
        click_y: f32,
        review_top_y: f32,
        review_scroll_y: f32,
    ) ?usize {
        var y = review_top_y - review_scroll_y;
        for (self.hunks, 0..) |hunk, index| {
            const block_h = hunkBlockHeight(hunk);
            if (click_y >= y and click_y < y + block_h) return index;
            y += block_h + 4;
        }
        return null;
    }

    pub fn hunkBlockHeight(hunk: Hunk) f32 {
        return 14.0 + @as(f32, @floatFromInt(hunk.diff_lines.len)) * 12.0;
    }

    pub fn totalContentHeight(self: Store) f32 {
        var h: f32 = 0;
        for (self.hunks) |hunk| {
            h += hunkBlockHeight(hunk) + 4;
        }
        return h;
    }

    pub const OwnedWorkspaceEdit = struct {
        files: []edit.FileEdit,

        pub fn deinit(self: *OwnedWorkspaceEdit, allocator: std.mem.Allocator) void {
            for (self.files) |file| {
                allocator.free(file.path);
                for (file.edits) |text_edit| allocator.free(text_edit.replacement);
                allocator.free(file.edits);
            }
            allocator.free(self.files);
            self.* = undefined;
        }

        pub fn workspaceEdit(self: *const OwnedWorkspaceEdit) edit.WorkspaceEdit {
            return .{ .files = self.files };
        }
    };

    pub fn buildAcceptedEdit(
        self: Store,
        allocator: std.mem.Allocator,
        proposal: *const workspace.OwnedProposal,
    ) !OwnedWorkspaceEdit {
        var files: std.ArrayList(edit.FileEdit) = .empty;
        errdefer {
            for (files.items) |file| {
                allocator.free(file.path);
                for (file.edits) |text_edit| allocator.free(text_edit.replacement);
                allocator.free(file.edits);
            }
            files.deinit(allocator);
        }

        for (proposal.files, 0..) |file_edit, file_index| {
            var accepted_edits: std.ArrayList(edit.TextEdit) = .empty;
            defer accepted_edits.deinit(allocator);
            var file_accepted = false;

            for (self.hunks) |hunk| {
                if (hunk.file_index != file_index or !hunk.accepted) continue;
                file_accepted = true;
                if (hunk.edit_index) |edit_index| {
                    const source = file_edit.edits[edit_index];
                    try accepted_edits.append(allocator, .{
                        .start = source.start,
                        .end = source.end,
                        .replacement = try allocator.dupe(u8, source.replacement),
                    });
                }
            }

            if (!file_accepted) continue;

            const edits = if (file_edit.operation == .modify and file_edit.edits.len > 0)
                try accepted_edits.toOwnedSlice(allocator)
            else
                try cloneTextEdits(allocator, file_edit.edits);

            try files.append(allocator, .{
                .path = try allocator.dupe(u8, file_edit.path),
                .operation = file_edit.operation,
                .expected_hash = file_edit.expected_hash,
                .edits = edits,
            });
        }

        if (files.items.len == 0) return error.NoAcceptedHunks;

        const built = try files.toOwnedSlice(allocator);
        const ws = edit.WorkspaceEdit{ .files = built };
        try ws.validate();

        return .{ .files = built };
    }

    pub fn collectInlineSpans(
        self: Store,
        allocator: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
    ) ![]InlineSpan {
        var spans: std.ArrayList(InlineSpan) = .empty;
        errdefer spans.deinit(allocator);

        for (self.hunks) |hunk| {
            if (!hunk.accepted) continue;
            if (!std.mem.eql(u8, hunk.path, path)) continue;
            const start = hunk.edit_start orelse continue;
            const end = hunk.edit_end orelse continue;

            const del_start = byteOffsetToLineCol(content, @intCast(start));
            const del_end = byteOffsetToLineCol(content, @intCast(end));

            if (del_start.line == del_end.line) {
                try spans.append(allocator, .{
                    .line = del_start.line,
                    .start_col = del_start.col,
                    .end_col = del_end.col,
                    .kind = .deletion,
                });
            } else {
                const line_len = lineLenAt(content, del_start.line);
                try spans.append(allocator, .{
                    .line = del_start.line,
                    .start_col = del_start.col,
                    .end_col = line_len,
                    .kind = .deletion,
                });
                var line = del_start.line + 1;
                while (line < del_end.line) : (line += 1) {
                    try spans.append(allocator, .{
                        .line = line,
                        .start_col = 0,
                        .end_col = lineLenAt(content, line),
                        .kind = .deletion,
                    });
                }
                if (del_end.line > del_start.line) {
                    try spans.append(allocator, .{
                        .line = del_end.line,
                        .start_col = 0,
                        .end_col = del_end.col,
                        .kind = .deletion,
                    });
                }
            }

            if (hunk.replacement) |replacement| {
                if (replacement.len > 0) {
                    const ins_line = del_start.line;
                    const ins_col = del_start.col;
                    const first_line_end = std.mem.indexOfScalar(u8, replacement, '\n') orelse replacement.len;
                    try spans.append(allocator, .{
                        .line = ins_line,
                        .start_col = ins_col,
                        .end_col = ins_col + first_line_end,
                        .kind = .insertion_preview,
                    });
                }
            }
        }

        return try spans.toOwnedSlice(allocator);
    }
};

fn appendFileHunk(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    list: *std.ArrayList(Hunk),
    file_index: usize,
    edit_index: ?usize,
    file_edit: edit.FileEdit,
) !void {
    const op_label = switch (file_edit.operation) {
        .create => "create",
        .delete => "delete",
        .modify => "modify",
    };
    const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ op_label, file_edit.path });
    errdefer allocator.free(label);

    const diff_lines = try renderFileDiff(allocator, io, root, file_edit);
    errdefer freeDiffLines(allocator, diff_lines);

    try list.append(allocator, .{
        .file_index = file_index,
        .edit_index = edit_index,
        .path = try allocator.dupe(u8, file_edit.path),
        .label = label,
        .diff_lines = diff_lines,
    });
}

fn appendEditHunk(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    list: *std.ArrayList(Hunk),
    file_index: usize,
    edit_index: usize,
    file_edit: edit.FileEdit,
    text_edit: edit.TextEdit,
) !void {
    const label = try std.fmt.allocPrint(allocator, "edit {s} [{d}..{d}]", .{
        file_edit.path,
        text_edit.start,
        text_edit.end,
    });
    errdefer allocator.free(label);

    const single = [_]edit.FileEdit{.{
        .path = file_edit.path,
        .operation = file_edit.operation,
        .expected_hash = file_edit.expected_hash,
        .edits = &[_]edit.TextEdit{text_edit},
    }};
    const diff_lines = try renderFileDiff(allocator, io, root, single[0]);
    errdefer freeDiffLines(allocator, diff_lines);

    try list.append(allocator, .{
        .file_index = file_index,
        .edit_index = edit_index,
        .path = try allocator.dupe(u8, file_edit.path),
        .label = label,
        .edit_start = text_edit.start,
        .edit_end = text_edit.end,
        .replacement = try allocator.dupe(u8, text_edit.replacement),
        .diff_lines = diff_lines,
    });
}

fn renderFileDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_edit: edit.FileEdit,
) ![]const []const u8 {
    const ws = edit.WorkspaceEdit{ .files = &[_]edit.FileEdit{file_edit} };
    var diff_writer = std.Io.Writer.Allocating.init(allocator);
    defer diff_writer.deinit();
    try preview.renderDiff(allocator, io, root, ws, &diff_writer.writer);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    const diff_bytes = diff_writer.writer.buffer[0..diff_writer.writer.end];
    var diff_it = std.mem.splitScalar(u8, diff_bytes, '\n');
    while (diff_it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(allocator, try allocator.dupe(u8, line));
    }

    return try lines.toOwnedSlice(allocator);
}

fn freeDiffLines(allocator: std.mem.Allocator, lines: []const []const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

fn cloneTextEdits(allocator: std.mem.Allocator, edits: []const edit.TextEdit) ![]edit.TextEdit {
    const owned = try allocator.alloc(edit.TextEdit, edits.len);
    errdefer allocator.free(owned);
    for (edits, 0..) |source, index| {
        owned[index] = .{
            .start = source.start,
            .end = source.end,
            .replacement = try allocator.dupe(u8, source.replacement),
        };
    }
    return owned;
}

const LineCol = struct { line: usize, col: usize };

fn byteOffsetToLineCol(content: []const u8, offset: usize) LineCol {
    var line: usize = 0;
    var col: usize = 0;
    var index: usize = 0;
    while (index < offset and index < content.len) : (index += 1) {
        if (content[index] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

fn lineLenAt(content: []const u8, line_index: usize) usize {
    var line: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= content.len) {
        if (index == content.len or content[index] == '\n') {
            if (line == line_index) return index - start;
            start = index + 1;
            line += 1;
        }
        index += 1;
    }
    return 0;
}

test "buildAcceptedEdit keeps only accepted hunks" {
    const changes = [_]edit.TextEdit{
        .{ .start = 0, .end = 3, .replacement = "foo" },
        .{ .start = 10, .end = 12, .replacement = "bar" },
    };
    const files = [_]edit.FileEdit{
        .{ .path = "src/a.zig", .operation = .modify, .expected_hash = 1, .edits = &changes },
    };
    var proposal = workspace.OwnedProposal{
        .allocator = std.testing.allocator,
        .files = undefined,
    };
    proposal.files = try std.testing.allocator.dupe(edit.FileEdit, &files);
    defer proposal.deinit();

    var store = Store{
        .hunks = try std.testing.allocator.alloc(Hunk, 2),
    };
    defer store.deinit(std.testing.allocator);
    store.hunks[0] = .{
        .file_index = 0,
        .edit_index = 0,
        .path = try std.testing.allocator.dupe(u8, "src/a.zig"),
        .label = try std.testing.allocator.dupe(u8, "edit 0"),
        .accepted = false,
        .diff_lines = &.{},
    };
    store.hunks[1] = .{
        .file_index = 0,
        .edit_index = 1,
        .path = try std.testing.allocator.dupe(u8, "src/a.zig"),
        .label = try std.testing.allocator.dupe(u8, "edit 1"),
        .accepted = true,
        .diff_lines = &.{},
        .edit_start = 10,
        .edit_end = 12,
        .replacement = try std.testing.allocator.dupe(u8, "bar"),
    };

    var filtered = try store.buildAcceptedEdit(std.testing.allocator, &proposal);
    defer filtered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), filtered.files.len);
    try std.testing.expectEqual(@as(usize, 1), filtered.files[0].edits.len);
    try std.testing.expectEqual(@as(u64, 10), filtered.files[0].edits[0].start);
}

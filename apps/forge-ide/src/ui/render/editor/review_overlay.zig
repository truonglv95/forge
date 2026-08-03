const renderer = @import("forge-renderer");
const std = @import("std");
const editor_scroll = @import("../../editor/editor_scroll.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const Buffer = @import("forge-editor").Buffer;

pub fn lineColAtBufferOffset(editor_buf: *Buffer, offset: usize) struct { line: usize, col: usize } {
    var pos: usize = 0;
    const line_count = editor_buf.lineCount();
    for (0..line_count) |line| {
        const line_len = editor_buf.lineAt(line).len;
        const line_end = pos + line_len;
        if (offset <= line_end) return .{ .line = line, .col = offset - pos };
        pos = line_end + 1;
    }
    if (line_count > 0) {
        const last = line_count - 1;
        return .{ .line = last, .col = editor_buf.lineAt(last).len };
    }
    return .{ .line = 0, .col = 0 };
}

pub const ResolvedHunk = struct {
    start_line: usize,
    end_line: usize,
    start_col: usize,
    end_col: usize,
    replacement: ?[]const u8,
};

pub const ReviewHunks = struct {
    items: [64]ResolvedHunk = undefined,
    len: usize = 0,

    pub fn append(self: *ReviewHunks, item: ResolvedHunk) !void {
        if (self.len >= self.items.len) return error.OutOfMemory;
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn slice(self: *const ReviewHunks) []const ResolvedHunk {
        return self.items[0..self.len];
    }
};

pub fn resolveHunks(wb: *Workbench, editor_buf: *Buffer, file_path: []const u8) ReviewHunks {
    var resolved_hunks = ReviewHunks{};
    if (!wb.agent_ui.session.show_review) return resolved_hunks;
    wb.agent_ui.session.lock();
    defer wb.agent_ui.session.unlock();

    var valid_hunks: std.ArrayList(*const @TypeOf(wb.agent_ui.session.review.hunks[0])) = .empty;
    defer valid_hunks.deinit(wb.allocator);

    for (wb.agent_ui.session.review.hunks) |*hunk| {
        if (!hunk.accepted or !std.mem.eql(u8, hunk.path, file_path)) continue;
        if (hunk.edit_start == null or hunk.edit_end == null) {
            resolved_hunks.append(.{
                .start_line = 0,
                .end_line = std.math.maxInt(usize),
                .start_col = 0,
                .end_col = 0,
                .replacement = hunk.replacement,
            }) catch {};
            continue;
        }
        valid_hunks.append(wb.allocator, hunk) catch {};
    }

    std.sort.pdq(*const @TypeOf(wb.agent_ui.session.review.hunks[0]), valid_hunks.items, {}, struct {
        pub fn less(_: void, a: *const @TypeOf(wb.agent_ui.session.review.hunks[0]), b: *const @TypeOf(wb.agent_ui.session.review.hunks[0])) bool {
            return a.edit_start.? < b.edit_start.?;
        }
    }.less);

    var pos: usize = 0;
    var line: usize = 0;
    const line_count = editor_buf.lineCount();

    for (valid_hunks.items) |hunk| {
        var start_l: usize = 0;
        var start_c: usize = 0;
        var end_l: usize = 0;
        var end_c: usize = 0;

        while (line < line_count) {
            const line_len = editor_buf.lineAt(line).len;
            if (hunk.edit_start.? <= pos + line_len) {
                start_l = line;
                start_c = hunk.edit_start.? - pos;
                break;
            }
            pos += line_len + 1;
            line += 1;
        }
        if (line >= line_count) {
            start_l = if (line_count > 0) line_count - 1 else 0;
            start_c = if (line_count > 0) editor_buf.lineAt(start_l).len else 0;
        }

        while (line < line_count) {
            const line_len = editor_buf.lineAt(line).len;
            if (hunk.edit_end.? <= pos + line_len) {
                end_l = line;
                end_c = hunk.edit_end.? - pos;
                break;
            }
            pos += line_len + 1;
            line += 1;
        }
        if (line >= line_count) {
            end_l = if (line_count > 0) line_count - 1 else 0;
            end_c = if (line_count > 0) editor_buf.lineAt(end_l).len else 0;
        }

        resolved_hunks.append(.{
            .start_line = start_l,
            .end_line = end_l,
            .start_col = start_c,
            .end_col = end_c,
            .replacement = hunk.replacement,
        }) catch {};
    }

    return resolved_hunks;
}

pub fn reviewLineHasChange(
    resolved_hunks: []const ResolvedHunk,
    line_index: usize,
) bool {
    for (resolved_hunks) |hunk| {
        if (line_index >= hunk.start_line and line_index <= hunk.end_line) return true;
    }
    return false;
}

pub fn drawReviewLineOverlay(
    resolved_hunks: []const ResolvedHunk,
    theme: *const @import("forge-workspace").Theme,
    editor_buf: *Buffer,
    line_index: usize,
    text_x: f32,
    line_y: f32,
    line_h: f32,
    font_size: f32,
) void {
    const line = editor_buf.lineAt(line_index);
    for (resolved_hunks) |hunk| {
        if (line_index < hunk.start_line or line_index > hunk.end_line) continue;

        const start_col = if (line_index == hunk.start_line) hunk.start_col else 0;
        const end_col = if (line_index == hunk.end_line) hunk.end_col else line.len;
        const start_x = text_x + editor_scroll.cursorX(line, start_col, font_size);
        const end_x = text_x + editor_scroll.cursorX(line, end_col, font_size);
        renderer.Renderer.drawRect(start_x, line_y, @max(4, end_x - start_x), line_h, .{ .r = 0.75, .g = 0.2, .b = 0.2, .a = 0.28 });

        if (hunk.replacement) |replacement| {
            if (replacement.len > 0 and line_index == hunk.start_line) {
                const first_line_end = std.mem.indexOfScalar(u8, replacement, '\n') orelse replacement.len;
                const preview = replacement[0..first_line_end];
                const ins_x = text_x + editor_scroll.cursorX(line, start_col, font_size);
                const ins_w = @as(f32, @floatFromInt(preview.len)) * editor_scroll.charWidth(theme);
                renderer.Renderer.drawRect(ins_x, line_y, @max(4, ins_w), line_h, .{ .r = 0.2, .g = 0.65, .b = 0.3, .a = 0.35 });
            }
        }
    }
}

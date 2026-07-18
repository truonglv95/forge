const std = @import("std");
const renderer = @import("forge-renderer");
const word_wrap = @import("../editor/word_wrap.zig");
const chat_markdown = @import("chat_markdown.zig");
const diff_line_style = @import("../diff_line_style.zig");

pub const LineRange = struct {
    start: u32,
    end: u32,
};

pub const Block = union(enum) {
    text_lines: []LineRange,
    code_lines: []LineRange,
};

pub const Entry = struct {
    markdown: bool = false,
    markdown_runtime: bool = false,
    ranges: []LineRange = &.{},
    blocks: []Block = &.{},
    height: f32 = 0,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.ranges.len > 0) allocator.free(self.ranges);
        for (self.blocks) |block| switch (block) {
            .text_lines => |lines| allocator.free(lines),
            .code_lines => |lines| allocator.free(lines),
        };
        if (self.blocks.len > 0) allocator.free(self.blocks);
        self.* = .{};
    }
};

const bubble_pad_y: f32 = 10.0;
const bubble_gap: f32 = 16.0;
const layout_safety_pad: f32 = 8.0;

fn lineHasInlineMarkup(line: []const u8) bool {
    for (line) |ch| {
        if (ch == '`') return true;
    }
    return std.mem.indexOf(u8, line, "**") != null;
}

fn paragraphHasInlineMarkup(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lineHasInlineMarkup(line)) return true;
    }
    return false;
}

fn paragraphHasBlockMarkdown(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (chat_markdown.lineHasBlockMarkdown(line)) return true;
    }
    return false;
}

fn findFence(text: []const u8, from: usize) ?struct { open_end: usize, close_start: usize } {
    const marker = "```";
    const open = std.mem.indexOfPos(u8, text, from, marker) orelse return null;
    var line_end = open + marker.len;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    if (line_end < text.len and text[line_end] == '\n') line_end += 1;
    const close = std.mem.indexOfPos(u8, text, line_end, marker) orelse return null;
    return .{ .open_end = line_end, .close_start = close };
}

fn trimRange(text: []const u8, start: usize, end: usize) struct { start: usize, end: usize } {
    var s = start;
    var e = end;
    while (s < e and std.ascii.isWhitespace(text[s])) s += 1;
    while (e > s and std.ascii.isWhitespace(text[e - 1])) e -= 1;
    return .{ .start = s, .end = e };
}

fn appendWrappedLine(
    allocator: std.mem.Allocator,
    ranges: *std.ArrayList(LineRange),
    line: []const u8,
    line_offset_in_text: usize,
    max_w: f32,
    font_size: f32,
) !void {
    var start: usize = 0;
    while (start < line.len) {
        const end = word_wrap.breakAt(line, start, max_w, font_size);
        try ranges.append(allocator, .{
            .start = @intCast(line_offset_in_text + start),
            .end = @intCast(line_offset_in_text + end),
        });
        if (end >= line.len) break;
        start = end;
        while (start < line.len and line[start] == ' ') start += 1;
    }
}

fn appendLinesInRange(
    allocator: std.mem.Allocator,
    ranges: *std.ArrayList(LineRange),
    text: []const u8,
    range_start: usize,
    range_end: usize,
    max_w: f32,
    font_size: f32,
) !void {
    var i = range_start;
    while (i <= range_end) {
        const line_end = std.mem.indexOfPos(u8, text, i, "\n") orelse range_end;
        const actual_end = @min(line_end, range_end);
        if (actual_end == i) {
            try ranges.append(allocator, .{ .start = 0, .end = 0 });
        } else {
            try appendWrappedLine(allocator, ranges, text[i..actual_end], i, max_w, font_size);
        }
        if (line_end >= range_end) break;
        i = line_end + 1;
    }
}

fn codeBlockInnerWidth(content_w: f32) f32 {
    return @max(20.0, content_w - chat_markdown.code_pad * 2);
}

fn appendCodeBlockLines(
    allocator: std.mem.Allocator,
    ranges: *std.ArrayList(LineRange),
    text: []const u8,
    code_start: usize,
    code_end: usize,
    content_w: f32,
) !void {
    const inner_w = codeBlockInnerWidth(content_w);
    try appendLinesInRange(allocator, ranges, text, code_start, code_end, inner_w, chat_markdown.code_font_size);
    if (ranges.items.len == 0) try ranges.append(allocator, .{ .start = 0, .end = 0 });
}

fn blockHeight(block: Block) f32 {
    return switch (block) {
        .text_lines => |lines| @max(chat_markdown.body_line_h, @as(f32, @floatFromInt(lines.len)) * chat_markdown.body_line_h),
        .code_lines => |lines| blk: {
            const line_count = @max(1, lines.len);
            break :blk chat_markdown.code_pad * 2 +
                @as(f32, @floatFromInt(line_count)) * chat_markdown.code_line_h +
                chat_markdown.code_gap;
        },
    };
}

fn buildMarkdownCached(allocator: std.mem.Allocator, text: []const u8, content_w: f32) !Entry {
    const max_w = word_wrap.maxWidth(content_w);
    var blocks: std.ArrayList(Block) = .empty;
    errdefer {
        for (blocks.items) |block| switch (block) {
            .text_lines => |lines| allocator.free(lines),
            .code_lines => |lines| allocator.free(lines),
        };
        blocks.deinit(allocator);
    }

    var total_h: f32 = 0;
    var cursor: usize = 0;
    while (cursor < text.len) {
        if (findFence(text, cursor)) |fence| {
            if (fence.open_end > cursor) {
                const trimmed = trimRange(text, cursor, fence.open_end - 1);
                if (trimmed.end > trimmed.start) {
                    const para = text[trimmed.start..trimmed.end];
                    if (paragraphHasInlineMarkup(para) or paragraphHasBlockMarkdown(para)) return error.NeedsRuntimeMarkdown;
                    var text_lines: std.ArrayList(LineRange) = .empty;
                    errdefer text_lines.deinit(allocator);
                    try appendLinesInRange(allocator, &text_lines, text, trimmed.start, trimmed.end, max_w, chat_markdown.body_font_size);
                    const owned = try text_lines.toOwnedSlice(allocator);
                    const block: Block = .{ .text_lines = owned };
                    total_h += blockHeight(block);
                    try blocks.append(allocator, block);
                }
            }
            var code_lines: std.ArrayList(LineRange) = .empty;
            errdefer code_lines.deinit(allocator);
            try appendCodeBlockLines(allocator, &code_lines, text, fence.open_end, fence.close_start, content_w);
            const owned_code = try code_lines.toOwnedSlice(allocator);
            const block: Block = .{ .code_lines = owned_code };
            total_h += blockHeight(block);
            try blocks.append(allocator, block);
            cursor = fence.close_start + 3;
            if (cursor < text.len and text[cursor] == '\n') cursor += 1;
            continue;
        }
        const trimmed = trimRange(text, cursor, text.len);
        if (trimmed.end > trimmed.start) {
            const tail = text[trimmed.start..trimmed.end];
            if (paragraphHasInlineMarkup(tail) or paragraphHasBlockMarkdown(tail)) return error.NeedsRuntimeMarkdown;
            var text_lines: std.ArrayList(LineRange) = .empty;
            errdefer text_lines.deinit(allocator);
            try appendLinesInRange(allocator, &text_lines, text, trimmed.start, trimmed.end, max_w, chat_markdown.body_font_size);
            const owned = try text_lines.toOwnedSlice(allocator);
            const block: Block = .{ .text_lines = owned };
            total_h += blockHeight(block);
            try blocks.append(allocator, block);
        }
        break;
    }

    return .{
        .markdown = true,
        .blocks = try blocks.toOwnedSlice(allocator),
        .height = @max(chat_markdown.body_line_h, total_h),
    };
}

fn buildPlain(allocator: std.mem.Allocator, text: []const u8, content_w: f32) !Entry {
    const max_w = word_wrap.maxWidth(content_w);
    var ranges: std.ArrayList(LineRange) = .empty;
    errdefer ranges.deinit(allocator);

    try appendLinesInRange(allocator, &ranges, text, 0, text.len, max_w, chat_markdown.body_font_size);
    if (ranges.items.len == 0) try ranges.append(allocator, .{ .start = 0, .end = 0 });

    const height = @max(
        chat_markdown.body_line_h,
        @as(f32, @floatFromInt(ranges.items.len)) * chat_markdown.body_line_h,
    );
    return .{
        .ranges = try ranges.toOwnedSlice(allocator),
        .height = height,
    };
}

pub fn build(allocator: std.mem.Allocator, text: []const u8, content_w: f32) !Entry {
    if (text.len == 0) return .{};
    if (chat_markdown.usesMarkdown(text)) {
        if (buildMarkdownCached(allocator, text, content_w)) |entry| return entry else |_| {
            return .{
                .markdown = true,
                .markdown_runtime = true,
                .height = chat_markdown.contentHeight(text, content_w),
            };
        }
    }
    return buildPlain(allocator, text, content_w);
}

pub fn layoutHeight(entry: Entry, is_user: bool, text: []const u8, content_w: f32) f32 {
    _ = content_w;
    if (text.len == 0 or entry.height == 0) return 0;
    if (is_user) return entry.height + bubble_pad_y * 2 + bubble_gap + layout_safety_pad;
    return @import("chat_bubble.zig").agent_header_h + entry.height + bubble_gap + layout_safety_pad;
}

pub fn drawPlain(text: []const u8, entry: *const Entry, x: f32, y: f32, fg: renderer.Color) f32 {
    if (entry.ranges.len == 0) return 0;
    var line_y = y;
    for (entry.ranges) |range| {
        if (range.start < range.end) {
            renderer.Renderer.drawText(text[range.start..range.end], x, line_y, chat_markdown.body_font_size, fg);
        }
        line_y += chat_markdown.body_line_h;
    }
    return line_y - y;
}

pub fn drawCached(
    text: []const u8,
    entry: *const Entry,
    x: f32,
    y: f32,
    content_w: f32,
    style: chat_markdown.Style,
) f32 {
    if (entry.blocks.len > 0) {
        var line_y = y;
        for (entry.blocks) |block| {
            switch (block) {
                .text_lines => |lines| {
                    for (lines) |range| {
                        if (range.start < range.end) {
                            renderer.Renderer.drawText(text[range.start..range.end], x, line_y, chat_markdown.body_font_size, style.fg);
                        }
                        line_y += chat_markdown.body_line_h;
                    }
                },
                .code_lines => |lines| {
                    const h = chat_markdown.code_pad * 2 +
                        @as(f32, @floatFromInt(@max(1, lines.len))) * chat_markdown.code_line_h +
                        chat_markdown.code_gap;
                    const block_h = h - chat_markdown.code_gap;
                    renderer.Renderer.drawRoundedRect(x, line_y, content_w, block_h, 6, style.code_block_border);
                    renderer.Renderer.drawRoundedRect(x + 1, line_y + 1, @max(1.0, content_w - 2), @max(1.0, block_h - 2), 5, style.code_block_bg);
                    var code_y = line_y + chat_markdown.code_pad;
                    for (lines) |range| {
                        const slice = if (range.start < range.end) text[range.start..range.end] else "";
                        const kind = diff_line_style.classify(slice);
                        const default_fg = style.code_block_fg;
                        const fg = diff_line_style.foreground(kind, slice, true, default_fg);
                        if (diff_line_style.background(kind, true)) |bg| {
                            renderer.Renderer.drawRect(x + 1, code_y - 1, @max(1.0, content_w - 2), chat_markdown.code_line_h, bg);
                        }
                        if (slice.len > 0) {
                            renderer.Renderer.drawText(slice, x + 1 + chat_markdown.code_pad, code_y, chat_markdown.code_font_size, fg);
                        }
                        code_y += chat_markdown.code_line_h;
                    }
                    line_y += h;
                },
            }
        }
        return line_y - y;
    }
    return drawPlain(text, entry, x, y, style.fg);
}

pub fn draw(text: []const u8, entry: *const Entry, x: f32, y: f32, fg: renderer.Color) f32 {
    return drawPlain(text, entry, x, y, fg);
}

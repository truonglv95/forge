const std = @import("std");
const renderer = @import("forge-renderer");
const word_wrap = @import("../editor/word_wrap.zig");
const diff_line_style = @import("../diff_line_style.zig");

pub const body_font_size: f32 = 14.0;
pub const body_line_h: f32 = 16.0;
pub const code_font_size: f32 = 12.0;
pub const code_line_h: f32 = 14.0;
pub const code_pad: f32 = 6.0;
pub const code_gap: f32 = 4.0;

pub const Style = struct {
    fg: renderer.Color,
    bold_fg: renderer.Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    inline_code_fg: renderer.Color = .{ .r = 0.85, .g = 0.92, .b = 1.0, .a = 1.0 },
    inline_code_bg: renderer.Color = .{ .r = 0.22, .g = 0.24, .b = 0.3, .a = 1.0 },
    code_block_fg: renderer.Color = .{ .r = 0.88, .g = 0.9, .b = 0.94, .a = 1.0 },
    code_block_bg: renderer.Color = .{ .r = 0.1, .g = 0.11, .b = 0.14, .a = 1.0 },
};

const Segment = union(enum) {
    text: []const u8,
    bold: []const u8,
    code: []const u8,
};

fn findFence(text: []const u8, from: usize) ?struct { open_end: usize, close_start: usize } {
    const marker = "```";
    const open = std.mem.indexOfPos(u8, text, from, marker) orelse return null;
    var line_end = open + marker.len;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    if (line_end < text.len and text[line_end] == '\n') line_end += 1;
    const close = std.mem.indexOfPos(u8, text, line_end, marker) orelse return null;
    return .{ .open_end = line_end, .close_start = close };
}

fn codeBlockInnerWidth(content_w: f32) f32 {
    return @max(20.0, content_w - code_pad * 2);
}

fn codeLineVisualCount(line: []const u8, content_w: f32) usize {
    if (line.len == 0) return 1;
    return word_wrap.segmentCount(line, codeBlockInnerWidth(content_w), code_font_size);
}

fn codeBlockVisualLineCount(code: []const u8, content_w: f32) usize {
    if (code.len == 0) return 1;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |line| {
        count += codeLineVisualCount(line, content_w);
    }
    return @max(1, count);
}

fn codeBlockHeight(code: []const u8, content_w: f32) f32 {
    const lines = codeBlockVisualLineCount(code, content_w);
    return code_pad * 2 + @as(f32, @floatFromInt(lines)) * code_line_h + code_gap;
}

fn paragraphLineCount(text: []const u8, max_w: f32) usize {
    if (text.len == 0) return 0;
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            total += 1;
            continue;
        }
        total += word_wrap.segmentCount(line, max_w, body_font_size);
    }
    return total;
}

pub fn contentHeight(text: []const u8, content_w: f32) f32 {
    if (text.len == 0) return body_line_h;
    const max_w = word_wrap.maxWidth(content_w);
    var total: f32 = 0;
    var cursor: usize = 0;
    while (cursor < text.len) {
        if (findFence(text, cursor)) |fence| {
            if (fence.open_end > cursor) {
                const para = std.mem.trim(u8, &std.ascii.whitespace, text[cursor .. fence.open_end - 1]);
                if (para.len > 0) {
                    total += @as(f32, @floatFromInt(paragraphLineCount(para, max_w))) * body_line_h;
                }
            }
            const code = text[fence.open_end..fence.close_start];
            total += codeBlockHeight(code, content_w);
            cursor = fence.close_start + 3;
            if (cursor < text.len and text[cursor] == '\n') cursor += 1;
            continue;
        }
        const tail = std.mem.trim(u8, &std.ascii.whitespace, text[cursor..]);
        if (tail.len > 0) {
            total += @as(f32, @floatFromInt(paragraphLineCount(tail, max_w))) * body_line_h;
        }
        break;
    }
    return @max(body_line_h, total);
}

fn freeSegments(allocator: std.mem.Allocator, segments: []Segment) void {
    for (segments) |seg| switch (seg) {
        .text, .bold, .code => |s| allocator.free(s),
    };
    allocator.free(segments);
}

fn parseInlineLine(allocator: std.mem.Allocator, line: []const u8) ![]Segment {
    var segments: std.ArrayList(Segment) = .empty;
    errdefer {
        for (segments.items) |seg| switch (seg) {
            .text, .bold, .code => |s| allocator.free(s),
        };
        segments.deinit(allocator);
    }

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            const rest = line[i + 1 ..];
            const close_rel = std.mem.indexOfScalar(u8, rest, '`') orelse {
                const tail = try allocator.dupe(u8, line[i..]);
                try segments.append(allocator, .{ .text = tail });
                return try segments.toOwnedSlice(allocator);
            };
            if (i > 0) {
                const plain = try allocator.dupe(u8, line[0..i]);
                try segments.append(allocator, .{ .text = plain });
            }
            const code = try allocator.dupe(u8, rest[0..close_rel]);
            try segments.append(allocator, .{ .code = code });
            const tail_segments = try parseInlineLine(allocator, rest[close_rel + 1 ..]);
            defer freeSegments(allocator, tail_segments);
            try segments.appendSlice(allocator, tail_segments);
            return try segments.toOwnedSlice(allocator);
        }
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            const rest = line[i + 2 ..];
            const close_rel = std.mem.indexOfPos(u8, rest, 0, "**") orelse {
                const tail = try allocator.dupe(u8, line[i..]);
                try segments.append(allocator, .{ .text = tail });
                return try segments.toOwnedSlice(allocator);
            };
            if (i > 0) {
                const plain = try allocator.dupe(u8, line[0..i]);
                try segments.append(allocator, .{ .text = plain });
            }
            const bold = try allocator.dupe(u8, rest[0..close_rel]);
            try segments.append(allocator, .{ .bold = bold });
            const tail_segments = try parseInlineLine(allocator, rest[close_rel + 2 ..]);
            defer freeSegments(allocator, tail_segments);
            try segments.appendSlice(allocator, tail_segments);
            return try segments.toOwnedSlice(allocator);
        }
        i += 1;
    }

    if (line.len > 0) {
        const plain = try allocator.dupe(u8, line);
        try segments.append(allocator, .{ .text = plain });
    }
    return try segments.toOwnedSlice(allocator);
}

fn lineHasInlineMarkup(line: []const u8) bool {
    for (line) |ch| {
        if (ch == '`') return true;
    }
    return std.mem.indexOf(u8, line, "**") != null;
}

fn drawPlainWrappedLine(line: []const u8, x: f32, y: f32, max_w: f32, fg: renderer.Color) f32 {
    var line_y = y;
    var start: usize = 0;
    while (start < line.len) {
        const end = word_wrap.breakAt(line, start, max_w, body_font_size);
        const part = line[start..end];
        if (part.len > 0) {
            renderer.Renderer.drawText(part, x, line_y, body_font_size, fg);
        }
        if (end >= line.len) break;
        line_y += body_line_h;
        start = end;
        while (start < line.len and line[start] == ' ') start += 1;
    }
    return line_y + body_line_h - y;
}

fn drawInlineLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    x: f32,
    y: f32,
    max_w: f32,
    style: Style,
) !f32 {
    if (!lineHasInlineMarkup(line)) {
        return drawPlainWrappedLine(line, x, y, max_w, style.fg);
    }

    const segments = try parseInlineLine(allocator, line);
    defer freeSegments(allocator, segments);

    var cursor_x = x;
    var line_y = y;
    for (segments) |seg| {
        switch (seg) {
            .text => |slice| {
                var start: usize = 0;
                while (start < slice.len) {
                    const end = word_wrap.breakAt(slice, start, max_w - (cursor_x - x), body_font_size);
                    const part = slice[start..end];
                    if (part.len > 0) {
                        renderer.Renderer.drawText(part, cursor_x, line_y, body_font_size, style.fg);
                        cursor_x += renderer.Renderer.measureText(part, body_font_size);
                    }
                    if (end >= slice.len) break;
                    line_y += body_line_h;
                    cursor_x = x;
                    start = end;
                    while (start < slice.len and slice[start] == ' ') start += 1;
                }
            },
            .bold => |slice| {
                var start: usize = 0;
                while (start < slice.len) {
                    const end = word_wrap.breakAt(slice, start, max_w - (cursor_x - x), body_font_size);
                    const part = slice[start..end];
                    if (part.len > 0) {
                        renderer.Renderer.drawText(part, cursor_x, line_y, body_font_size, style.bold_fg);
                        cursor_x += renderer.Renderer.measureText(part, body_font_size);
                    }
                    if (end >= slice.len) break;
                    line_y += body_line_h;
                    cursor_x = x;
                    start = end;
                    while (start < slice.len and slice[start] == ' ') start += 1;
                }
            },
            .code => |slice| {
                const w = renderer.Renderer.measureText(slice, code_font_size) + 6;
                renderer.Renderer.drawRoundedRect(cursor_x, line_y + 1, w, code_line_h - 2, 3, style.inline_code_bg);
                renderer.Renderer.drawText(slice, cursor_x + 3, line_y + 1, code_font_size, style.inline_code_fg);
                cursor_x += w + 2;
            },
        }
    }
    return line_y + body_line_h - y;
}

fn drawParagraph(
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f32,
    y: f32,
    content_w: f32,
    style: Style,
) !f32 {
    const max_w = word_wrap.maxWidth(content_w);
    var line_y = y;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            line_y += body_line_h;
            continue;
        }
        const drawn = try drawInlineLine(allocator, line, x, line_y, max_w, style);
        line_y += if (drawn > 0) drawn else body_line_h;
    }
    return line_y - y;
}

fn drawCodeBlockLine(
    line: []const u8,
    x: f32,
    y: f32,
    content_w: f32,
    style: Style,
) f32 {
    const kind = diff_line_style.classify(line);
    const inner_w = codeBlockInnerWidth(content_w);
    const default_fg = style.code_block_fg;
    const fg = diff_line_style.foreground(kind, line, true, default_fg);
    var line_y = y;
    var start: usize = 0;
    if (line.len == 0) return code_line_h;

    while (start < line.len) {
        const end = word_wrap.breakAt(line, start, inner_w, code_font_size);
        if (diff_line_style.background(kind, true)) |bg| {
            renderer.Renderer.drawRect(x, line_y - 1, content_w, code_line_h, bg);
        }
        const part = line[start..end];
        if (part.len > 0) {
            renderer.Renderer.drawText(part, x + code_pad, line_y, code_font_size, fg);
        }
        if (end >= line.len) break;
        line_y += code_line_h;
        start = end;
        while (start < line.len and line[start] == ' ') start += 1;
    }
    return line_y + code_line_h - y;
}

fn drawCodeBlock(code: []const u8, x: f32, y: f32, content_w: f32, style: Style) f32 {
    const h = codeBlockHeight(code, content_w);
    renderer.Renderer.drawRoundedRect(x, y, content_w, h - code_gap, 6, style.code_block_bg);
    var line_y = y + code_pad;
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |line| {
        const drawn = drawCodeBlockLine(line, x, line_y, content_w, style);
        line_y += if (drawn > 0) drawn else code_line_h;
    }
    return h;
}

pub fn drawSimpleContent(text: []const u8, x: f32, y: f32, content_w: f32, fg: renderer.Color) f32 {
    return drawPlainWrappedLine(text, x, y, word_wrap.maxWidth(content_w), fg);
}

pub fn drawContent(
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f32,
    y: f32,
    content_w: f32,
    style: Style,
) !f32 {
    if (text.len == 0) return body_line_h;
    var cursor_y = y;
    var cursor: usize = 0;
    while (cursor < text.len) {
        if (findFence(text, cursor)) |fence| {
            if (fence.open_end > cursor) {
                const para = std.mem.trim(u8, &std.ascii.whitespace, text[cursor .. fence.open_end - 1]);
                if (para.len > 0) {
                    cursor_y += try drawParagraph(allocator, para, x, cursor_y, content_w, style);
                }
            }
            const code = text[fence.open_end..fence.close_start];
            cursor_y += drawCodeBlock(code, x, cursor_y, content_w, style);
            cursor = fence.close_start + 3;
            if (cursor < text.len and text[cursor] == '\n') cursor += 1;
            continue;
        }
        const tail = std.mem.trim(u8, &std.ascii.whitespace, text[cursor..]);
        if (tail.len > 0) {
            cursor_y += try drawParagraph(allocator, tail, x, cursor_y, content_w, style);
        }
        break;
    }
    return cursor_y - y;
}

test "code fence height" {
    const text = "Hello\n```zig\nconst x = 1;\n```\nTail";
    const h = contentHeight(text, 200);
    try std.testing.expect(h > 48);
}

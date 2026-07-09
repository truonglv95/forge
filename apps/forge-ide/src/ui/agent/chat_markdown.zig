const std = @import("std");
const renderer = @import("forge-renderer");
const word_wrap = @import("../editor/word_wrap.zig");
const diff_line_style = @import("../diff_line_style.zig");

pub const body_font_size: f32 = 14.0;
pub const body_line_h: f32 = 18.0;
pub const code_font_size: f32 = 12.0;
pub const code_line_h: f32 = 21.0;
pub const code_pad: f32 = 6.0;
pub const code_gap: f32 = 4.0;
pub const heading_font_size: f32 = 15.0;
pub const heading_line_h: f32 = 20.0;
pub const list_indent: f32 = 14.0;
pub const quote_indent: f32 = 10.0;
pub const markdown_block_gap: f32 = 4.0;

pub const Style = struct {
    fg: renderer.Color,
    bold_fg: renderer.Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    inline_code_fg: renderer.Color = .{ .r = 0.85, .g = 0.92, .b = 1.0, .a = 1.0 },
    inline_code_bg: renderer.Color = .{ .r = 0.22, .g = 0.24, .b = 0.3, .a = 1.0 },
    code_block_fg: renderer.Color = .{ .r = 0.88, .g = 0.9, .b = 0.94, .a = 1.0 },
    code_block_bg: renderer.Color = .{ .r = 0.1, .g = 0.11, .b = 0.14, .a = 1.0 },
    top_square: bool = false,
};

const Segment = union(enum) {
    text: []const u8,
    bold: []const u8,
    code: []const u8,
};

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, &std.ascii.whitespace);
}

fn headingBody(line: []const u8) ?[]const u8 {
    const trimmed = trimLine(line);
    if (trimmed.len < 3 or trimmed[0] != '#') return null;
    var count: usize = 0;
    while (count < trimmed.len and count < 6 and trimmed[count] == '#') : (count += 1) {}
    if (count == 0 or count >= trimmed.len or trimmed[count] != ' ') return null;
    return std.mem.trim(u8, trimmed[count + 1 ..], " ");
}

fn bulletBody(line: []const u8) ?[]const u8 {
    const trimmed = trimLine(line);
    if (trimmed.len < 2 or trimmed[1] != ' ') return null;
    return switch (trimmed[0]) {
        '-', '*', '+' => std.mem.trim(u8, trimmed[2..], " "),
        else => null,
    };
}

fn numberedMarkerLen(line: []const u8) ?usize {
    const trimmed = trimLine(line);
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) : (i += 1) {}
    if (i == 0 or i + 1 >= trimmed.len) return null;
    if (trimmed[i] != '.' or trimmed[i + 1] != ' ') return null;
    return i + 2;
}

fn quoteBody(line: []const u8) ?[]const u8 {
    const trimmed = trimLine(line);
    if (trimmed.len < 2 or trimmed[0] != '>' or trimmed[1] != ' ') return null;
    return std.mem.trim(u8, trimmed[2..], " ");
}

pub fn lineHasBlockMarkdown(line: []const u8) bool {
    return headingBody(line) != null or
        bulletBody(line) != null or
        numberedMarkerLen(line) != null or
        quoteBody(line) != null;
}

pub fn usesMarkdown(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "```") != null or
        std.mem.indexOf(u8, text, "**") != null or
        std.mem.indexOfScalar(u8, text, '`') != null)
    {
        return true;
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lineHasBlockMarkdown(line)) return true;
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

fn codeBlockInnerWidth(content_w: f32) f32 {
    return @max(20.0, content_w - code_pad * 2);
}

fn codeLineVisualCount(line: []const u8) usize {
    _ = line;
    return 1;
}

fn getCommonIndent(code: []const u8) usize {
    var common_indent: usize = std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, code, '\n');
    var has_non_empty = false;
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
        if (indent < common_indent) common_indent = indent;
        has_non_empty = true;
    }
    return if (has_non_empty) common_indent else 0;
}

fn codeBlockVisualLineCount(code: []const u8) usize {
    if (code.len == 0) return 1;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |_| {
        count += 1;
    }
    return @max(1, count);
}

fn codeBlockHeight(code: []const u8) f32 {
    const lines = codeBlockVisualLineCount(code);
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

fn markdownLineHeight(line: []const u8, max_w: f32) f32 {
    if (line.len == 0) return body_line_h;
    if (headingBody(line)) |body| {
        const count = @max(1, word_wrap.segmentCount(body, max_w, heading_font_size));
        return @as(f32, @floatFromInt(count)) * heading_line_h + markdown_block_gap;
    }
    if (bulletBody(line)) |body| {
        const count = @max(1, word_wrap.segmentCount(body, @max(20.0, max_w - list_indent), body_font_size));
        return @as(f32, @floatFromInt(count)) * body_line_h;
    }
    if (numberedMarkerLen(line)) |marker_len| {
        const trimmed = trimLine(line);
        const body = std.mem.trim(u8, trimmed[marker_len..], " ");
        const count = @max(1, word_wrap.segmentCount(body, @max(20.0, max_w - list_indent), body_font_size));
        return @as(f32, @floatFromInt(count)) * body_line_h;
    }
    if (quoteBody(line)) |body| {
        const count = @max(1, word_wrap.segmentCount(body, @max(20.0, max_w - quote_indent), body_font_size));
        return @as(f32, @floatFromInt(count)) * body_line_h;
    }
    return @as(f32, @floatFromInt(word_wrap.segmentCount(line, max_w, body_font_size))) * body_line_h;
}

fn markdownTextHeight(text: []const u8, max_w: f32) f32 {
    if (text.len == 0) return 0;
    var total: f32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        total += markdownLineHeight(line, max_w);
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
            const open_start = std.mem.indexOfPos(u8, text, cursor, "```").?;
            if (open_start > cursor) {
                const para = std.mem.trim(u8, text[cursor..open_start], &std.ascii.whitespace);
                if (para.len > 0) {
                    total += markdownTextHeight(para, max_w);
                }
            }
            var code = text[fence.open_end..fence.close_start];
            code = std.mem.trimEnd(u8, code, " \n\r\t");
            total += codeBlockHeight(code);
            cursor = fence.close_start + 3;
            if (cursor < text.len and text[cursor] == '\n') cursor += 1;
            continue;
        }
        const tail = std.mem.trim(u8, text[cursor..], &std.ascii.whitespace);
        if (tail.len > 0) {
            total += markdownTextHeight(tail, max_w);
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
            defer allocator.free(tail_segments);
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
            defer allocator.free(tail_segments);
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

fn drawPlainWrappedLineWith(
    line: []const u8,
    x: f32,
    y: f32,
    max_w: f32,
    font_size: f32,
    line_h: f32,
    fg: renderer.Color,
) f32 {
    var line_y = y;
    var start: usize = 0;
    while (start < line.len) {
        const end = word_wrap.breakAt(line, start, max_w, font_size);
        const part = line[start..end];
        if (part.len > 0) {
            renderer.Renderer.drawText(part, x, line_y, font_size, fg);
        }
        if (end >= line.len) break;
        line_y += line_h;
        start = end;
        while (start < line.len and line[start] == ' ') start += 1;
    }
    return line_y + line_h - y;
}

fn drawPlainWrappedLine(line: []const u8, x: f32, y: f32, max_w: f32, fg: renderer.Color) f32 {
    return drawPlainWrappedLineWith(line, x, y, max_w, body_font_size, body_line_h, fg);
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

fn drawMarkdownLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    x: f32,
    y: f32,
    content_w: f32,
    style: Style,
) !f32 {
    const max_w = word_wrap.maxWidth(content_w);
    if (headingBody(line)) |body| {
        return drawPlainWrappedLineWith(body, x, y, max_w, heading_font_size, heading_line_h, style.bold_fg) + markdown_block_gap;
    }
    if (bulletBody(line)) |body| {
        renderer.Renderer.drawText("-", x, y, body_font_size, style.bold_fg);
        return try drawInlineLine(allocator, body, x + list_indent, y, @max(20.0, max_w - list_indent), style);
    }
    if (numberedMarkerLen(line)) |marker_len| {
        const trimmed = trimLine(line);
        const marker = trimmed[0..@min(marker_len, trimmed.len)];
        const body = std.mem.trim(u8, trimmed[marker_len..], " ");
        renderer.Renderer.drawText(marker, x, y, body_font_size, style.bold_fg);
        return try drawInlineLine(allocator, body, x + list_indent, y, @max(20.0, max_w - list_indent), style);
    }
    if (quoteBody(line)) |body| {
        renderer.Renderer.drawRect(x, y + 1, 2, body_line_h - 2, style.inline_code_bg);
        return try drawInlineLine(allocator, body, x + quote_indent, y, @max(20.0, max_w - quote_indent), style);
    }
    return try drawParagraph(allocator, line, x, y, content_w, style);
}

fn isPunctuation(ch: u8) bool {
    return ch == '(' or ch == ')' or ch == '{' or ch == '}' or ch == ';' or ch == ',' or ch == '[' or ch == ']' or ch == '.' or ch == ':' or ch == '=';
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "pub", "fn", "const", "var", "let", "function", "class", "import", "from", "export", "struct", "enum", "union", "return", "try", "catch", "if", "else", "switch", "while", "for", "break", "continue", "defer", "errdefer", "await", "async", "interface", "type", "new" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn drawCodeBlockLine(
    line: []const u8,
    x: f32,
    y: f32,
    content_w: f32,
    scroll_x: f32,
    style: Style,
    lang: []const u8,
) f32 {
    const is_diff = std.mem.eql(u8, lang, "diff");
    const kind = diff_line_style.classify(line);
    const default_fg = style.code_block_fg;
    const fg = if (is_diff) diff_line_style.foreground(kind, line, true, default_fg) else default_fg;
    if (line.len == 0) return 0.0;

    if (is_diff) {
        if (diff_line_style.background(kind, true)) |bg| {
            renderer.Renderer.drawRect(x, y - 1, content_w, code_line_h, bg);
        }
    }
    const part = line;
    const draw_x = x + code_pad - scroll_x;
    if (part.len > 0) {
        if (is_diff) {
            renderer.Renderer.drawText(part, draw_x, y, code_font_size, fg);
        } else {
            var spans: [256]renderer.TextSpan = undefined;
            var span_count: usize = 0;
            var i: usize = 0;
            while (i < part.len and span_count < spans.len) {
                const word_start = i;
                var c = default_fg;
                if (part[i] == ' ') {
                    i += 1;
                } else if (isPunctuation(part[i])) {
                    c = .{ .r = 0.55, .g = 0.6, .b = 0.65, .a = 1.0 };
                    i += 1;
                } else if (part[i] == '"' or part[i] == '\'') {
                    c = .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 };
                    const quote = part[i];
                    i += 1;
                    while (i < part.len and part[i] != quote) : (i += 1) {
                        if (part[i] == '\\' and i + 1 < part.len) i += 1;
                    }
                    if (i < part.len) i += 1;
                } else if (std.ascii.isDigit(part[i])) {
                    c = .{ .r = 0.9, .g = 0.6, .b = 0.4, .a = 1.0 };
                    while (i < part.len and (std.ascii.isDigit(part[i]) or part[i] == '.' or part[i] == 'x' or part[i] == 'a' or part[i] == 'b' or part[i] == 'c' or part[i] == 'd' or part[i] == 'e' or part[i] == 'f')) : (i += 1) {}
                } else {
                    while (i < part.len and !isPunctuation(part[i]) and part[i] != ' ') : (i += 1) {}
                    const word = part[word_start..i];
                    if (isKeyword(word)) {
                        c = .{ .r = 0.8, .g = 0.5, .b = 0.8, .a = 1.0 };
                    } else if (word.len > 0 and word[0] >= 'A' and word[0] <= 'Z') {
                        c = .{ .r = 0.4, .g = 0.8, .b = 0.8, .a = 1.0 };
                    } else if (i < part.len and part[i] == '(') {
                        c = .{ .r = 0.4, .g = 0.7, .b = 1.0, .a = 1.0 };
                    }
                }
                spans[span_count] = .{ .offset = @intCast(word_start), .length = @intCast(i - word_start), .r = c.r, .g = c.g, .b = c.b, .a = c.a };
                span_count += 1;
            }
            if (span_count > 0) {
                renderer.Renderer.drawStyledText(part, draw_x, y, code_font_size, spans[0..span_count]);
            } else {
                renderer.Renderer.drawText(part, draw_x, y, code_font_size, fg);
            }
        }
    }
    return renderer.Renderer.measureText(part, code_font_size) + code_pad * 2;
}

pub fn drawCodeBlock(code: []const u8, x: f32, y: f32, content_w: f32, style: Style, lang: []const u8, scroll_x: f32, out_max_w: *f32) f32 {
    const h = codeBlockHeight(code);
    renderer.Renderer.drawRoundedRect(x, y, content_w, h - code_gap, 6, style.code_block_bg);
    if (style.top_square) {
        renderer.Renderer.drawRect(x, y, content_w, 6, style.code_block_bg);
    }
    const common_indent = getCommonIndent(code);
    var line_y = y + code_pad;

    renderer.Renderer.pushClipRect(x, y, content_w, h - code_gap);
    var lines = std.mem.splitScalar(u8, code, '\n');
    var max_w: f32 = 0;
    while (lines.next()) |line| {
        const display_line = if (line.len >= common_indent) line[common_indent..] else line;
        const line_w = drawCodeBlockLine(display_line, x, line_y, content_w, scroll_x, style, lang);
        if (line_w > max_w) max_w = line_w;
        line_y += code_line_h;
    }
    renderer.Renderer.popClipRect();
    out_max_w.* = max_w;
    return h;
}

pub fn drawSimpleContent(text: []const u8, x: f32, y: f32, content_w: f32, fg: renderer.Color) f32 {
    if (text.len == 0) return body_line_h;
    var line_y = y;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            line_y += body_line_h;
            continue;
        }
        line_y += drawPlainWrappedLine(line, x, line_y, content_w, fg);
    }
    return line_y - y;
}

pub fn drawContent(
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f32,
    y: f32,
    content_w: f32,
    style: Style,
    wb: ?*@import("../../workbench.zig").Workbench,
    base_hash: u64,
) !f32 {
    if (text.len == 0) return body_line_h;
    var cursor_y = y;
    var cursor: usize = 0;
    while (cursor < text.len) {
        if (findFence(text, cursor)) |fence| {
            const open_start = std.mem.indexOfPos(u8, text, cursor, "```").?;
            if (open_start > cursor) {
                const para = std.mem.trim(u8, text[cursor..open_start], &std.ascii.whitespace);
                if (para.len > 0) {
                    var lines = std.mem.splitScalar(u8, para, '\n');
                    while (lines.next()) |line| {
                        if (line.len == 0) {
                            cursor_y += body_line_h;
                            continue;
                        }
                        cursor_y += try drawMarkdownLine(allocator, line, x, cursor_y, content_w, style);
                    }
                }
            }
            var code = text[fence.open_end..fence.close_start];
            code = std.mem.trimEnd(u8, code, " \n\r\t");
            const lang = std.mem.trim(u8, text[open_start + 3 .. fence.open_end - 1], &std.ascii.whitespace);

            var scroll_x: f32 = 0;
            var code_hash: u64 = 0;
            if (wb) |w| {
                code_hash = std.hash.Wyhash.hash(base_hash + cursor, code);
                if (w.code_scroll_x.get(code_hash)) |state| {
                    scroll_x = state.scroll_x;
                }
            }

            var max_w: f32 = 0;
            const block_h = drawCodeBlock(code, x, cursor_y, content_w, style, lang, scroll_x, &max_w);

            if (wb) |w| {
                var state = w.code_scroll_x.get(code_hash) orelse @import("../../workbench.zig").Workbench.CodeScrollState{};
                const max_scroll = @max(0, max_w - content_w);
                state.max_scroll_x = max_scroll;
                w.code_scroll_x.put(code_hash, state) catch {};

                w.rendered_code_blocks.append(allocator, .{
                    .hash = code_hash,
                    .x = x,
                    .y = cursor_y,
                    .w = content_w,
                    .h = block_h,
                }) catch {};
            }

            cursor_y += block_h;

            cursor = fence.close_start + 3;
            if (cursor < text.len and text[cursor] == '\n') cursor += 1;
            continue;
        }
        const tail = std.mem.trim(u8, text[cursor..], &std.ascii.whitespace);
        if (tail.len > 0) {
            var lines = std.mem.splitScalar(u8, tail, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) {
                    cursor_y += body_line_h;
                    continue;
                }
                cursor_y += try drawMarkdownLine(allocator, line, x, cursor_y, content_w, style);
            }
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

test "markdown headings and lists are detected and taller than plain text" {
    const text = "### Overview\n- LSP has diagnostics\n1. Completion works with `items`";
    try std.testing.expect(usesMarkdown(text));
    try std.testing.expect(lineHasBlockMarkdown("### Overview"));
    try std.testing.expect(lineHasBlockMarkdown("- LSP has diagnostics"));
    try std.testing.expect(contentHeight(text, 220) > body_line_h * 3);
}

test "markdown vietnamese final answer keeps visible body height" {
    const text =
        \\Dựa trên việc khám phá mã nguồn, đây là đánh giá tổng thể về dự án **Forge**:
        \\
        \\### Tổng quan dự án
        \\- Forge là một IDE native viết bằng Zig.
    ;
    try std.testing.expect(usesMarkdown(text));
    try std.testing.expect(contentHeight(text, 260) > body_line_h * 4);
}

test "inline markdown parser keeps appended segment ownership" {
    const allocator = std.testing.allocator;
    const segments = try parseInlineLine(allocator, "hello **bold** and `code` tail");
    defer freeSegments(allocator, segments);
    try std.testing.expect(segments.len >= 5);
}

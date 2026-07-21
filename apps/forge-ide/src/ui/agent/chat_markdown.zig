const std = @import("std");
const renderer = @import("forge-renderer");
const word_wrap = @import("../editor/word_wrap.zig");
const diff_line_style = @import("../diff_line_style.zig");
const metrics = @import("metrics.zig");
const tokens = @import("../tokens.zig");

pub var body_font_size: f32 = 14.5;
pub var body_line_h: f32 = 24.0;
pub var code_font_size: f32 = 12.5;
pub var code_line_h: f32 = 21.0;
pub var code_pad: f32 = 10.0;
pub var code_gap: f32 = 8.0;
pub var heading_font_size: f32 = 15.5;
pub var heading_line_h: f32 = 25.0;
pub var list_indent: f32 = 20.0;
pub var quote_indent: f32 = 14.0;
var paragraph_gap: f32 = 14.0;
var list_item_gap: f32 = 6.0;
var quote_pad_x: f32 = 10.0;
var quote_pad_y: f32 = 8.0;
var inline_code_pad_x: f32 = 3.5;
var inline_code_gap: f32 = 4.0;
pub var markdown_block_gap: f32 = 10.0;
pub var heading_gap_top: f32 = 15.0;
pub var heading_gap_bottom: f32 = 10.0;

const prose_text_style = metrics.typography.prose_style;
const bold_text_style = metrics.typography.strong_style;
const code_text_style = metrics.typography.code_style;

pub const Style = struct {
    fg: renderer.Color,
    bold_fg: renderer.Color = tokens.color.text_primary,
    inline_code_fg: renderer.Color = tokens.color.inline_code_fg,
    inline_code_bg: renderer.Color = tokens.color.inline_code_bg,
    code_block_fg: renderer.Color = tokens.color.code_fg,
    code_block_bg: renderer.Color = tokens.color.surface_recessed,
    code_block_border: renderer.Color = tokens.color.border,
    quote_bg: renderer.Color = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 0.62 },
    quote_bar: renderer.Color = tokens.color.accent,
    list_marker: renderer.Color = tokens.color.accent,
    top_square: bool = false,
};

pub const RenderContext = struct {
    allocator: std.mem.Allocator,
    global_text: []const u8,
    selection: ?struct { start: usize, end: usize } = null,
    base_hash: u64 = 0,
    wb: ?*@import("../../workbench.zig").Workbench = null,
    hit_test: ?struct { x: f32, y: f32 } = null,
    hit_result: ?usize = null,

    pub fn isSelected(self: RenderContext, ptr: [*]const u8, len: usize) ?struct { start: usize, end: usize } {
        if (self.selection == null) return null;
        const s = self.selection.?;
        const t_start = @intFromPtr(self.global_text.ptr);
        const p_start = @intFromPtr(ptr);
        if (p_start < t_start or p_start >= t_start + self.global_text.len) return null;
        const seg_start = p_start - t_start;
        const seg_end = seg_start + len;
        if (s.end <= seg_start or s.start >= seg_end) return null;
        const inter_start = @max(s.start, seg_start) - seg_start;
        const inter_end = @min(s.end, seg_end) - seg_start;
        return .{ .start = inter_start, .end = inter_end };
    }
};

pub var current_render_context: ?*RenderContext = null;

const Segment = union(enum) {
    text: []const u8,
    bold: []const u8,
    code: []const u8,
};

const HeightCacheSlot = struct {
    key: u64 = 0,
    height: f32 = 0,
};

var height_cache: [512]HeightCacheSlot = [_]HeightCacheSlot{.{}} ** 512;
var height_cache_hits: u64 = 0;
var height_cache_misses: u64 = 0;

pub fn configureFontSize(font_size: f32) void {
    metrics.configureAiPanelFontSize(font_size);
    body_font_size = metrics.markdown.body_font_size;
    body_line_h = metrics.markdown.body_line_h;
    code_font_size = metrics.markdown.code_font_size;
    code_line_h = metrics.markdown.code_line_h;
    code_pad = metrics.markdown.code_pad;
    code_gap = metrics.markdown.code_gap;
    heading_font_size = metrics.markdown.heading_font_size;
    heading_line_h = metrics.markdown.heading_line_h;
    list_indent = metrics.markdown.list_indent;
    quote_indent = metrics.markdown.quote_indent;
    paragraph_gap = metrics.markdown.paragraph_gap;
    list_item_gap = metrics.markdown.list_item_gap;
    quote_pad_x = metrics.markdown.quote_pad_x;
    quote_pad_y = metrics.markdown.quote_pad_y;
    inline_code_pad_x = metrics.markdown.inline_code_pad_x;
    inline_code_gap = metrics.markdown.inline_code_gap;
    markdown_block_gap = metrics.markdown.block_gap;
    heading_gap_top = metrics.markdown.heading_gap_top;
    heading_gap_bottom = metrics.markdown.heading_gap_bottom;
    height_cache = [_]HeightCacheSlot{.{}} ** 512;
}

pub fn runtimeSafetyPad() f32 {
    return metrics.markdown.runtime_safety_pad;
}

fn heightCacheKey(text: []const u8, content_w: f32) u64 {
    var hasher = std.hash.Wyhash.init(0x4652475f4d445f48);
    const width_bits: u32 = @bitCast(content_w);
    hasher.update(std.mem.asBytes(&width_bits));
    hasher.update(text);
    const key = hasher.final();
    return if (key == 0) 1 else key;
}

pub fn heightCacheStats(hits: *u64, misses: *u64) void {
    hits.* = height_cache_hits;
    misses.* = height_cache_misses;
}

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

fn measureStyledText(text: []const u8, font_size: f32, text_style: renderer.TextStyle) f32 {
    return renderer.Renderer.measureTextWithStyle(text, font_size, text_style);
}

fn isAsciiSlice(text: []const u8) bool {
    for (text) |ch| {
        if (ch >= 0x80) return false;
    }
    return true;
}

fn nextUtf8Boundary(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    var next = index + 1;
    while (next < text.len and (text[next] & 0xc0) == 0x80) : (next += 1) {}
    return next;
}

fn breakAtStyled(line: []const u8, start: usize, max_w: f32, font_size: f32, text_style: renderer.TextStyle) usize {
    if (start >= line.len) return start;
    if (max_w <= 0) return @min(start + 1, line.len);

    const rest = line[start..];
    if (measureStyledText(rest, font_size, text_style) <= max_w) return line.len;

    if (!isAsciiSlice(rest)) {
        var end = start;
        var last_space: ?usize = null;
        var cursor = start;
        while (cursor < line.len) {
            const next = nextUtf8Boundary(line, cursor);
            if (next <= cursor) break;
            if (measureStyledText(line[start..next], font_size, text_style) > max_w) break;
            if (line[cursor] == ' ') last_space = next;
            end = next;
            cursor = next;
        }
        if (end < line.len and end > start) {
            if (last_space) |space_end| {
                if (space_end > start) return space_end;
            }
            return end;
        }
        return nextUtf8Boundary(line, start);
    }

    var lo: usize = start + 1;
    var hi: usize = line.len;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (measureStyledText(line[start..mid], font_size, text_style) <= max_w) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    var end = lo;
    if (end < line.len and end > start) {
        if (std.mem.lastIndexOfScalar(u8, line[start..end], ' ')) |rel| {
            const sp = start + rel + 1;
            if (sp > start) end = sp;
        }
    }
    return if (end > start) end else start + 1;
}

fn segmentCountStyled(line: []const u8, max_w: f32, font_size: f32, text_style: renderer.TextStyle) usize {
    if (line.len == 0) return 1;
    var count: usize = 0;
    var start: usize = 0;
    while (start < line.len) {
        const end = breakAtStyled(line, start, max_w, font_size, text_style);
        count += 1;
        if (end >= line.len) break;
        start = end;
        while (start < line.len and line[start] == ' ') start += 1;
    }
    return @max(1, count);
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
        total += segmentCountStyled(line, max_w, body_font_size, prose_text_style);
    }
    return total;
}

const InlineMeasure = struct {
    cursor_x: f32 = 0,
    line_count: usize = 1,

    fn addWrapped(self: *InlineMeasure, slice: []const u8, max_w: f32, font_size: f32, text_style: renderer.TextStyle) void {
        var start: usize = 0;
        while (start < slice.len) {
            var remaining_w = max_w - self.cursor_x;
            if (self.cursor_x > 0 and remaining_w < 20.0) {
                self.line_count += 1;
                self.cursor_x = 0;
                remaining_w = max_w;
            }
            const end = breakAtStyled(slice, start, remaining_w, font_size, text_style);
            const part = slice[start..end];
            if (part.len > 0) {
                self.cursor_x += measureStyledText(part, font_size, text_style);
            }
            if (end >= slice.len) break;
            self.line_count += 1;
            self.cursor_x = 0;
            start = end;
            while (start < slice.len and slice[start] == ' ') start += 1;
        }
    }

    fn addInlineCode(self: *InlineMeasure, slice: []const u8, max_w: f32) void {
        const w = measureStyledText(slice, code_font_size, code_text_style) + inline_code_pad_x * 2 + inline_code_gap;
        if (self.cursor_x > 0 and self.cursor_x + w > max_w) {
            self.line_count += 1;
            self.cursor_x = 0;
        }
        self.cursor_x += w;
    }
};

fn inlineMarkdownLineHeight(line: []const u8, max_w: f32) f32 {
    if (!lineHasInlineMarkup(line)) {
        return @as(f32, @floatFromInt(segmentCountStyled(line, max_w, body_font_size, prose_text_style))) * body_line_h;
    }

    var measure = InlineMeasure{};
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            const rest = line[i + 1 ..];
            const close_rel = std.mem.indexOfScalar(u8, rest, '`') orelse {
                measure.addWrapped(line[i..], max_w, body_font_size, prose_text_style);
                return @as(f32, @floatFromInt(measure.line_count)) * body_line_h;
            };
            measure.addInlineCode(rest[0..close_rel], max_w);
            i += close_rel + 2;
            continue;
        }
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            const rest = line[i + 2 ..];
            const close_rel = std.mem.indexOfPos(u8, rest, 0, "**") orelse {
                measure.addWrapped(line[i..], max_w, body_font_size, prose_text_style);
                return @as(f32, @floatFromInt(measure.line_count)) * body_line_h;
            };
            measure.addWrapped(rest[0..close_rel], max_w, body_font_size, bold_text_style);
            i += close_rel + 4;
            continue;
        }

        const code_pos = std.mem.indexOfScalarPos(u8, line, i, '`');
        const bold_pos = std.mem.indexOfPos(u8, line, i, "**");
        const next = if (code_pos) |c|
            if (bold_pos) |b| @min(c, b) else c
        else if (bold_pos) |b|
            b
        else
            line.len;
        measure.addWrapped(line[i..next], max_w, body_font_size, prose_text_style);
        i = next;
    }

    return @as(f32, @floatFromInt(measure.line_count)) * body_line_h;
}

fn markdownLineHeight(line: []const u8, max_w: f32) f32 {
    if (line.len == 0) return paragraph_gap;
    if (headingBody(line)) |body| {
        const count = @max(1, segmentCountStyled(body, max_w, heading_font_size, bold_text_style));
        return heading_gap_top + @as(f32, @floatFromInt(count)) * heading_line_h + heading_gap_bottom;
    }
    if (bulletBody(line)) |body| {
        return inlineMarkdownLineHeight(body, @max(20.0, max_w - list_indent)) + list_item_gap;
    }
    if (numberedMarkerLen(line)) |marker_len| {
        const trimmed = trimLine(line);
        const body = std.mem.trim(u8, trimmed[marker_len..], " ");
        return inlineMarkdownLineHeight(body, @max(20.0, max_w - list_indent)) + list_item_gap;
    }
    if (quoteBody(line)) |body| {
        return inlineMarkdownLineHeight(body, @max(20.0, max_w - quote_indent - quote_pad_x * 2)) + quote_pad_y * 2;
    }
    return inlineMarkdownLineHeight(line, max_w);
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
    const key = heightCacheKey(text, content_w);
    const start = @as(usize, @intCast(key % height_cache.len));
    var insert_idx = start;
    var probe: usize = 0;
    while (probe < 4) : (probe += 1) {
        const idx = (start + probe) % height_cache.len;
        const slot = height_cache[idx];
        if (slot.key == key) {
            height_cache_hits += 1;
            return slot.height;
        }
        if (slot.key == 0) {
            insert_idx = idx;
            break;
        }
    }

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
    const height = @max(body_line_h, total);
    height_cache_misses += 1;
    height_cache[insert_idx] = .{ .key = key, .height = height };
    return height;
}

fn freeSegments(allocator: std.mem.Allocator, segments: []Segment) void {
    allocator.free(segments);
}

fn parseInlineLine(allocator: std.mem.Allocator, line: []const u8) ![]Segment {
    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(allocator);

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '`') {
            const rest = line[i + 1 ..];
            const close_rel = std.mem.indexOfScalar(u8, rest, '`') orelse {
                try segments.append(allocator, .{ .text = line[i..] });
                return try segments.toOwnedSlice(allocator);
            };
            if (i > 0) {
                try segments.append(allocator, .{ .text = line[0..i] });
            }
            try segments.append(allocator, .{ .code = rest[0..close_rel] });
            const tail_segments = try parseInlineLine(allocator, rest[close_rel + 1 ..]);
            defer allocator.free(tail_segments);
            try segments.appendSlice(allocator, tail_segments);
            return try segments.toOwnedSlice(allocator);
        }
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            const rest = line[i + 2 ..];
            const close_rel = std.mem.indexOfPos(u8, rest, 0, "**") orelse {
                try segments.append(allocator, .{ .text = line[i..] });
                return try segments.toOwnedSlice(allocator);
            };
            if (i > 0) {
                try segments.append(allocator, .{ .text = line[0..i] });
            }
            try segments.append(allocator, .{ .bold = rest[0..close_rel] });
            const tail_segments = try parseInlineLine(allocator, rest[close_rel + 2 ..]);
            defer allocator.free(tail_segments);
            try segments.appendSlice(allocator, tail_segments);
            return try segments.toOwnedSlice(allocator);
        }
        i += 1;
    }

    if (line.len > 0) {
        try segments.append(allocator, .{ .text = line });
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
    text_style: renderer.TextStyle,
) f32 {
    var line_y = y;
    var start: usize = 0;
    while (start < line.len) {
        const end = breakAtStyled(line, start, max_w, font_size, text_style);
        const part = line[start..end];
        if (part.len > 0) {
            handleTextHitAndDraw(part, x, line_y, line_h, font_size, fg, text_style);
        }
        if (end >= line.len) break;
        line_y += line_h;
        start = end;
        while (start < line.len and line[start] == ' ') start += 1;
    }
    return line_y + line_h - y;
}

fn drawPlainWrappedLine(line: []const u8, x: f32, y: f32, max_w: f32, fg: renderer.Color) f32 {
    return drawPlainWrappedLineWith(line, x, y, max_w, body_font_size, body_line_h, fg, prose_text_style);
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
                    var remaining_w = max_w - (cursor_x - x);
                    if (cursor_x > x and remaining_w < 20.0) {
                        line_y += body_line_h;
                        cursor_x = x;
                        remaining_w = max_w;
                    }
                    const end = breakAtStyled(slice, start, remaining_w, body_font_size, prose_text_style);
                    const part = slice[start..end];
                    if (part.len > 0) {
                        handleTextHitAndDraw(part, cursor_x, line_y, body_line_h, body_font_size, style.fg, prose_text_style);
                        cursor_x += measureStyledText(part, body_font_size, prose_text_style);
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
                    var remaining_w = max_w - (cursor_x - x);
                    if (cursor_x > x and remaining_w < 20.0) {
                        line_y += body_line_h;
                        cursor_x = x;
                        remaining_w = max_w;
                    }
                    const end = breakAtStyled(slice, start, remaining_w, body_font_size, bold_text_style);
                    const part = slice[start..end];
                    if (part.len > 0) {
                        handleTextHitAndDraw(part, cursor_x, line_y, body_line_h, body_font_size, style.bold_fg, bold_text_style);
                        cursor_x += measureStyledText(part, body_font_size, bold_text_style);
                    }
                    if (end >= slice.len) break;
                    line_y += body_line_h;
                    cursor_x = x;
                    start = end;
                    while (start < slice.len and slice[start] == ' ') start += 1;
                }
            },
            .code => |slice| {
                const w = measureStyledText(slice, code_font_size, code_text_style) + inline_code_pad_x * 2;
                if (cursor_x > x and (cursor_x - x) + w > max_w) {
                    line_y += body_line_h;
                    cursor_x = x;
                }
                if (current_render_context == null or current_render_context.?.hit_test == null) {
                    renderer.Renderer.drawRoundedRect(cursor_x, line_y + 2, w, code_line_h - 4, 4, style.inline_code_bg);
                }
                handleTextHitAndDraw(slice, cursor_x + inline_code_pad_x, line_y + 1, body_line_h, code_font_size, style.inline_code_fg, code_text_style);
                cursor_x += w + inline_code_gap;
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
            line_y += paragraph_gap;
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
        const text_y = y + heading_gap_top;
        const drawn = drawPlainWrappedLineWith(body, x, text_y, max_w, heading_font_size, heading_line_h, style.bold_fg, bold_text_style);
        if (current_render_context == null or current_render_context.?.hit_test == null) {
            renderer.Renderer.drawRoundedRect(x, text_y + drawn + 1.0, @min(max_w, 44.0), 1.0, 0.5, .{ .r = style.quote_bar.r, .g = style.quote_bar.g, .b = style.quote_bar.b, .a = 0.42 });
        }
        return heading_gap_top + drawn + heading_gap_bottom;
    }
    if (bulletBody(line)) |body| {
        if (current_render_context == null or current_render_context.?.hit_test == null) {
            renderer.Renderer.drawRoundedRect(x + 4.0, y + 7.0, 4.0, 4.0, 2.0, style.list_marker);
        }
        return try drawInlineLine(allocator, body, x + list_indent, y, @max(20.0, max_w - list_indent), style) + list_item_gap;
    }
    if (numberedMarkerLen(line)) |marker_len| {
        const trimmed = trimLine(line);
        const marker = trimmed[0..@min(marker_len, trimmed.len)];
        const body = std.mem.trim(u8, trimmed[marker_len..], " ");
        renderer.Renderer.drawTextWithStyle(marker, x, y, body_font_size, style.list_marker, prose_text_style);
        return try drawInlineLine(allocator, body, x + list_indent, y, @max(20.0, max_w - list_indent), style) + list_item_gap;
    }
    if (quoteBody(line)) |body| {
        const h = markdownLineHeight(line, max_w);
        const quote_x = x + quote_indent;
        const quote_w = @max(20.0, max_w - quote_indent);
        if (current_render_context == null or current_render_context.?.hit_test == null) {
            renderer.Renderer.drawRoundedRect(quote_x, y, quote_w, h, 6, style.quote_bg);
            renderer.Renderer.drawRoundedRect(quote_x, y + 3, 3, @max(4.0, h - 6), 2, style.quote_bar);
        }
        _ = try drawInlineLine(allocator, body, quote_x + quote_pad_x, y + quote_pad_y, @max(20.0, quote_w - quote_pad_x * 2), style);
        return h;
    }
    return try drawParagraph(allocator, line, x, y, content_w, style);
}

fn getSelectionColor(wb: ?*@import("../../workbench.zig").Workbench) renderer.Color {
    if (wb) |w| {
        return @import("../render/theme.zig").color(w.theme.colors.selection);
    }
    return renderer.Color{ .r = 0.149, .g = 0.309, .b = 0.470, .a = 1.0 };
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
            handleTextHitAndDraw(part, draw_x, y, code_line_h, code_font_size, fg, code_text_style);
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
            if (current_render_context) |ctx| {
                if (ctx.isSelected(part.ptr, part.len)) |sel| {
                    const pre_w = measureStyledText(part[0..sel.start], code_font_size, code_text_style);
                    const sel_w = measureStyledText(part[sel.start..sel.end], code_font_size, code_text_style);
                    renderer.Renderer.drawRect(draw_x + pre_w, y, sel_w, code_line_h, getSelectionColor(ctx.wb));
                }
                if (ctx.hit_test) |hit| {
                    if (hit.y >= y and hit.y < y + code_line_h) {
                        if (hit.x <= draw_x) {
                            ctx.hit_result = @intFromPtr(part.ptr) - @intFromPtr(ctx.global_text.ptr);
                        } else {
                            var w: f32 = 0;
                            var found = false;
                            for (part, 0..) |_, j| {
                                w = measureStyledText(part[0..j], code_font_size, code_text_style);
                                if (draw_x + w >= hit.x) {
                                    ctx.hit_result = @intFromPtr(part.ptr) - @intFromPtr(ctx.global_text.ptr) + j;
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                ctx.hit_result = @intFromPtr(part.ptr) - @intFromPtr(ctx.global_text.ptr) + part.len;
                            }
                        }
                    }
                }
            }
            if (current_render_context == null or current_render_context.?.hit_test == null) {
                if (span_count > 0) {
                    var span_x = draw_x;
                    for (spans[0..span_count]) |span| {
                        const span_text = part[span.offset .. span.offset + span.length];
                        renderer.Renderer.drawTextWithStyle(span_text, span_x, y, code_font_size, .{ .r = span.r, .g = span.g, .b = span.b, .a = span.a }, code_text_style);
                        span_x += measureStyledText(span_text, code_font_size, code_text_style);
                    }
                } else {
                    renderer.Renderer.drawTextWithStyle(part, draw_x, y, code_font_size, fg, code_text_style);
                }
            }
        }
    }
    return measureStyledText(part, code_font_size, code_text_style) + code_pad * 2;
}

pub fn drawCodeBlock(code: []const u8, x: f32, y: f32, content_w: f32, style: Style, lang: []const u8, scroll_x: f32, out_max_w: *f32) f32 {
    const h = codeBlockHeight(code);
    const block_h = h - code_gap;
    renderer.Renderer.drawRoundedRect(x, y, content_w, block_h, 6, style.code_block_border);
    renderer.Renderer.drawRoundedRect(x + 1, y + 1, @max(1.0, content_w - 2), @max(1.0, block_h - 2), 5, style.code_block_bg);
    if (style.top_square) {
        renderer.Renderer.drawRect(x + 1, y + 1, @max(1.0, content_w - 2), 6, style.code_block_bg);
    }
    const common_indent = getCommonIndent(code);
    var line_y = y + code_pad;

    renderer.Renderer.pushClipRect(x + 1, y + 1, @max(1.0, content_w - 2), @max(1.0, block_h - 2));
    var lines = std.mem.splitScalar(u8, code, '\n');
    var max_w: f32 = 0;
    while (lines.next()) |line| {
        const display_line = if (line.len >= common_indent) line[common_indent..] else line;
        const line_w = drawCodeBlockLine(display_line, x + 1, line_y, @max(1.0, content_w - 2), scroll_x, style, lang);
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
    const state = @import("../core/state.zig");
    const active_sel = if (state.chat_selection) |sel| (if (sel.msg_hash == base_hash) sel else null) else null;
    const old_ctx = current_render_context;
    var new_ctx = RenderContext{
        .allocator = allocator,
        .global_text = text,
        .selection = if (active_sel) |s| .{ .start = s.start, .end = s.end } else null,
        .base_hash = base_hash,
        .wb = wb,
        .hit_test = if (old_ctx) |c| c.hit_test else null,
    };
    current_render_context = &new_ctx;
    defer {
        if (old_ctx) |c| {
            if (new_ctx.hit_result) |hr| c.hit_result = hr;
        }
        current_render_context = old_ctx;
    }

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
                            cursor_y += paragraph_gap;
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
                if (w.code_scroll_x.get(code_hash)) |scroll_state| {
                    scroll_x = scroll_state.scroll_x;
                }
            }

            var max_w: f32 = 0;
            const block_h = drawCodeBlock(code, x, cursor_y, content_w, style, lang, scroll_x, &max_w);

            if (wb) |w| {
                var scroll_state = w.code_scroll_x.get(code_hash) orelse @import("../../workbench.zig").Workbench.CodeScrollState{};
                const max_scroll = @max(0, max_w - content_w);
                scroll_state.max_scroll_x = max_scroll;
                w.code_scroll_x.put(code_hash, scroll_state) catch {};

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
                    cursor_y += paragraph_gap;
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

test "inline code height matches single-line rendering at narrow widths" {
    const text = "`this_is_a_long_inline_code_identifier_that_scrolls_horizontally`";
    try std.testing.expectEqual(body_line_h, contentHeight(text, 80));
}

test "inline code followed by text wraps instead of clipping tail" {
    const text = "- Use `zig build test-<package>` for targeted package tests.";
    try std.testing.expect(contentHeight(text, 230) >= body_line_h * 3);
}

test "markdown blank lines use compact paragraph gap" {
    const text =
        \\First paragraph
        \\
        \\Second paragraph
    ;
    try std.testing.expectEqual(body_line_h * 2 + paragraph_gap, contentHeight(text, 420));
}

pub fn hitTestContent(
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f32,
    y: f32,
    content_w: f32,
    hit_x: f32,
    hit_y: f32,
) ?usize {
    const old_ctx = current_render_context;
    defer current_render_context = old_ctx;

    var new_ctx = RenderContext{
        .allocator = allocator,
        .global_text = text,
        .selection = null,
        .base_hash = 0,
        .wb = null,
        .hit_test = .{ .x = hit_x, .y = hit_y },
        .hit_result = null,
    };
    current_render_context = &new_ctx;

    const dummy_style = Style{ .fg = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
    _ = drawContent(allocator, text, x, y, content_w, dummy_style, null, 0) catch 0.0;

    return new_ctx.hit_result;
}

fn handleTextHitAndDraw(
    part: []const u8,
    draw_x: f32,
    line_y: f32,
    line_h: f32,
    font_size: f32,
    fg: renderer.Color,
    text_style: renderer.TextStyle,
) void {
    if (current_render_context) |ctx| {
        if (ctx.isSelected(part.ptr, part.len)) |sel| {
            const pre_w = measureStyledText(part[0..sel.start], font_size, text_style);
            const sel_w = measureStyledText(part[sel.start..sel.end], font_size, text_style);
            renderer.Renderer.drawRect(draw_x + pre_w, line_y, sel_w, line_h, getSelectionColor(ctx.wb));
        }
        if (ctx.hit_test) |hit| {
            if (hit.y >= line_y and hit.y < line_y + line_h) {
                if (hit.x <= draw_x) {
                    ctx.hit_result = @intFromPtr(part.ptr) - @intFromPtr(ctx.global_text.ptr);
                } else {
                    var w: f32 = 0;
                    var found = false;
                    for (part, 0..) |_, i| {
                        w = measureStyledText(part[0..i], font_size, text_style);
                        if (draw_x + w >= hit.x) {
                            ctx.hit_result = @intFromPtr(part.ptr) - @intFromPtr(ctx.global_text.ptr) + i;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        ctx.hit_result = @intFromPtr(part.ptr) - @intFromPtr(ctx.global_text.ptr) + part.len;
                    }
                }
            }
        }
    }
    if (current_render_context == null or current_render_context.?.hit_test == null) {
        renderer.Renderer.drawTextWithStyle(part, draw_x, line_y, font_size, fg, text_style);
    }
}

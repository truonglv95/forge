const std = @import("std");
const renderer = @import("forge-renderer");
const chat_markdown = @import("chat_markdown.zig");
const chat_message_lines = @import("chat_message_lines.zig");

pub const font_size: f32 = chat_markdown.body_font_size;
pub const line_h: f32 = chat_markdown.body_line_h;
pub const bubble_pad_x: f32 = 8.0;
pub const bubble_pad_y: f32 = 6.0;
pub const title_h: f32 = 16.0;
pub const bubble_gap: f32 = 10.0;

pub const BubbleStyle = struct {
    bg: renderer.Color,
    fg: renderer.Color,
    title_fg: renderer.Color = .{ .r = 0.72, .g = 0.78, .b = 0.88, .a = 0.9 },
};

pub fn textMaxWidth(content_w: f32) f32 {
    return content_w - bubble_pad_x * 2;
}

pub fn visualLineCount(text: []const u8, content_w: f32) usize {
    const h = chat_markdown.contentHeight(text, textMaxWidth(content_w));
    return @max(1, @as(usize, @intFromFloat(std.math.ceil(h / line_h))));
}

pub fn bubbleHeight(text: []const u8, content_w: f32, with_title: bool) f32 {
    const body_h = chat_markdown.contentHeight(text, textMaxWidth(content_w));
    const title_extra = if (with_title) title_h else 0.0;
    return title_extra + body_h + bubble_pad_y * 2;
}

pub fn markdownStyle(style: BubbleStyle) chat_markdown.Style {
    return .{
        .fg = style.fg,
        .bold_fg = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = style.fg.a },
        .inline_code_fg = .{ .r = 0.85, .g = 0.92, .b = 1.0, .a = style.fg.a },
        .code_block_fg = .{ .r = 0.88, .g = 0.9, .b = 0.94, .a = style.fg.a },
    };
}

pub fn drawBubble(
    allocator: std.mem.Allocator,
    agent_x: f32,
    inner_x: f32,
    content_w: f32,
    y: f32,
    title: ?[]const u8,
    text: []const u8,
    style: BubbleStyle,
) f32 {
    return drawBubbleWithCache(allocator, agent_x, inner_x, content_w, y, title, text, style, null);
}

fn cacheIsDrawable(cache: *const chat_message_lines.Entry) bool {
    if (cache.markdown_runtime) return false;
    return cache.ranges.len > 0 or cache.blocks.len > 0;
}

fn drawCachedBody(
    text: []const u8,
    cache: *const chat_message_lines.Entry,
    x: f32,
    y: f32,
    draw_w: f32,
    style: chat_markdown.Style,
) void {
    _ = chat_message_lines.drawCached(text, cache, x, y, draw_w, style);
}

pub fn drawBubbleWithCache(
    allocator: std.mem.Allocator,
    agent_x: f32,
    inner_x: f32,
    content_w: f32,
    y: f32,
    title: ?[]const u8,
    text: []const u8,
    style: BubbleStyle,
    line_cache: ?*const chat_message_lines.Entry,
) f32 {
    if (text.len == 0 and (title == null or title.?.len == 0)) return 0;
    const with_title = title != null and title.?.len > 0;
    const text_w = textMaxWidth(content_w);
    const body_h = if (line_cache) |cache| cache.height else chat_markdown.contentHeight(text, text_w);
    const height = body_h + bubble_pad_y * 2 + (if (with_title) title_h else 0);
    const bubble_x = agent_x + 10;
    renderer.Renderer.drawRoundedRect(bubble_x, y - 4, content_w, height, 8.0, style.bg);
    renderer.Renderer.pushClipRect(bubble_x, y - 4, content_w, height);
    defer renderer.Renderer.popClipRect();

    var text_y = y + bubble_pad_y;
    if (with_title) {
        var title_buf: [64:0]u8 = undefined;
        const title_text = title.?;
        const n = @min(title_text.len, title_buf.len - 1);
        @memcpy(title_buf[0..n], title_text[0..n]);
        title_buf[n] = 0;
        renderer.Renderer.drawText(title_buf[0..n], inner_x + bubble_pad_x, text_y, 11.0, style.title_fg);
        text_y += title_h;
    }

    if (text.len > 0) {
        const md_style = markdownStyle(style);
        if (line_cache) |cache| {
            if (cacheIsDrawable(cache)) {
                drawCachedBody(text, cache, inner_x + bubble_pad_x, text_y, text_w, md_style);
            } else {
                drawBubbleBody(allocator, text, inner_x, text_y, text_w, style);
            }
        } else {
            drawBubbleBody(allocator, text, inner_x, text_y, text_w, style);
        }
    }
    return height + bubble_gap;
}

fn drawBubbleBody(
    allocator: std.mem.Allocator,
    text: []const u8,
    inner_x: f32,
    text_y: f32,
    text_w: f32,
    style: BubbleStyle,
) void {
    const use_markdown = std.mem.indexOf(u8, text, "```") != null or std.mem.indexOf(u8, text, "**") != null;
    if (use_markdown) {
        _ = chat_markdown.drawContent(
            allocator,
            text,
            inner_x + bubble_pad_x,
            text_y,
            text_w,
            markdownStyle(style),
        ) catch {
            renderer.Renderer.flushBatch();
            _ = chat_markdown.drawSimpleContent(
                text,
                inner_x + bubble_pad_x,
                text_y,
                text_w,
                style.fg,
            );
        };
    } else {
        renderer.Renderer.flushBatch();
        _ = chat_markdown.drawSimpleContent(
            text,
            inner_x + bubble_pad_x,
            text_y,
            text_w,
            style.fg,
        );
    }
}

pub fn plainMessageHeight(text: []const u8, content_w: f32) f32 {
    if (text.len == 0) return 0;
    return chat_markdown.contentHeight(text, content_w) + bubble_gap;
}

pub fn drawPlainMessage(
    allocator: std.mem.Allocator,
    inner_x: f32,
    content_w: f32,
    y: f32,
    text: []const u8,
    style: chat_markdown.Style,
) f32 {
    return drawPlainMessageWithCache(allocator, inner_x, content_w, y, text, style, null);
}

pub fn drawPlainMessageWithCache(
    allocator: std.mem.Allocator,
    inner_x: f32,
    content_w: f32,
    y: f32,
    text: []const u8,
    style: chat_markdown.Style,
    line_cache: ?*const chat_message_lines.Entry,
) f32 {
    if (text.len == 0) return 0;
    const body_h = if (line_cache) |cache| cache.height else chat_markdown.contentHeight(text, content_w);

    if (line_cache) |cache| {
        if (cacheIsDrawable(cache)) {
            renderer.Renderer.pushClipRect(inner_x, y, content_w, body_h);
            defer renderer.Renderer.popClipRect();
            drawCachedBody(text, cache, inner_x, y, content_w, style);
            return body_h + bubble_gap;
        }
    }

    renderer.Renderer.pushClipRect(inner_x, y, content_w, body_h);
    defer renderer.Renderer.popClipRect();
    const use_markdown = std.mem.indexOf(u8, text, "```") != null or std.mem.indexOf(u8, text, "**") != null;
    _ = if (use_markdown)
        chat_markdown.drawContent(allocator, text, inner_x, y, content_w, style) catch
            chat_markdown.drawSimpleContent(text, inner_x, y, content_w, style.fg)
    else
        chat_markdown.drawSimpleContent(text, inner_x, y, content_w, style.fg);
    return body_h + bubble_gap;
}

pub const agent_text_style = chat_markdown.Style{
    .fg = .{ .r = 0.86, .g = 0.88, .b = 0.92, .a = 1.0 },
    .bold_fg = .{ .r = 0.95, .g = 0.96, .b = 0.98, .a = 1.0 },
    .inline_code_fg = .{ .r = 0.82, .g = 0.9, .b = 0.98, .a = 1.0 },
    .code_block_fg = .{ .r = 0.88, .g = 0.9, .b = 0.94, .a = 1.0 },
};

pub const thinking_text_style = chat_markdown.Style{
    .fg = .{ .r = 0.58, .g = 0.62, .b = 0.7, .a = 1.0 },
    .bold_fg = .{ .r = 0.68, .g = 0.72, .b = 0.8, .a = 1.0 },
    .inline_code_fg = .{ .r = 0.65, .g = 0.72, .b = 0.82, .a = 1.0 },
    .code_block_fg = .{ .r = 0.7, .g = 0.74, .b = 0.8, .a = 1.0 },
    .code_block_bg = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1.0 },
};

pub fn drawThinkingLine(inner_x: f32, y: f32, text: []const u8) f32 {
    if (text.len == 0) return 0;
    var label_buf: [320:0]u8 = undefined;
    const clipped = if (text.len > 280) text[0..280] else text;
    const line = std.fmt.bufPrint(&label_buf, "Thinking: {s}", .{clipped}) catch clipped;
    label_buf[@min(line.len, label_buf.len - 1)] = 0;
    renderer.Renderer.drawText(line[0..line.len], inner_x, y, 11.0, thinking_text_style.fg);
    return line_h + bubble_gap;
}

pub fn drawStatusLine(inner_x: f32, y: f32, text: []const u8) f32 {
    if (text.len == 0) return 0;
    var buf: [256:0]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    renderer.Renderer.drawText(buf[0..n], inner_x, y, 11.0, thinking_text_style.fg);
    return line_h + bubble_gap;
}

pub fn historyMessageHeight(is_user: bool, text: []const u8, content_w: f32) f32 {
    if (text.len == 0) return 0;
    if (is_user) return bubbleHeight(text, content_w, false) + bubble_gap;
    return plainMessageHeight(text, content_w);
}

pub fn estimateLiveLines(thinking: []const u8, stream: []const u8, worker_running: bool, content_w: f32) usize {
    var total: usize = 0;
    if (thinking.len > 0) {
        total += 2;
    } else if (stream.len == 0 and worker_running) {
        total += 1;
    }
    if (stream.len > 0) {
        total += visualLineCount(stream, content_w) + 1;
    }
    return total;
}

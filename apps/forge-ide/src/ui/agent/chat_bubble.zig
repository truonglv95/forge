const std = @import("std");
const renderer = @import("forge-renderer");
const chat_markdown = @import("chat_markdown.zig");
const chat_message_lines = @import("chat_message_lines.zig");
const metrics = @import("metrics.zig");
const tokens = @import("../tokens.zig");

pub fn fontSize() f32 {
    return chat_markdown.body_font_size;
}

pub fn lineH() f32 {
    return chat_markdown.body_line_h;
}
pub const bubble_pad_x: f32 = metrics.bubble.pad_x;
pub const bubble_pad_y: f32 = metrics.bubble.pad_y;
pub const title_h: f32 = metrics.bubble.title_h;
pub const bubble_gap: f32 = metrics.bubble.gap;
pub const agent_icon_size: f32 = metrics.bubble.agent_icon_size;
pub const agent_header_h: f32 = metrics.bubble.agent_header_h;

pub fn agentTextWidth(content_w: f32) f32 {
    return @max(40.0, content_w);
}

pub const BubbleStyle = struct {
    bg: renderer.Color,
    fg: renderer.Color,
    title_fg: renderer.Color = tokens.color.text_secondary,
};

pub fn textMaxWidth(content_w: f32) f32 {
    return userBubbleWidth(content_w) - bubble_pad_x * 2;
}

fn userBubbleWidth(content_w: f32) f32 {
    return @min(content_w, @max(180.0, content_w * 0.82));
}

pub fn visualLineCount(text: []const u8, content_w: f32) usize {
    const h = chat_markdown.contentHeight(text, textMaxWidth(content_w));
    return @max(1, @as(usize, @intFromFloat(std.math.ceil(h / lineH()))));
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
    wb: ?*@import("../../workbench.zig").Workbench,
    base_hash: u64,
) f32 {
    return drawBubbleWithCache(allocator, agent_x, inner_x, content_w, y, title, text, style, null, wb, base_hash);
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
    wb: ?*@import("../../workbench.zig").Workbench,
    base_hash: u64,
) f32 {
    if (text.len == 0 and (title == null or title.?.len == 0)) return 0;
    const with_title = title != null and title.?.len > 0;
    const bubble_w = userBubbleWidth(content_w);
    const text_w = textMaxWidth(content_w);
    const body_h = if (line_cache) |cache| cache.height else chat_markdown.contentHeight(text, text_w);
    const height = body_h + bubble_pad_y * 2 + (if (with_title) title_h else 0);
    _ = agent_x;
    const bubble_x = inner_x + content_w - bubble_w;
    const text_x = bubble_x + bubble_pad_x;
    renderer.Renderer.drawRoundedRect(bubble_x, y, bubble_w, height, tokens.radius.lg, style.bg);
    renderer.Renderer.pushClipRect(bubble_x, y, bubble_w, height);
    defer renderer.Renderer.popClipRect();

    var text_y = y + bubble_pad_y;
    if (with_title) {
        var title_buf: [64:0]u8 = undefined;
        const title_text = title.?;
        const n = @min(title_text.len, title_buf.len - 1);
        @memcpy(title_buf[0..n], title_text[0..n]);
        title_buf[n] = 0;
        renderer.Renderer.drawTextWithStyle(title_buf[0..n], text_x, text_y, 11.0, style.title_fg, metrics.typography.strong_style);
        text_y += title_h;
    }

    if (text.len > 0) {
        const md_style = markdownStyle(style);
        if (line_cache) |cache| {
            if (cacheIsDrawable(cache)) {
                drawCachedBody(text, cache, text_x, text_y, text_w, md_style);
            } else {
                drawBubbleBody(allocator, text, bubble_x, text_y, text_w, style, wb, base_hash);
            }
        } else {
            drawBubbleBody(allocator, text, bubble_x, text_y, text_w, style, wb, base_hash);
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
    wb: ?*@import("../../workbench.zig").Workbench,
    base_hash: u64,
) void {
    const use_markdown = chat_markdown.usesMarkdown(text);
    if (use_markdown) {
        _ = chat_markdown.drawContent(
            allocator,
            text,
            inner_x + bubble_pad_x,
            text_y,
            text_w,
            markdownStyle(style),
            wb,
            base_hash,
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

pub fn agentMessageHeight(text: []const u8, content_w: f32) f32 {
    if (text.len == 0) return 0;
    const text_h = chat_markdown.contentHeight(text, agentTextWidth(content_w));
    return agent_header_h + text_h + bubble_gap;
}

pub fn drawPlainMessage(
    allocator: std.mem.Allocator,
    inner_x: f32,
    content_w: f32,
    y: f32,
    text: []const u8,
    style: chat_markdown.Style,
    wb: ?*@import("../../workbench.zig").Workbench,
    base_hash: u64,
) f32 {
    return drawPlainMessageWithCache(allocator, inner_x, content_w, y, text, style, null, wb, base_hash);
}

pub fn drawPlainMessageWithCache(
    allocator: std.mem.Allocator,
    inner_x: f32,
    content_w: f32,
    y: f32,
    text: []const u8,
    style: chat_markdown.Style,
    line_cache: ?*const chat_message_lines.Entry,
    wb: ?*@import("../../workbench.zig").Workbench,
    base_hash: u64,
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
    const use_markdown = chat_markdown.usesMarkdown(text);
    _ = if (use_markdown)
        chat_markdown.drawContent(allocator, text, inner_x, y, content_w, style, wb, base_hash) catch
            chat_markdown.drawSimpleContent(text, inner_x, y, content_w, style.fg)
    else
        chat_markdown.drawSimpleContent(text, inner_x, y, content_w, style.fg);
    return body_h + bubble_gap;
}

pub fn drawAgentMessageWithCache(
    allocator: std.mem.Allocator,
    agent_x: f32,
    inner_x: f32,
    content_w: f32,
    y: f32,
    text: []const u8,
    style: chat_markdown.Style,
    line_cache: ?*const chat_message_lines.Entry,
    wb: ?*@import("../../workbench.zig").Workbench,
    base_hash: u64,
) f32 {
    if (text.len == 0) return 0;

    const icon_x = @max(agent_x + tokens.space.sm, inner_x);
    renderer.Renderer.drawRoundedRect(icon_x, y, agent_icon_size, agent_icon_size, 4, .{ .r = 0.02, .g = 0.43, .b = 1.0, .a = 1.0 });
    renderer.Renderer.drawSvg(renderer.icons.gear, icon_x + 3, y + 3, 14, 14, .{ .r = 0.92, .g = 0.96, .b = 1.0, .a = 1.0 });

    const text_x = inner_x;
    const text_y = y + agent_header_h;
    const text_w = agentTextWidth(content_w);

    const body_h = if (line_cache) |cache| cache.height else chat_markdown.contentHeight(text, text_w);

    if (line_cache) |cache| {
        if (cacheIsDrawable(cache)) {
            renderer.Renderer.pushClipRect(text_x, text_y, text_w, body_h + 8.0);
            drawCachedBody(text, cache, text_x, text_y, text_w, style);
            renderer.Renderer.popClipRect();
            return agent_header_h + body_h + bubble_gap + 8.0;
        }
    }

    renderer.Renderer.pushClipRect(text_x, text_y, text_w, body_h + 8.0);
    const use_markdown = chat_markdown.usesMarkdown(text);
    _ = if (use_markdown)
        chat_markdown.drawContent(allocator, text, text_x, text_y, text_w, style, wb, base_hash) catch
            chat_markdown.drawSimpleContent(text, text_x, text_y, text_w, style.fg)
    else
        chat_markdown.drawSimpleContent(text, text_x, text_y, text_w, style.fg);
    renderer.Renderer.popClipRect();
    return agent_header_h + body_h + bubble_gap + 8.0;
}

pub fn hitTestAgentOpen(inner_x: f32, content_w: f32, y: f32, event_x: f32, event_y: f32) bool {
    _ = inner_x;
    _ = content_w;
    _ = y;
    _ = event_x;
    _ = event_y;
    return false;
}

pub fn hitTestAgentCopy(inner_x: f32, content_w: f32, y: f32, event_x: f32, event_y: f32) bool {
    _ = inner_x;
    _ = content_w;
    _ = y;
    _ = event_x;
    _ = event_y;
    return false;
}

pub fn hitTestMessageContent(
    allocator: std.mem.Allocator,
    text: []const u8,
    inner_x: f32,
    content_w: f32,
    y: f32,
    event_x: f32,
    event_y: f32,
) ?usize {
    return chat_markdown.hitTestContent(allocator, text, inner_x, y + agent_header_h, agentTextWidth(content_w), event_x, event_y);
}

pub const agent_text_style = chat_markdown.Style{
    .fg = .{ .r = 0.82, .g = 0.84, .b = 0.88, .a = 1.0 },
    .bold_fg = .{ .r = 0.91, .g = 0.92, .b = 0.95, .a = 1.0 },
    .inline_code_fg = .{ .r = 0.78, .g = 0.86, .b = 0.94, .a = 1.0 },
    .inline_code_bg = .{ .r = 0.18, .g = 0.2, .b = 0.25, .a = 0.9 },
    .code_block_fg = .{ .r = 0.84, .g = 0.86, .b = 0.9, .a = 1.0 },
    .code_block_bg = .{ .r = 0.075, .g = 0.085, .b = 0.105, .a = 1.0 },
    .code_block_border = .{ .r = 0.15, .g = 0.17, .b = 0.21, .a = 1.0 },
    .quote_bg = .{ .r = 0.1, .g = 0.115, .b = 0.14, .a = 0.62 },
    .quote_bar = .{ .r = 0.34, .g = 0.56, .b = 0.88, .a = 0.72 },
    .list_marker = .{ .r = 0.34, .g = 0.72, .b = 0.76, .a = 0.82 },
};

pub const thinking_text_style = chat_markdown.Style{
    .fg = .{ .r = 0.58, .g = 0.62, .b = 0.7, .a = 1.0 },
    .bold_fg = .{ .r = 0.68, .g = 0.72, .b = 0.8, .a = 1.0 },
    .inline_code_fg = .{ .r = 0.65, .g = 0.72, .b = 0.82, .a = 1.0 },
    .code_block_fg = .{ .r = 0.7, .g = 0.74, .b = 0.8, .a = 1.0 },
    .code_block_bg = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1.0 },
};

pub fn drawThinkingLine(inner_x: f32, y: f32, text: []const u8, anim_time: f32) f32 {
    _ = text;
    const dot_count: usize = @as(usize, @intFromFloat(@mod(anim_time * 2.8, 3.0))) + 1;
    var label_buf: [16]u8 = undefined;
    @memcpy(label_buf[0.."Thinking".len], "Thinking");
    var label_len: usize = "Thinking".len;
    var i: usize = 0;
    while (i < dot_count) : (i += 1) {
        label_buf[label_len] = '.';
        label_len += 1;
    }

    const pill_w: f32 = 142;
    const pill_h: f32 = 32;
    renderer.Renderer.drawRoundedRect(inner_x, y, pill_w, pill_h, 6, .{ .r = 0.03, .g = 0.24, .b = 0.43, .a = 1.0 });
    renderer.Renderer.drawRoundedRect(inner_x + 1, y + 1, pill_w - 2, pill_h - 2, 5, .{ .r = 0.07, .g = 0.12, .b = 0.18, .a = 1.0 });
    renderer.Renderer.drawSvg(renderer.icons.sparkle, inner_x + 14, y + 8, 14, 14, .{ .r = 0.18, .g = 0.58, .b = 0.95, .a = 1.0 });
    renderer.Renderer.drawTextWithStyle(label_buf[0..label_len], inner_x + 34, y + 8, 12.0, .{ .r = 0.24, .g = 0.62, .b = 0.95, .a = 1.0 }, metrics.typography.strong_style);
    return thinkingLineHeight();
}

pub fn thinkingLineHeight() f32 {
    return 32.0 + bubble_gap;
}

pub fn drawStatusLine(inner_x: f32, y: f32, text: []const u8) f32 {
    if (text.len == 0) return 0;
    var buf: [256:0]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    renderer.Renderer.drawTextWithStyle(buf[0..n], inner_x, y, 11.0, thinking_text_style.fg, metrics.typography.prose_style);
    return lineH() + bubble_gap;
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

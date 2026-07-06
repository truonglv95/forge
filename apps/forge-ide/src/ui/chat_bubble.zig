const std = @import("std");
const renderer = @import("forge-renderer");
const chat_markdown = @import("chat_markdown.zig");

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
    if (text.len == 0 and (title == null or title.?.len == 0)) return 0;
    const with_title = title != null and title.?.len > 0;
    const height = bubbleHeight(text, content_w, with_title);
    const bubble_x = agent_x + 10;
    renderer.Renderer.drawRoundedRect(bubble_x, y - 4, content_w, height, 8.0, style.bg);

    var text_y = y + bubble_pad_y;
    if (with_title) {
        var title_buf: [64:0]u8 = undefined;
        const title_text = title.?;
        const n = @min(title_text.len, title_buf.len - 1);
        @memcpy(title_buf[0..n], title_text[0..n]);
        title_buf[n] = 0;
        renderer.Renderer.drawText(@ptrCast(&title_buf), inner_x + bubble_pad_x, text_y, 11.0, style.title_fg);
        text_y += title_h;
    }

    if (text.len > 0) {
        _ = chat_markdown.drawContent(
            allocator,
            text,
            inner_x + bubble_pad_x,
            text_y,
            textMaxWidth(content_w),
            markdownStyle(style),
        ) catch {};
    }
    return height + bubble_gap;
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
    if (text.len == 0) return 0;
    const drawn = chat_markdown.drawContent(allocator, text, inner_x, y, content_w, style) catch 0;
    return drawn + bubble_gap;
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
    renderer.Renderer.drawText(@ptrCast(&label_buf), inner_x, y, 11.0, thinking_text_style.fg);
    return line_h + bubble_gap;
}

pub fn drawStatusLine(inner_x: f32, y: f32, text: []const u8) f32 {
    if (text.len == 0) return 0;
    var buf: [256:0]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    renderer.Renderer.drawText(@ptrCast(&buf), inner_x, y, 11.0, thinking_text_style.fg);
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

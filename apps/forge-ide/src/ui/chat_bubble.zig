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

pub fn estimateLiveLines(thinking: []const u8, stream: []const u8, worker_running: bool, content_w: f32) usize {
    var total: usize = 0;
    const inner_w = textMaxWidth(content_w);
    if (thinking.len > 0) {
        total += visualLineCount(thinking, content_w) + 2;
    } else if (stream.len == 0 and worker_running) {
        total += 2;
    }
    if (stream.len > 0) {
        total += @max(1, @as(usize, @intFromFloat(std.math.ceil(
            chat_markdown.contentHeight(stream, inner_w) / line_h,
        )))) + 2;
    }
    return total;
}

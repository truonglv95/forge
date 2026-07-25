//! Notification rendering — draws toast notifications in the bottom-right
//! corner of the window. Each notification is a card with a colored
//! accent strip (level), a title, and a message. Auto-fades after the
//! configured duration.

const std = @import("std");
const renderer = @import("forge-renderer");
const theme_mod = @import("theme.zig");
const notifications_mod = @import("../../workbench/notifications.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub const card_w: f32 = 320;
pub const card_h: f32 = 64;
pub const card_gap: f32 = 8;
pub const card_margin: f32 = 16;

pub fn drawNotifications(wb: *Workbench, window_w: f32, window_h: f32) void {
    if (wb.notifications.items.items.len == 0) return;

    const theme = &wb.theme;
    const font_size = theme.ui_font_size;
    const title_size = 11.0;

    // Stack from bottom-right, going up.
    var y = window_h - card_margin - card_h;
    for (wb.notifications.items.items) |notif| {
        // Slide-in animation: new notifications slide in from the right.
        // Use remaining time as proxy for age (high remaining = just shown).
        // Assuming default duration ~5s, slide-in happens in first 0.3s.
        const slide_progress = @min(1.0, @max(0.0, (5.0 - notif.remaining) / 0.3));
        const slide_offset = (1.0 - slide_progress) * (card_w + card_margin);
        const x = window_w - card_margin - card_w + slide_offset;

        // Card shadow
        renderer.Renderer.drawRoundedRect(x + 2, y + 3, card_w, card_h, 8, .{ .r = 0, .g = 0, .b = 0, .a = 0.3 });

        // Card background — rounded
        renderer.Renderer.drawRoundedRect(x, y, card_w, card_h, 8, theme_mod.color(theme.colors.panel_bg));

        // Accent strip on the left (colored by level).
        const accent_color: renderer.Color = switch (notif.level) {
            .info => .{ .r = 0.27, .g = 0.53, .b = 1.0, .a = 1.0 },
            .success => .{ .r = 0.20, .g = 0.53, .b = 0.27, .a = 1.0 },
            .warning => .{ .r = 0.93, .g = 0.73, .b = 0.20, .a = 1.0 },
            .err => .{ .r = 0.73, .g = 0.27, .b = 0.27, .a = 1.0 },
        };
        renderer.Renderer.drawRoundedRect(x, y, 4, card_h, 2, accent_color);

        // Border.
        renderer.Renderer.drawRect(x, y, card_w, 1, theme_mod.color(theme.colors.border));
        renderer.Renderer.drawRect(x, y + card_h - 1, card_w, 1, theme_mod.color(theme.colors.border));

        // Title (level label) in accent color.
        renderer.Renderer.drawText(notif.level.label(), x + 14, y + 8, title_size, accent_color);

        // Message text.
        const message_color = theme_mod.color(theme.colors.text_primary);
        var msg_y = y + 24;
        const msg_x = x + 14;
        // Simple word-wrap.
        var words = std.mem.splitScalar(u8, notif.message, ' ');
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(wb.allocator);
        const max_line_w = card_w - 28;
        while (words.next()) |word| {
            if (line.items.len > 0) {
                const test_w = estimateWidth(line.items, font_size) + estimateWidth(" ", font_size) + estimateWidth(word, font_size);
                if (test_w > max_line_w) {
                    renderer.Renderer.drawText(line.items, msg_x, msg_y, font_size, message_color);
                    msg_y += font_size + 2;
                    line.clearRetainingCapacity();
                } else {
                    line.append(wb.allocator, ' ') catch break;
                }
            }
            line.appendSlice(wb.allocator, word) catch break;
        }
        if (line.items.len > 0 and msg_y < y + card_h) {
            renderer.Renderer.drawText(line.items, msg_x, msg_y, font_size, message_color);
        }

        y -= (card_h + card_gap);
    }
}

fn estimateWidth(text: []const u8, font_size: f32) f32 {
    return @as(f32, @floatFromInt(text.len)) * font_size * 0.55;
}

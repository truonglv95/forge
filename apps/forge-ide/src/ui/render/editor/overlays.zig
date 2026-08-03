const std = @import("std");
const renderer = @import("forge-renderer");
const editor_scroll = @import("../../editor/editor_scroll.zig");
const tabs_ui = @import("../../editor/tabs.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const Buffer = @import("forge-editor").Buffer;
const theme_mod = @import("../theme.zig");

pub fn drawHoverTooltip(wb: *Workbench, editor_x: f32, editor_w: f32) void {
    const text = wb.lsp.hover.text orelse return;
    if (text.len == 0) return;

    const theme = &wb.theme;
    const font_size: f32 = 12.0;
    const line_h: f32 = 16.0;
    const padding: f32 = 10.0;
    const max_w: f32 = @min(480, editor_w - 24);
    const max_lines: usize = 15;
    const max_chars_per_line: usize = 72;

    var lines: [max_lines][]const u8 = undefined;
    var line_is_code: [max_lines]bool = undefined;
    var line_count: usize = 0;
    var in_code_block = false;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len and line_count < max_lines) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            var slice = text[line_start..i];
            if (std.mem.startsWith(u8, slice, "```")) {
                in_code_block = !in_code_block;
                line_start = i + 1;
                continue;
            }
            slice = std.mem.trim(u8, slice, " \t\r");
            if (slice.len == 0) {
                line_start = i + 1;
                continue;
            }
            const is_code = in_code_block or (slice.len >= 2 and slice[0] == '`' and slice[slice.len - 1] == '`');
            var chunk_start: usize = 0;
            while (chunk_start < slice.len and line_count < max_lines) {
                const chunk_end = @min(chunk_start + max_chars_per_line, slice.len);
                lines[line_count] = slice[chunk_start..chunk_end];
                line_is_code[line_count] = is_code;
                line_count += 1;
                if (chunk_end >= slice.len) break;
                chunk_start = chunk_end;
            }
            line_start = i + 1;
        }
    }
    if (line_count == 0) return;

    var box_w: f32 = 0;
    for (lines[0..line_count]) |line| {
        box_w = @max(box_w, renderer.Renderer.measureText(line, font_size));
    }
    box_w = @min(max_w, box_w + padding * 2);
    const box_h = @as(f32, @floatFromInt(line_count)) * line_h + padding * 2;
    var box_x = wb.lsp.hover.anchor_x + 12;
    var box_y = wb.lsp.hover.anchor_y - box_h - 8;
    if (box_x + box_w > editor_x + editor_w - 8) box_x = editor_x + editor_w - box_w - 8;
    if (box_x < editor_x + 8) box_x = editor_x + 8;
    if (box_y < 70) box_y = wb.lsp.hover.anchor_y + 18;

    // Shadow effect (offset dark rect behind)
    renderer.Renderer.drawRoundedRect(box_x + 2, box_y + 3, box_w, box_h, 8, .{ .r = 0, .g = 0, .b = 0, .a = 0.3 });

    // Background — use theme panel bg with slight transparency
    const bg_color = theme_mod.color(theme.colors.panel_bg);
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 8, .{
        .r = bg_color.r,
        .g = bg_color.g,
        .b = bg_color.b,
        .a = 0.98,
    });

    // Border — subtle theme border
    const border_color = theme_mod.color(theme.colors.border);
    renderer.Renderer.drawRect(box_x, box_y, box_w, 1, border_color);
    renderer.Renderer.drawRect(box_x, box_y + box_h - 1, box_w, 1, border_color);
    renderer.Renderer.drawRect(box_x, box_y, 1, box_h, border_color);
    renderer.Renderer.drawRect(box_x + box_w - 1, box_y, 1, box_h, border_color);

    // Accent bar on left
    const accent = theme_mod.color(theme.colors.accent);
    renderer.Renderer.drawRoundedRect(box_x, box_y, 3, box_h, 1.5, accent);

    var y = box_y + padding;
    for (lines[0..line_count], line_is_code[0..line_count]) |line, is_code| {
        var buf: [256:0]u8 = undefined;
        var clipped = line;
        if (is_code and clipped.len >= 2 and clipped[0] == '`' and clipped[clipped.len - 1] == '`') {
            clipped = clipped[1 .. clipped.len - 1];
        }
        const copy_len = @min(clipped.len, 255);
        @memcpy(buf[0..copy_len], clipped[0..copy_len]);
        buf[copy_len] = 0;
        // Code: accent color, Regular text: primary text color
        const color = if (is_code)
            theme_mod.color(theme.colors.type)
        else
            theme_mod.color(theme.colors.text_primary);
        renderer.Renderer.drawText(@ptrCast(&buf), box_x + padding + 4, y, font_size, color);
        y += line_h;
    }
}

pub fn drawFindHighlights(
    wb: *Workbench,
    buf: *Buffer,
    row: usize,
    text_x: f32,
    line_y: f32,
    line_h: f32,
    font_size: f32,
) void {
    if (!wb.find_bar.open or wb.find_bar.matches.len == 0) return;
    const line = buf.lineAt(row);
    var left: usize = 0;
    var right: usize = wb.find_bar.matches.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (wb.find_bar.matches[mid].row < row) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    for (wb.find_bar.matches[left..], left..) |match, index| {
        if (match.row != row) break;
        const start_x = text_x + editor_scroll.cursorX(line, match.col, font_size);
        const end_x = text_x + editor_scroll.cursorX(line, @min(match.col + match.len, line.len), font_size);
        const is_active = index == wb.find_bar.match_index;
        const color = if (is_active)
            renderer.Color{ .r = 0.95, .g = 0.75, .b = 0.2, .a = 0.45 }
        else
            renderer.Color{ .r = 0.55, .g = 0.65, .b = 0.85, .a = 0.35 };
        renderer.Renderer.drawRect(start_x, line_y, @max(4, end_x - start_x), line_h - 2, color);
    }
}

pub fn drawEditorOverlay(wb: *Workbench, editor_x: f32, editor_w: f32) void {
    const bar_h: f32 = if (wb.find_bar.open and wb.find_bar.replace_mode) 56 else 32;
    const bar_y: f32 = tabs_ui.tab_bar_top + tabs_ui.tab_bar_height;
    // Subtle drop shadow above the overlay (top 2px gradient) so it visually
    // detaches from the editor instead of looking like a flat sticker.
    renderer.Renderer.drawRect(editor_x, bar_y - 2, editor_w, 2, .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.25 });
    renderer.Renderer.drawRect(editor_x, bar_y, editor_w, bar_h, .{ .r = 0.12, .g = 0.14, .b = 0.18, .a = 0.98 });
    // Bottom border to separate from editor content
    renderer.Renderer.drawRect(editor_x, bar_y + bar_h - 1, editor_w, 1, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });

    if (wb.find_bar.open) {
        var query_buf: [256:0]u8 = undefined;
        const query = wb.find_bar.query.lineAt(0);
        const clipped_q = if (query.len > 255) query[0..255] else query;
        @memcpy(query_buf[0..clipped_q.len], clipped_q);
        query_buf[clipped_q.len] = 0;

        // Find input box with cursor caret
        const input_x = editor_x + 56;
        const input_w: f32 = 200;
        renderer.Renderer.drawRoundedRect(input_x, bar_y + 5, input_w, 22, 4, .{ .r = 0.08, .g = 0.09, .b = 0.12, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(input_x, bar_y + 5, input_w, 22, 4, .{ .r = 0.25, .g = 0.28, .b = 0.34, .a = 0.7 });
        renderer.Renderer.drawText("Find:", editor_x + 12, bar_y + 8, 11.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&query_buf), input_x + 8, bar_y + 8, 11.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });

        // Blinking caret (when overlay is focused)
        const blink_phase = @mod(@import("../../core/state.zig").time, 1.06);
        if (blink_phase < 0.53) {
            const caret_x = input_x + 8 + @import("../../editor/editor_scroll.zig").cursorX(query, 0, 11.0);
            renderer.Renderer.drawRect(caret_x, bar_y + 8, 1.5, 16, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        }

        if (wb.find_bar.replace_mode) {
            var replace_buf: [256:0]u8 = undefined;
            const replacement = wb.find_bar.replace.lineAt(0);
            const clipped_r = if (replacement.len > 255) replacement[0..255] else replacement;
            @memcpy(replace_buf[0..clipped_r.len], clipped_r);
            replace_buf[clipped_r.len] = 0;

            const replace_x = editor_x + 56;
            const replace_w: f32 = 200;
            renderer.Renderer.drawRoundedRect(replace_x, bar_y + 28, replace_w, 22, 4, .{ .r = 0.08, .g = 0.09, .b = 0.12, .a = 1.0 });
            renderer.Renderer.drawRoundedRect(replace_x, bar_y + 28, replace_w, 22, 4, .{ .r = 0.25, .g = 0.28, .b = 0.34, .a = 0.7 });
            renderer.Renderer.drawText("With:", editor_x + 12, bar_y + 33, 11.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
            renderer.Renderer.drawText(@ptrCast(&replace_buf), replace_x + 8, bar_y + 33, 11.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
        }

        // Match counter on the right side — color codes results:
        // - green: matches found, currently positioned on one
        // - red:   no matches at all
        var count_buf: [64:0]u8 = undefined;
        const count_msg = if (wb.find_bar.matches.len > 0)
            std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ wb.find_bar.match_index + 1, wb.find_bar.matches.len }) catch ""
        else
            std.fmt.bufPrint(&count_buf, "0/0", .{}) catch "0/0";
        count_buf[count_msg.len] = 0;
        const count_color = if (wb.find_bar.matches.len > 0)
            renderer.Color{ .r = 0.55, .g = 0.85, .b = 0.55, .a = 1.0 }
        else
            renderer.Color{ .r = 0.95, .g = 0.55, .b = 0.55, .a = 1.0 };
        renderer.Renderer.drawText(@ptrCast(&count_buf), editor_x + editor_w - 80, bar_y + 8, 11.0, count_color);

        // Show small hint text for available actions
        var hint_buf: [128:0]u8 = undefined;
        const hint = if (wb.find_bar.replace_mode)
            "Enter=Replace  Cmd+Enter=All  Esc=Close"
        else
            "Enter=Next  Shift+Enter=Prev  Cmd+1=Replace  Esc=Close";
        const hint_clipped = if (hint.len > 127) hint[0..127] else hint;
        @memcpy(hint_buf[0..hint_clipped.len], hint_clipped);
        hint_buf[hint_clipped.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&hint_buf), editor_x + editor_w - 360, bar_y + (if (wb.find_bar.replace_mode) @as(f32, 33) else 8), 10.0, .{ .r = 0.5, .g = 0.5, .b = 0.55, .a = 1.0 });
    }

    if (wb.goto_bar.open) {
        var line_buf: [64:0]u8 = undefined;
        const input = wb.goto_bar.input.lineAt(0);
        const clipped = if (input.len > 63) input[0..63] else input;
        @memcpy(line_buf[0..clipped.len], clipped);
        line_buf[clipped.len] = 0;
        renderer.Renderer.drawText("Go to line:", editor_x + 12, bar_y + 8, 11.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&line_buf), editor_x + 96, bar_y + 8, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
    }

    if (wb.rename_bar.open) {
        var name_buf: [128:0]u8 = undefined;
        const input = wb.rename_bar.input.lineAt(0);
        const clipped = if (input.len > 127) input[0..127] else input;
        @memcpy(name_buf[0..clipped.len], clipped);
        name_buf[clipped.len] = 0;
        renderer.Renderer.drawText("Rename:", editor_x + 12, bar_y + 8, 11.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&name_buf), editor_x + 80, bar_y + 8, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
    }
}

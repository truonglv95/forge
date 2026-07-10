const std = @import("std");
const renderer = @import("forge-renderer");
const agent_session = @import("../../agent/session.zig");
const chat_markdown = @import("chat_markdown.zig");
const tokens = @import("../tokens.zig");

pub const card_h: f32 = 28;
pub const card_gap: f32 = tokens.space.xs;
pub const child_h: f32 = 20;
pub const child_indent: f32 = 28;
pub const expanded_content_pad: f32 = tokens.space.md;

fn drawClippedText(text: []const u8, x: f32, y: f32, max_w: f32, font_size: f32, color: renderer.Color) void {
    if (max_w <= 0 or text.len == 0) return;
    renderer.Renderer.pushClipRect(x, y - 2, max_w, font_size + 6);
    defer renderer.Renderer.popClipRect();
    renderer.Renderer.drawText(text, x, y, font_size, color);
}

pub fn stepVisibleInMode(mode: agent_session.Mode, kind: []const u8) bool {
    if (mode == .ask and std.mem.eql(u8, kind, "propose")) return false;
    return true;
}

pub fn kindAccent(kind: []const u8) renderer.Color {
    if (std.mem.eql(u8, kind, "explore")) return .{ .r = 0.45, .g = 0.72, .b = 0.95, .a = 1.0 };
    if (std.mem.eql(u8, kind, "bash")) return tokens.color.warning;
    if (std.mem.eql(u8, kind, "mcp")) return .{ .r = 0.72, .g = 0.55, .b = 0.95, .a = 1.0 };
    if (std.mem.eql(u8, kind, "web")) return .{ .r = 0.5, .g = 0.85, .b = 0.75, .a = 1.0 };
    if (std.mem.eql(u8, kind, "remember")) return .{ .r = 0.95, .g = 0.78, .b = 0.45, .a = 1.0 };
    if (std.mem.eql(u8, kind, "propose")) return .{ .r = 0.55, .g = 0.9, .b = 0.55, .a = 1.0 };
    if (std.mem.eql(u8, kind, "thought")) return .{ .r = 0.65, .g = 0.68, .b = 0.78, .a = 1.0 };
    return tokens.color.text_muted;
}

pub fn formatTitle(
    step: *const agent_session.AgentStep,
    steps: []const agent_session.AgentStep,
    step_i: usize,
    buf: []u8,
) []const u8 {
    if (step.is_thought) return "Thought";

    var summary = step.summary;
    if (summary.len == 0 and step.child_count > 0) {
        var j = step_i + 1;
        while (j < steps.len) : (j += 1) {
            if (steps[j].parent_index == step_i) {
                summary = steps[j].summary;
                break;
            }
        }
    }

    if (step.child_count <= 1) {
        return std.fmt.bufPrint(buf, "{s}", .{summary}) catch summary;
    }
    if (std.mem.eql(u8, step.kind, "explore")) {
        return std.fmt.bufPrint(buf, "Explored {d} items", .{step.child_count}) catch "Explored";
    }
    if (std.mem.eql(u8, step.kind, "bash")) {
        return std.fmt.bufPrint(buf, "Ran {d} commands", .{step.child_count}) catch "Ran commands";
    }
    return std.fmt.bufPrint(buf, "{s} ({d})", .{ step.kind, step.child_count }) catch step.kind;
}

fn compactTitle(text: []const u8, buf: []u8) []const u8 {
    if (text.len <= buf.len) return text;
    var len = buf.len;
    while (len > 0 and (text[len] & 0xc0) == 0x80) : (len -= 1) {}
    if (len > 3) len -= 3;
    @memcpy(buf[0..len], text[0..len]);
    @memcpy(buf[len .. len + 3], "...");
    return buf[0 .. len + 3];
}

pub fn stepHeight(
    steps: []agent_session.AgentStep,
    step_i: usize,
    content_w: f32,
    mode: agent_session.Mode,
) f32 {
    const step = &steps[step_i];
    if (step.parent_index != null) return 0;
    if (!stepVisibleInMode(mode, step.kind)) return 0;

    const is_propose = std.mem.eql(u8, step.kind, "propose");
    const is_write = std.mem.eql(u8, step.kind, "write_to_file");
    const is_replace = std.mem.eql(u8, step.kind, "replace_file_content");
    const is_multi_replace = std.mem.eql(u8, step.kind, "multi_replace_file_content");
    const should_connect = is_propose or is_write or is_replace or is_multi_replace;
    const connect_to_content = should_connect and step.expanded and step.content != null;

    const current_card_gap = if (connect_to_content) 0.0 else card_gap;
    var h = card_h + current_card_gap;
    if (!step.expanded) return h;

    if (step.is_thought) {
        if (step.content) |text| {
            h += chat_markdown.contentHeight(text, content_w) + expanded_content_pad;
        }
        return h;
    }

    var has_detail = false;
    if (step.content) |text| {
        has_detail = true;
        h += chat_markdown.contentHeight(text, content_w);
    }

    var child_j = step_i + 1;
    while (child_j < steps.len) : (child_j += 1) {
        const child = &steps[child_j];
        if (child.parent_index == null or child.parent_index.? != step_i) continue;
        has_detail = true;
        h += child_h;
        if (child.expanded) {
            if (child.content) |text| {
                h += chat_markdown.contentHeight(text, content_w - child_indent) + expanded_content_pad;
            }
        }
    }
    return if (has_detail) h + expanded_content_pad else h;
}

pub fn totalStepsHeight(steps: []agent_session.AgentStep, content_w: f32, mode: agent_session.Mode) f32 {
    var total: f32 = 0;
    var i: usize = 0;
    while (i < steps.len) : (i += 1) {
        total += stepHeight(steps, i, content_w, mode);
    }
    return total;
}

pub fn drawStep(
    agent_x: f32,
    inner_x: f32,
    content_w: f32,
    y: f32,
    steps: []agent_session.AgentStep,
    step_i: usize,
    allocator: std.mem.Allocator,
    anim_time: f32,
    mode: agent_session.Mode,
    wb: ?*@import("../../workbench.zig").Workbench,
    base_hash: u64,
) f32 {
    _ = agent_x;
    const step = &steps[step_i];
    if (step.parent_index != null) return 0;
    if (!stepVisibleInMode(mode, step.kind)) return 0;

    const accent = if (step.running)
        tokens.color.accent
    else
        tokens.color.success;

    const card_x = inner_x;
    const card_w = content_w;

    // Very subtle border, dark background
    const border_color: renderer.Color = tokens.color.border;
    const card_bg: renderer.Color = tokens.color.surface_raised;

    renderer.Renderer.drawRoundedRect(card_x, y, card_w, card_h, tokens.radius.md, border_color);
    renderer.Renderer.drawRoundedRect(card_x + 1, y + 1, card_w - 2, card_h - 2, tokens.radius.md - 1, card_bg);

    const is_propose = std.mem.eql(u8, step.kind, "propose");
    const is_write = std.mem.eql(u8, step.kind, "write_to_file");
    const is_replace = std.mem.eql(u8, step.kind, "replace_file_content");
    const is_multi_replace = std.mem.eql(u8, step.kind, "multi_replace_file_content");
    const should_connect = is_propose or is_write or is_replace or is_multi_replace;
    const connect_to_content = should_connect and step.expanded and step.content != null;

    if (connect_to_content) {
        renderer.Renderer.drawRect(card_x, y + card_h - 6, card_w, 6, border_color);
        renderer.Renderer.drawRect(card_x + 1, y + card_h - 6, card_w - 2, 6, card_bg);
    }

    // Draw the status dot
    const dot_y = y + (card_h - 6.0) / 2.0;
    if (step.running) {
        const pulse = 0.45 + 0.35 * @sin(anim_time * 6.0);
        renderer.Renderer.drawRoundedRect(card_x + 10, dot_y, 6, 6, 3, .{
            .r = accent.r,
            .g = accent.g,
            .b = accent.b,
            .a = pulse,
        });
    } else {
        renderer.Renderer.drawRoundedRect(card_x + 10, dot_y, 6, 6, 3, accent);
    }

    const is_parent = step.child_count > 0 or step.is_thought;
    if (is_parent) {
        const icon = if (step.expanded) renderer.icons.chevron_down else renderer.icons.chevron_right;
        renderer.Renderer.drawSvg(icon, card_x + card_w - 20, y + 6, 16, 16, .{ .r = 0.5, .g = 0.5, .b = 0.55, .a = 1.0 });
    }

    var title_buf: [384:0]u8 = undefined;
    var compact_buf: [220]u8 = undefined;
    const title = if (step.running) blk: {
        const compact = compactTitle(step.summary, &compact_buf);
        const n = @min(compact.len, title_buf.len - 1);
        @memcpy(title_buf[0..n], compact[0..n]);
        title_buf[n] = 0;
        break :blk title_buf[0..n :0];
    } else blk: {
        const formatted = formatTitle(step, steps, step_i, &title_buf);
        const compact = compactTitle(formatted, &compact_buf);
        const n = @min(compact.len, title_buf.len - 1);
        if (compact.ptr != title_buf[0..].ptr) @memcpy(title_buf[0..n], compact[0..n]);
        title_buf[n] = 0;
        break :blk title_buf[0..n :0];
    };

    // Draw the title text
    const title_fg = if (step.running)
        renderer.Color{ .r = 0.72, .g = 0.78, .b = 0.86, .a = 1.0 }
    else
        renderer.Color{ .r = 0.88, .g = 0.9, .b = 0.94, .a = 1.0 };

    const title_x = card_x + 24;
    const title_max_w = @max(0, card_w - 52);

    renderer.Renderer.pushClipRect(title_x, y + 4, title_max_w, card_h - 6);

    // Check if the title can be split (e.g. "Read file.ts")
    const space_idx = std.mem.indexOf(u8, title, " ");
    if (space_idx != null and space_idx.? < 15) {
        const verb = title[0..space_idx.?];
        const rest = title[space_idx.? + 1 ..];

        renderer.Renderer.drawText(verb, title_x, y + 8, 11.5, title_fg);
        const verb_w = renderer.Renderer.measureText(verb, 11.5);
        renderer.Renderer.drawText(rest, title_x + verb_w + 4, y + 8, 11.5, .{ .r = 0.6, .g = 0.6, .b = 0.65, .a = 1.0 });
    } else {
        renderer.Renderer.drawText(title, title_x, y + 8, 11.5, title_fg);
    }
    renderer.Renderer.popClipRect();

    const current_card_gap = if (connect_to_content) 0.0 else card_gap;
    var content_y = y + card_h + current_card_gap;

    if (step.expanded) {
        if (step.is_thought) {
            if (step.content) |text| {
                const thought_style = chat_markdown.Style{
                    .fg = .{ .r = 0.65, .g = 0.68, .b = 0.75, .a = 1.0 },
                    .code_block_bg = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1.0 },
                };
                const drawn = chat_markdown.drawContent(
                    allocator,
                    text,
                    inner_x,
                    content_y,
                    content_w,
                    thought_style,
                    wb,
                    base_hash,
                ) catch 0;
                content_y += drawn + expanded_content_pad;
            }
        } else {
            var has_detail = false;
            if (step.content) |text| {
                has_detail = true;
                const style = chat_markdown.Style{
                    .fg = .{ .r = 0.75, .g = 0.8, .b = 0.85, .a = 1.0 },
                    .code_block_bg = .{ .r = 0.1, .g = 0.11, .b = 0.14, .a = 1.0 },
                    .top_square = connect_to_content,
                };
                const drawn = chat_markdown.drawContent(
                    allocator,
                    text,
                    inner_x,
                    content_y,
                    content_w,
                    style,
                    wb,
                    base_hash,
                ) catch 0;
                content_y += drawn + expanded_content_pad;
            }
            var child_j = step_i + 1;
            while (child_j < steps.len) : (child_j += 1) {
                const child = &steps[child_j];
                if (child.parent_index == null or child.parent_index.? != step_i) continue;
                has_detail = true;

                renderer.Renderer.drawRoundedRect(card_x + child_indent, content_y, card_w - child_indent, child_h - 2, 4, .{ .r = 0.13, .g = 0.15, .b = 0.18, .a = 1.0 });
                var child_buf: [512:0]u8 = undefined;
                const child_line = std.fmt.bufPrintZ(&child_buf, "{s}", .{child.summary}) catch "Action";
                drawClippedText(child_line, inner_x + child_indent + 8, content_y + 3, card_w - child_indent - 16, 11.0, .{ .r = 0.72, .g = 0.76, .b = 0.82, .a = 1.0 });
                content_y += child_h;

                if (child.expanded) {
                    if (child.content) |text| {
                        const style = chat_markdown.Style{
                            .fg = .{ .r = 0.75, .g = 0.8, .b = 0.85, .a = 1.0 },
                            .code_block_bg = .{ .r = 0.1, .g = 0.11, .b = 0.14, .a = 1.0 },
                        };
                        const drawn = chat_markdown.drawContent(
                            allocator,
                            text,
                            inner_x + child_indent,
                            content_y,
                            content_w - child_indent,
                            style,
                            wb,
                            base_hash,
                        ) catch 0;
                        content_y += drawn + expanded_content_pad;
                    }
                }
            }
            if (has_detail) content_y += expanded_content_pad;
        }
    }

    return content_y - y;
}

pub fn hitTestStep(
    steps: []agent_session.AgentStep,
    step_i: usize,
    content_y: f32,
    x: f32,
    y: f32,
    inner_x: f32,
    content_w: f32,
) ?usize {
    const step = &steps[step_i];
    if (step.parent_index != null) return null;
    if (x < inner_x or x > inner_x + content_w) return null;

    const is_parent = step.child_count > 0 or step.is_thought;
    if (!is_parent) return null;

    if (y >= content_y and y < content_y + card_h) return step_i;

    if (step.expanded and !step.is_thought) {
        var cy = content_y + card_h + card_gap;
        var child_j = step_i + 1;
        while (child_j < steps.len) : (child_j += 1) {
            const child = &steps[child_j];
            if (child.parent_index == null or child.parent_index.? != step_i) continue;

            if (y >= cy and y < cy + child_h) return child_j;

            cy += child_h;
            if (child.expanded) {
                if (child.content) |text| {
                    cy += chat_markdown.contentHeight(text, content_w - child_indent) + expanded_content_pad;
                }
            }
        }
    }

    return null;
}

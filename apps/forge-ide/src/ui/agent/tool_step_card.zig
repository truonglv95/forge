const std = @import("std");
const renderer = @import("forge-renderer");
const agent_session = @import("../../agent/session.zig");
const chat_markdown = @import("chat_markdown.zig");

pub const card_h: f32 = 28;
pub const card_gap: f32 = 4;
pub const child_h: f32 = 20;
pub const child_indent: f32 = 28;
pub const expanded_content_pad: f32 = 8;

pub fn stepVisibleInMode(mode: agent_session.Mode, kind: []const u8) bool {
    if (mode == .ask and std.mem.eql(u8, kind, "propose")) return false;
    return true;
}

pub fn kindAccent(kind: []const u8) renderer.Color {
    if (std.mem.eql(u8, kind, "explore")) return .{ .r = 0.45, .g = 0.72, .b = 0.95, .a = 1.0 };
    if (std.mem.eql(u8, kind, "bash")) return .{ .r = 0.95, .g = 0.72, .b = 0.4, .a = 1.0 };
    if (std.mem.eql(u8, kind, "mcp")) return .{ .r = 0.72, .g = 0.55, .b = 0.95, .a = 1.0 };
    if (std.mem.eql(u8, kind, "web")) return .{ .r = 0.5, .g = 0.85, .b = 0.75, .a = 1.0 };
    if (std.mem.eql(u8, kind, "remember")) return .{ .r = 0.95, .g = 0.78, .b = 0.45, .a = 1.0 };
    if (std.mem.eql(u8, kind, "propose")) return .{ .r = 0.55, .g = 0.9, .b = 0.55, .a = 1.0 };
    if (std.mem.eql(u8, kind, "thought")) return .{ .r = 0.65, .g = 0.68, .b = 0.78, .a = 1.0 };
    return .{ .r = 0.6, .g = 0.65, .b = 0.72, .a = 1.0 };
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

pub fn stepHeight(
    steps: []agent_session.AgentStep,
    step_i: usize,
    content_w: f32,
    mode: agent_session.Mode,
) f32 {
    const step = &steps[step_i];
    if (step.parent_index != null) return 0;
    if (!stepVisibleInMode(mode, step.kind)) return 0;

    var h = card_h + card_gap;
    if (!step.expanded) return h;

    if (step.is_thought) {
        if (step.content) |text| {
            h += chat_markdown.contentHeight(text, content_w - child_indent) + expanded_content_pad;
        }
        return h;
    }

    var child_j = step_i + 1;
    while (child_j < steps.len) : (child_j += 1) {
        const child = &steps[child_j];
        if (child.parent_index == null or child.parent_index.? != step_i) continue;
        h += child_h;
    }
    return h + expanded_content_pad;
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
) f32 {
    const step = &steps[step_i];
    if (step.parent_index != null) return 0;
    if (!stepVisibleInMode(mode, step.kind)) return 0;

    const accent = kindAccent(step.kind);
    const card_x = agent_x + 8;
    const card_w = content_w;
    const card_bg: renderer.Color = if (step.running)
        .{ .r = 0.18, .g = 0.2, .b = 0.26, .a = 1.0 }
    else
        .{ .r = 0.16, .g = 0.18, .b = 0.22, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(card_x, y, card_w, card_h, 6, card_bg);
    renderer.Renderer.drawRect(card_x + 2, y + 4, 2, card_h - 4, .{ .r = accent.r, .g = accent.g, .b = accent.b, .a = if (step.running) 0.55 else 0.35 });
    renderer.Renderer.drawRoundedRect(card_x + 6, y + 6, 14, 14, 7, accent);
    if (step.running) {
        const pulse = 0.45 + 0.35 * @sin(anim_time * 6.0);
        renderer.Renderer.drawRoundedRect(card_x + 9, y + 9, 8, 8, 4, .{
            .r = accent.r,
            .g = accent.g,
            .b = accent.b,
            .a = pulse,
        });
    } else {
        var idx_buf: [8:0]u8 = undefined;
        const idx_text = std.fmt.bufPrint(&idx_buf, "{d}", .{step.index}) catch "?";
        idx_buf[idx_text.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&idx_buf), card_x + 9, y + 8, 9.0, .{ .r = 0.1, .g = 0.12, .b = 0.14, .a = 1.0 });
    }
    renderer.Renderer.drawRoundedRect(card_x + 24, y + 8, 4, 12, 2, accent);

    const is_parent = step.child_count > 0 or step.is_thought;
    if (is_parent) {
        const icon = if (step.expanded) renderer.icons.chevron_down else renderer.icons.chevron_right;
        renderer.Renderer.drawSvg(icon, inner_x + 4, y + 6, 16, 16, .{ .r = 0.65, .g = 0.68, .b = 0.72, .a = 1.0 });
    }

    var title_buf: [384:0]u8 = undefined;
    const title = if (step.running) blk: {
        const n = @min(step.summary.len, title_buf.len - 1);
        @memcpy(title_buf[0..n], step.summary[0..n]);
        title_buf[n] = 0;
        break :blk title_buf[0..n :0];
    } else blk: {
        const formatted = formatTitle(step, steps, step_i, &title_buf);
        title_buf[@min(formatted.len, title_buf.len - 1)] = 0;
        break :blk formatted;
    };
    const title_fg = if (step.running)
        renderer.Color{ .r = 0.72, .g = 0.78, .b = 0.86, .a = 1.0 }
    else
        renderer.Color{ .r = 0.88, .g = 0.9, .b = 0.94, .a = 1.0 };
    renderer.Renderer.drawText(title, inner_x + 30, y + 7, 12.0, title_fg);

    var content_y = y + card_h + card_gap;

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
                    inner_x + child_indent,
                    content_y,
                    content_w - child_indent,
                    thought_style,
                ) catch 0;
                content_y += drawn + expanded_content_pad;
            }
        } else {
            var child_j = step_i + 1;
            while (child_j < steps.len) : (child_j += 1) {
                const child = &steps[child_j];
                if (child.parent_index == null or child.parent_index.? != step_i) continue;

                renderer.Renderer.drawRoundedRect(card_x + child_indent, content_y, card_w - child_indent, child_h - 2, 4, .{ .r = 0.13, .g = 0.15, .b = 0.18, .a = 1.0 });
                var child_buf: [512:0]u8 = undefined;
                const child_line = std.fmt.bufPrintZ(&child_buf, "{s}", .{child.summary}) catch "Action";
                renderer.Renderer.drawText(child_line, inner_x + child_indent + 8, content_y + 3, 11.0, .{ .r = 0.72, .g = 0.76, .b = 0.82, .a = 1.0 });
                content_y += child_h;
            }
            content_y += expanded_content_pad;
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
    return null;
}

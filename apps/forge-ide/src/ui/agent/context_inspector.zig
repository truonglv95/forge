const std = @import("std");
const renderer = @import("forge-renderer");
const layout = @import("../core/layout.zig");
const agent_session = @import("../../agent/session.zig");

const agent_composer = @import("agent_composer.zig");
const ai = @import("forge-ai");

pub const composer_height = agent_composer.composer_base_h;
pub const composer_pad = agent_composer.composer_pad;
pub const strip_gap: f32 = 6;
pub const header_h: f32 = 22;
pub const row_h: f32 = 15;
pub const max_visible_rows: usize = 5;
pub const detail_h: f32 = 36;
pub const pill_h: f32 = 18;

pub fn effectiveEntryCount(agent: *agent_session.Session, entry_count: usize) usize {
    if (entry_count > 0) return entry_count;
    agent.lock();
    defer agent.unlock();
    return if (agent.scope_files.items.len > 0) 1 else 0;
}

pub fn composerTop(window_h: f32, attachment_count: usize, agent_w: f32, prompt: *const @import("forge-editor").Buffer) f32 {
    return agent_composer.composerTop(window_h, attachment_count, agent_w, prompt);
}

pub fn stripTop(
    window_h: f32,
    expanded: bool,
    entry_count: usize,
    attachment_count: usize,
    agent_w: f32,
    prompt: *const @import("forge-editor").Buffer,
    has_detail: bool,
    has_routing: bool,
) f32 {
    return composerTop(window_h, attachment_count, agent_w, prompt) - stripHeight(expanded, entry_count, has_detail, has_routing) - strip_gap;
}

pub const ToggleRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: ToggleRect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub const routing_row_h: f32 = 14;

pub fn stripHeight(expanded: bool, entry_count: usize, has_detail: bool, has_routing: bool) f32 {
    if (entry_count == 0 and !has_routing) return header_h;
    if (entry_count == 0) return header_h + routing_row_h + 4;
    if (!expanded) {
        var h = header_h + pill_h + 6;
        if (has_routing) h += routing_row_h + 2;
        return h;
    }
    const rows = @min(entry_count, max_visible_rows);
    var h = header_h + pill_h + 6 + @as(f32, @floatFromInt(rows)) * row_h + 8;
    if (has_routing) h += routing_row_h + 2;
    if (has_detail) h += detail_h + 4;
    return h;
}

pub fn toggleRect(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    entry_count: usize,
    attachment_count: usize,
    prompt: *const @import("forge-editor").Buffer,
) ToggleRect {
    const top = stripTop(window_h, true, entry_count, attachment_count, agent_w, prompt, false, false);
    return .{
        .x = agent_x + 10,
        .y = top,
        .w = agent_w - 20,
        .h = header_h,
    };
}

pub fn hitToggle(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    entry_count: usize,
    attachment_count: usize,
    prompt: *const @import("forge-editor").Buffer,
    has_detail: bool,
    x: f32,
    y: f32,
) bool {
    const top = stripTop(window_h, true, entry_count, attachment_count, agent_w, prompt, has_detail, false);
    return x >= agent_x + 10 and x < agent_x + agent_w - 10 and y >= top and y < top + header_h;
}

pub fn hitEntryRow(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    entry_count: usize,
    attachment_count: usize,
    prompt: *const @import("forge-editor").Buffer,
    scroll_y: f32,
    x: f32,
    y: f32,
) ?usize {
    if (entry_count == 0) return null;
    const pad: f32 = 10;
    const inner_x = agent_x + pad + 10;
    const top = stripTop(window_h, true, entry_count, attachment_count, agent_w, prompt, false, false);
    const list_top = top + header_h + pill_h + 8 - scroll_y;
    if (x < inner_x or x > agent_x + agent_w - pad) return null;
    const rel = y - list_top;
    if (rel < 0) return null;
    const row = @as(usize, @intFromFloat(rel / row_h));
    if (row >= entry_count or row >= max_visible_rows) return null;
    return row;
}

pub fn hitEntryAction(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    entry_count: usize,
    attachment_count: usize,
    prompt: *const @import("forge-editor").Buffer,
    scroll_y: f32,
    x: f32,
    y: f32,
) ?usize {
    if (entry_count == 0) return null;
    const pad: f32 = 10;
    const action_x = agent_x + agent_w - pad - 24;
    const top = stripTop(window_h, true, entry_count, attachment_count, agent_w, prompt, false, false);
    const list_top = top + header_h + pill_h + 8 - scroll_y;
    if (x < action_x or x > action_x + 16) return null;
    const rel = y - list_top;
    if (rel < 0) return null;
    const row = @as(usize, @intFromFloat(rel / row_h));
    if (row >= entry_count or row >= max_visible_rows) return null;
    return row;
}

fn formatBytes(buf: []u8, value: usize) []const u8 {
    if (value >= 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MiB", .{@as(f64, @floatFromInt(value)) / (1024.0 * 1024.0)}) catch "???";
    }
    if (value >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KiB", .{@as(f64, @floatFromInt(value)) / 1024.0}) catch "???";
    }
    return std.fmt.bufPrint(buf, "{d} B", .{value}) catch "???";
}

fn statusGlyph(status: agent_session.ContextEntryStatus) []const u8 {
    return switch (status) {
        .included => "+",
        .truncated => "~",
        .rejected => "x",
    };
}

fn statusColor(status: agent_session.ContextEntryStatus) renderer.Color {
    return switch (status) {
        .included => .{ .r = 0.45, .g = 0.85, .b = 0.55, .a = 1.0 },
        .truncated => .{ .r = 0.95, .g = 0.78, .b = 0.35, .a = 1.0 },
        .rejected => .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 },
    };
}

fn kindLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "rules")) return "rules";
    if (std.mem.eql(u8, kind, "intent")) return "prompt";
    if (std.mem.eql(u8, kind, "file")) return "file";
    if (std.mem.eql(u8, kind, "diagnostic")) return "diag";
    if (std.mem.eql(u8, kind, "retrieval")) return "retrieve";
    if (std.mem.eql(u8, kind, "semantic")) return "semantic";
    if (std.mem.eql(u8, kind, "fused")) return "fused";
    if (std.mem.eql(u8, kind, "memory")) return "memory";
    if (std.mem.eql(u8, kind, "web")) return "web";
    if (std.mem.eql(u8, kind, "imports")) return "imports";
    if (std.mem.eql(u8, kind, "lsp")) return "lsp";
    if (std.mem.eql(u8, kind, "docs")) return "docs";
    if (std.mem.eql(u8, kind, "git_diff")) return "git";
    if (std.mem.eql(u8, kind, "recent")) return "recent";
    return kind;
}

fn copyToSentinelBuf(dest: []u8, src: []const u8) []const u8 {
    const n = @min(src.len, dest.len - 1);
    @memcpy(dest[0..n], src[0..n]);
    dest[n] = 0;
    return dest[0..n];
}

pub fn draw(
    agent: *agent_session.Session,
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    used_bytes: usize,
    max_bytes: usize,
    entry_count: usize,
    expanded: bool,
    attachment_count: usize,
    prompt: *const @import("forge-editor").Buffer,
    scroll_y: f32,
    selected_index: ?usize,
) void {
    agent.lock();
    const has_scope = agent.scope_files.items.len > 0;
    const has_detail = selected_index != null and expanded;
    const has_routing = agent.routing_task_intent.len > 0;
    const routing_task = agent.routing_task_intent;
    const routing_profile = agent.routing_profile;
    const routing_tools = agent.routing_tools;
    agent.unlock();
    if (entry_count == 0 and used_bytes == 0 and !has_scope and !has_routing) return;

    const pad: f32 = 10;
    const inner_x = agent_x + pad + 10;
    const content_w = agent_w - pad * 2 - 20;
    const top = stripTop(window_h, expanded, entry_count, attachment_count, agent_w, prompt, has_detail, has_routing);
    const height = stripHeight(expanded, entry_count, has_detail, has_routing);

    renderer.Renderer.drawRoundedRect(agent_x + pad, top, agent_w - pad * 2, height, 8, .{
        .r = 0.11,
        .g = 0.13,
        .b = 0.18,
        .a = 1.0,
    });

    const chevron = if (expanded) "v" else ">";
    var header_buf: [160:0]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} Context  {d} items", .{ chevron, entry_count }) catch "Context";
    header_buf[header.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&header_buf), inner_x, top + 4, 11.0, .{ .r = 0.72, .g = 0.78, .b = 0.95, .a = 1.0 });

    var budget_buf: [64:0]u8 = undefined;
    var used_label: [32:0]u8 = undefined;
    var max_label: [32:0]u8 = undefined;
    const used_text = formatBytes(&used_label, used_bytes);
    const max_text = formatBytes(&max_label, max_bytes);
    const budget_line = std.fmt.bufPrint(&budget_buf, "{s} / {s}", .{ used_text, max_text }) catch "?";
    budget_buf[budget_line.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&budget_buf), agent_x + agent_w - pad - 120, top + 4, 10.0, .{
        .r = 0.55,
        .g = 0.62,
        .b = 0.75,
        .a = 1.0,
    });

    const bar_x = inner_x;
    const bar_y = top + header_h - 6;
    const bar_w = content_w;
    const bar_h: f32 = 3;
    renderer.Renderer.drawRoundedRect(bar_x, bar_y, bar_w, bar_h, 1.5, .{ .r = 0.18, .g = 0.2, .b = 0.26, .a = 1.0 });
    const fill_ratio = if (max_bytes > 0)
        @min(@as(f32, @floatFromInt(used_bytes)) / @as(f32, @floatFromInt(max_bytes)), 1.0)
    else
        0.0;
    if (fill_ratio > 0) {
        renderer.Renderer.drawRoundedRect(bar_x, bar_y, bar_w * fill_ratio, bar_h, 1.5, .{
            .r = 0.35,
            .g = 0.62,
            .b = 0.95,
            .a = 1.0,
        });
    }

    if (has_routing) {
        var route_buf: [384:0]u8 = undefined;
        const route_line = std.fmt.bufPrint(&route_buf, "Route: {s} · {s} · tools: {s}", .{
            routing_task,
            routing_profile,
            routing_tools,
        }) catch "Route unavailable";
        route_buf[route_line.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&route_buf), inner_x, top + header_h + 2, 9.5, .{
            .r = 0.62,
            .g = 0.82,
            .b = 0.72,
            .a = 1.0,
        });
    }

    var pill_x = inner_x;
    const pill_y = top + header_h + 2 + if (has_routing) routing_row_h + 2 else 0;
    agent.lock();
    defer agent.unlock();

    for (agent.scope_files.items) |path| {
        if (pill_x + 80 > agent_x + agent_w - pad) break;
        var pill_buf: [96:0]u8 = undefined;
        var label_buf: [96]u8 = undefined;
        const pill = ai.scope_resolver.displayLabel(path, &label_buf);
        const pill_text = copyToSentinelBuf(&pill_buf, pill);
        const pill_w: f32 = @floatFromInt(pill_text.len * 6 + 14);
        renderer.Renderer.drawRoundedRect(pill_x, pill_y, pill_w, pill_h, 4, .{ .r = 0.16, .g = 0.28, .b = 0.42, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&pill_buf), pill_x + 6, pill_y + 2, 10.0, .{ .r = 0.85, .g = 0.95, .b = 1.0, .a = 1.0 });
        pill_x += pill_w + 4;
    }

    if (!expanded) return;

    var row_y = pill_y + pill_h + 8 - scroll_y;
    var row_index: usize = 0;
    for (agent.context_entries.items) |entry| {
        if (row_index >= max_visible_rows) break;
        if (row_y + row_h >= top and row_y <= top + height) {
            if (selected_index) |sel| {
                if (sel == row_index) {
                    renderer.Renderer.drawRoundedRect(inner_x - 4, row_y - 1, content_w, row_h, 3, .{ .r = 0.18, .g = 0.24, .b = 0.34, .a = 1.0 });
                }
            }
            var row_buf: [384:0]u8 = undefined;
            const glyph = statusGlyph(entry.status);
            const label = kindLabel(entry.kind);
            const row_line = if (entry.reason) |reason| blk: {
                break :blk std.fmt.bufPrint(&row_buf, "{s} [{s}] {s} — {s}", .{
                    glyph,
                    label,
                    entry.name,
                    reason,
                }) catch continue;
            } else blk: {
                break :blk std.fmt.bufPrint(&row_buf, "{s} [{s}] {s} ({d} B)", .{
                    glyph,
                    label,
                    entry.name,
                    entry.bytes,
                }) catch continue;
            };
            row_buf[row_line.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&row_buf), inner_x, row_y, 9.5, statusColor(entry.status));

            const action_x = agent_x + agent_w - pad - 24;
            const is_file = std.mem.eql(u8, entry.kind, "file");
            var is_pinned = false;
            if (is_file) {
                for (agent.scope_files.items) |existing| {
                    if (std.mem.eql(u8, existing, entry.name)) {
                        is_pinned = true;
                        break;
                    }
                }
            }
            if (is_file) {
                if (is_pinned) {
                    renderer.Renderer.drawText("x", action_x, row_y, 10.0, .{ .r = 0.8, .g = 0.4, .b = 0.4, .a = 1.0 });
                } else {
                    renderer.Renderer.drawText("+", action_x, row_y, 10.0, .{ .r = 0.4, .g = 0.8, .b = 0.4, .a = 1.0 });
                }
            } else {
                renderer.Renderer.drawText("x", action_x, row_y, 10.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            }
        }
        row_y += row_h;
        row_index += 1;
    }

    if (agent.context_entries.items.len > max_visible_rows) {
        var more_buf: [64:0]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "... +{d} more", .{agent.context_entries.items.len - max_visible_rows}) catch "...";
        more_buf[more.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&more_buf), inner_x, row_y, 9.0, .{ .r = 0.5, .g = 0.55, .b = 0.65, .a = 1.0 });
    }

    if (selected_index) |sel| {
        if (sel < agent.context_entries.items.len) {
            const entry = agent.context_entries.items[sel];
            const detail_y = top + height - detail_h;
            renderer.Renderer.drawRoundedRect(agent_x + pad, detail_y, agent_w - pad * 2, detail_h, 6, .{ .r = 0.14, .g = 0.17, .b = 0.22, .a = 1.0 });
            var detail_buf: [512:0]u8 = undefined;
            const detail = if (entry.reason) |reason|
                std.fmt.bufPrint(&detail_buf, "{s} · {s} · {s}", .{ entry.kind, entry.name, reason }) catch entry.name
            else
                std.fmt.bufPrint(&detail_buf, "{s} · {s} · {d} bytes", .{ entry.kind, entry.name, entry.bytes }) catch entry.name;
            detail_buf[detail.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&detail_buf), inner_x, detail_y + 12, 9.5, .{ .r = 0.78, .g = 0.84, .b = 0.92, .a = 1.0 });
        }
    }
}

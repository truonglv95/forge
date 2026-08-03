const std = @import("std");
const renderer = @import("forge-renderer");
const agent_session = @import("../../agent/session.zig");
const chat_markdown = @import("chat_markdown.zig");
const metrics = @import("metrics.zig");
const tokens = @import("../tokens.zig");

pub const card_h: f32 = metrics.tool_step.card_h;
pub const card_gap: f32 = metrics.tool_step.card_gap;
pub const child_h: f32 = metrics.tool_step.child_h;
pub const child_indent: f32 = metrics.tool_step.child_indent;
pub const expanded_content_pad: f32 = metrics.tool_step.expanded_content_pad;

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
    // Dynamic card height — grows when the title wraps onto multiple
    // lines (Issue 4: previously long tool-call titles were clipped at
    // card_h, hiding the suffix and leaving users unable to tell what
    // the step was doing).
    const dyn_card_h = computeCardHeight(step, steps, step_i, content_w);
    var h = dyn_card_h + current_card_gap;
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

/// Title font size used for tool-step card titles.
const title_font_size: f32 = 11.5;
/// Title horizontal padding inside the card (status dot + spacing).
const title_x_pad: f32 = 24.0;
/// Title right padding (chevron icon + spacing).
const title_right_pad: f32 = 28.0;
/// Title line height for wrapped titles.
const title_line_h: f32 = 14.0;
/// Vertical padding inside the card (top + bottom = 2 * title_v_pad).
const title_v_pad: f32 = 6.0;

/// Card-height cache — avoids re-running measureText on every frame for
/// tool-step cards whose titles haven't changed (Issue: per-frame
/// measureText for wrap estimation caused measurable CPU usage when the
/// agent panel showed many cards). Keyed by (title_hash, content_w) —
/// we hash the title content so the cache works even when the title is
/// produced via stack-local compact_buf (which differs across calls).
/// The cache is invalidated implicitly when the title text changes
/// (different hash → different slot). Capacity is small (8 slots) since
/// typical agent runs produce 3-6 visible cards at a time.
const CardHeightCacheEntry = struct {
    title_hash: u64,
    title_len: u32,
    content_w_bits: u32, // content_w quantized to integer for stable key
    height: f32,
};
var card_height_cache: [8]CardHeightCacheEntry = [_]CardHeightCacheEntry{
    .{ .title_hash = 0, .title_len = 0, .content_w_bits = 0, .height = 0 },
    .{ .title_hash = 0, .title_len = 0, .content_w_bits = 0, .height = 0 },
    .{ .title_hash = 0, .title_len = 0, .content_w_bits = 0, .height = 0 },
    .{ .title_hash = 0, .title_len = 0, .content_w_bits = 0, .height = 0 },
    .{ .title_hash = 0, .title_len = 0, .content_w_bits = 0, .height = 0 },
    .{ .title_hash = 0, .title_len = 0, .content_w_bits = 0, .height = 0 },
    .{ .title_hash = 0, .title_len = 0, .content_w_bits = 0, .height = 0 },
    .{ .title_hash = 0, .title_len = 0, .content_w_bits = 0, .height = 0 },
};
var card_height_cache_inited: bool = false;

fn titleHash(title: []const u8) u64 {
    return std.hash.CityHash64.hash(title);
}

fn lookupCardHeight(title: []const u8, content_w: f32) ?f32 {
    if (!card_height_cache_inited) return null;
    const key_hash = titleHash(title);
    const key_len: u32 = @intCast(title.len);
    const key_w: u32 = @intFromFloat(@round(content_w));
    for (card_height_cache) |entry| {
        if (entry.title_hash == key_hash and entry.title_len == key_len and entry.content_w_bits == key_w) {
            return entry.height;
        }
    }
    return null;
}

fn storeCardHeight(title: []const u8, content_w: f32, height: f32) void {
    card_height_cache_inited = true;
    const key_hash = titleHash(title);
    const key_len: u32 = @intCast(title.len);
    const key_w: u32 = @intFromFloat(@round(content_w));
    // Find existing slot for this key, or reuse slot 0 (LRU-ish).
    var slot_idx: usize = 0;
    for (card_height_cache, 0..) |entry, i| {
        if (entry.title_hash == key_hash and entry.title_len == key_len and entry.content_w_bits == key_w) {
            slot_idx = i;
            break;
        }
    }
    card_height_cache[slot_idx] = .{
        .title_hash = key_hash,
        .title_len = key_len,
        .content_w_bits = key_w,
        .height = height,
    };
}

/// Compute the dynamic card height needed to fit the step's title,
/// wrapping onto multiple lines if necessary. The minimum height is
/// the standard `card_h` (28px); wrapped titles grow by `title_line_h`
/// per extra line.
pub fn computeCardHeight(
    step: *const agent_session.AgentStep,
    steps: []const agent_session.AgentStep,
    step_i: usize,
    content_w: f32,
) f32 {
    // Format the title the same way drawStep does so the height matches.
    var title_buf: [384]u8 = undefined;
    const formatted = formatTitle(step, steps, step_i, &title_buf);
    // Use the running-step compact title path too.
    var compact_buf: [220]u8 = undefined;
    const title = if (step.running)
        compactTitle(step.summary, &compact_buf)
    else
        compactTitle(formatted, &compact_buf);

    if (title.len == 0) return card_h;

    // Cache lookup — skips measureText on every frame for unchanged
    // titles. step.summary (and thus `title` via compact_buf) is stable
    // across frames because agent steps are heap-allocated and only
    // mutated on appendAgentStep / clearAgentSteps. compact_buf is on
    // the stack, but its content is derived from step.summary so
    // pointer-identity lookup works for the source allocation.
    if (lookupCardHeight(title, content_w)) |cached_h| {
        return cached_h;
    }

    const title_max_w = @max(0, content_w - title_x_pad - title_right_pad);
    if (title_max_w <= 0) {
        storeCardHeight(title, content_w, card_h);
        return card_h;
    }

    const title_w = renderer.Renderer.measureText(title, title_font_size);
    const result_h: f32 = if (title_w <= title_max_w) card_h else blk: {
        // Need to wrap. Estimate line count by chunking on word boundaries.
        const line_count = estimateWrappedLines(title, title_max_w);
        if (line_count <= 1) break :blk card_h;
        // Height = top pad + line_count * line_h + bottom pad, with a
        // minimum of the standard card_h.
        const natural_h = title_v_pad * 2.0 + @as(f32, @floatFromInt(line_count)) * title_line_h;
        break :blk @max(card_h, natural_h);
    };
    storeCardHeight(title, content_w, result_h);
    return result_h;
}

/// Estimate the number of lines a piece of text will occupy when
/// rendered with `title_font_size` inside `max_w` pixels. Uses a
/// greedy word-wrap algorithm with `measureText` for accurate widths.
fn estimateWrappedLines(text: []const u8, max_w: f32) usize {
    if (text.len == 0 or max_w <= 0) return 1;
    var lines: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        // Find next whitespace boundary.
        if (text[i] == ' ' or text[i] == '\t') {
            const candidate_w = renderer.Renderer.measureText(text[line_start..i], title_font_size);
            if (candidate_w > max_w) {
                // Wrap: line_start..i doesn't fit, push the word to next line.
                if (i > line_start) {
                    lines += 1;
                    line_start = i + 1; // skip the space
                }
            }
        }
    }
    // Check the last segment.
    if (line_start < text.len) {
        const last_w = renderer.Renderer.measureText(text[line_start..], title_font_size);
        if (last_w > max_w and line_start > 0) {
            // The last word is on its own line and is still too wide —
            // assume it fits or wraps further; we've already counted one line.
        }
    }
    return @max(1, lines);
}

/// Draw wrapped title text. Returns the number of lines used.
fn drawWrappedTitle(text: []const u8, x: f32, y: f32, max_w: f32, color: renderer.Color) usize {
    if (text.len == 0) return 1;
    // Try single-line first — fast path.
    const w = renderer.Renderer.measureText(text, title_font_size);
    if (w <= max_w) {
        renderer.Renderer.drawText(text, x, y, title_font_size, color);
        return 1;
    }
    // Word-wrap. Greedy: pack as many words as fit per line.
    var lines: usize = 0;
    var line_y = y;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const at_space = !at_end and (text[i] == ' ' or text[i] == '\t');
        if (at_end or at_space) {
            const candidate_w = renderer.Renderer.measureText(text[line_start..i], title_font_size);
            if (candidate_w > max_w and i > line_start + 1) {
                // The accumulated segment doesn't fit — flush the previous
                // line (line_start..prev_break), then start a new line.
                // Find the previous word break (last space before i).
                var prev_break = i;
                while (prev_break > line_start and text[prev_break - 1] != ' ' and text[prev_break - 1] != '\t') {
                    prev_break -= 1;
                }
                if (prev_break > line_start) {
                    renderer.Renderer.drawText(text[line_start..prev_break], x, line_y, title_font_size, color);
                    lines += 1;
                    line_y += title_line_h;
                    line_start = if (prev_break < text.len and (text[prev_break] == ' ' or text[prev_break] == '\t')) prev_break + 1 else prev_break;
                }
                // If even a single word doesn't fit, just render it and advance.
                if (line_start == i and i < text.len) {
                    // single word longer than max_w — render anyway.
                    renderer.Renderer.drawText(text[line_start..i], x, line_y, title_font_size, color);
                    lines += 1;
                    line_y += title_line_h;
                    line_start = i + 1;
                }
            }
        }
    }
    // Final segment.
    if (line_start < text.len) {
        renderer.Renderer.drawText(text[line_start..], x, line_y, title_font_size, color);
        lines += 1;
    }
    return @max(1, lines);
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

    // Dynamic card height — matches computeCardHeight so the rendered
    // border/background covers all wrapped title lines (Issue 4).
    const dyn_card_h = computeCardHeight(step, steps, step_i, content_w);

    renderer.Renderer.drawRoundedRect(card_x, y, card_w, dyn_card_h, tokens.radius.md, border_color);
    renderer.Renderer.drawRoundedRect(card_x + 1, y + 1, card_w - 2, dyn_card_h - 2, tokens.radius.md - 1, card_bg);

    const is_propose = std.mem.eql(u8, step.kind, "propose");
    const is_write = std.mem.eql(u8, step.kind, "write_to_file");
    const is_replace = std.mem.eql(u8, step.kind, "replace_file_content");
    const is_multi_replace = std.mem.eql(u8, step.kind, "multi_replace_file_content");
    const should_connect = is_propose or is_write or is_replace or is_multi_replace;
    const connect_to_content = should_connect and step.expanded and step.content != null;

    if (connect_to_content) {
        renderer.Renderer.drawRect(card_x, y + dyn_card_h - 6, card_w, 6, border_color);
        renderer.Renderer.drawRect(card_x + 1, y + dyn_card_h - 6, card_w - 2, 6, card_bg);
    }

    // Draw the status dot (vertically centered in the dynamic card)
    const dot_y = y + (dyn_card_h - 6.0) / 2.0;
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

    const is_parent = step.child_count > 0 or step.is_thought or step.content != null;
    if (is_parent) {
        const icon = if (step.expanded) renderer.forge_icons.chevron_down else renderer.forge_icons.chevron_right;
        // Vertically center the chevron in the dynamic card.
        const chevron_y = y + (dyn_card_h - 16.0) / 2.0;
        renderer.Renderer.drawSvg(icon, card_x + card_w - 20, chevron_y, 16, 16, .{ .r = 0.5, .g = 0.5, .b = 0.55, .a = 1.0 });
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

    // Draw the title text — wraps onto multiple lines when too long.
    // The clip rect is now the full dynamic card height so wrapped
    // lines are not clipped (Issue 4).
    const title_fg = if (step.running)
        renderer.Color{ .r = 0.72, .g = 0.78, .b = 0.86, .a = 1.0 }
    else
        renderer.Color{ .r = 0.88, .g = 0.9, .b = 0.94, .a = 1.0 };

    const title_x = card_x + title_x_pad;
    const title_max_w = @max(0, card_w - title_x_pad - title_right_pad);

    renderer.Renderer.pushClipRect(title_x, y + title_v_pad, title_max_w, dyn_card_h - title_v_pad * 2);

    // Check if the title can be split (e.g. "Read file.ts") — short verb
    // gets the title color, the rest gets a muted color. We only split
    // when the verb is short (<15 chars) and the rest fits on one line;
    // otherwise we fall through to wrapped rendering.
    const space_idx = std.mem.indexOf(u8, title, " ");
    const full_w = renderer.Renderer.measureText(title, title_font_size);
    if (full_w <= title_max_w) {
        // Single-line fast path — try verb split for nicer styling.
        if (space_idx != null and space_idx.? < 15) {
            const verb = title[0..space_idx.?];
            const rest = title[space_idx.? + 1 ..];
            const title_y = y + (dyn_card_h - title_font_size) / 2.0;
            renderer.Renderer.drawText(verb, title_x, title_y, title_font_size, title_fg);
            const verb_w = renderer.Renderer.measureText(verb, title_font_size);
            renderer.Renderer.drawText(rest, title_x + verb_w + 4, title_y, title_font_size, .{ .r = 0.6, .g = 0.6, .b = 0.65, .a = 1.0 });
        } else {
            const title_y = y + (dyn_card_h - title_font_size) / 2.0;
            renderer.Renderer.drawText(title, title_x, title_y, title_font_size, title_fg);
        }
    } else {
        // Wrapped path — use drawWrappedTitle. Verb split is skipped
        // here because wrapping interferes with verb/rest coloring.
        // Vertically center the wrapped block.
        const line_count = estimateWrappedLines(title, title_max_w);
        const block_h = @as(f32, @floatFromInt(line_count)) * title_line_h;
        const start_y = y + (dyn_card_h - block_h) / 2.0;
        _ = drawWrappedTitle(title, title_x, start_y, title_max_w, title_fg);
    }
    renderer.Renderer.popClipRect();

    const current_card_gap = if (connect_to_content) 0.0 else card_gap;
    var content_y = y + dyn_card_h + current_card_gap;

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

    const is_parent = step.child_count > 0 or step.is_thought or step.content != null;
    if (!is_parent) return null;

    const dyn_card_h = computeCardHeight(step, steps, step_i, content_w);
    if (y >= content_y and y < content_y + dyn_card_h) return step_i;

    if (step.expanded and !step.is_thought) {
        var cy = content_y + dyn_card_h + card_gap;
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

//! Agent timeline view — Antigravity-style horizontal DAG visualization.
//!
//! Renders agent steps as horizontal nodes connected by arrows, showing the
//! flow of a multi-step agent run: prompt → tool_call → tool_result → next
//! tool_call → ... → final_answer. Each node displays:
//!   - Step number (1, 2, 3, ...)
//!   - Tool kind icon (search, read, write, run, etc.)
//!   - Status color (completed=green, running=pulse, failed=red, waiting=gray)
//!   - Optional tooltip with tool name + args preview
//!
//! This is the IDE equivalent of `forge agent events <session_id>` + the TUI's
//! `/timeline` command, but visualized as a horizontal DAG instead of a
//! vertical list. It reuses `agent_session.AgentStep` as the data source.
//!
//! Layout:
//!   [1]──[2]──[3]──[4]──[5]
//!    │    │    │    │    │
//!   read  search read write done
//!
//! Click a node to expand its detail (args + result summary). Keyboard nav:
//!   ←/→ = cycle nodes, Enter = expand, Esc = collapse, b = branch here.

const std = @import("std");
const renderer = @import("forge-renderer");
const agent_session = @import("../../agent/session.zig");
const tokens = @import("../tokens.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub const node_w: f32 = 48.0;
pub const node_h: f32 = 48.0;
pub const node_gap: f32 = 24.0;
pub const arrow_h: f32 = 2.0;
pub const label_h: f32 = 14.0;
pub const detail_h: f32 = 80.0;

pub const NodeStatus = enum {
    completed, // green
    running, // pulsing accent
    failed, // red
    waiting, // gray (not yet started)
};

/// Determine the status of a step for timeline coloring.
pub fn stepStatus(step: *const agent_session.AgentStep) NodeStatus {
    if (step.running) return .running;
    // Heuristic: if the step has content (result), it's completed.
    // If it has no content and isn't running, it's waiting.
    // Failed detection: we don't have an explicit failed flag in AgentStep,
    // so we check if the summary starts with "✗" or "Error".
    if (step.content != null) {
        if (std.mem.startsWith(u8, step.summary, "✗") or
            std.mem.startsWith(u8, step.summary, "Error") or
            std.mem.startsWith(u8, step.summary, "Failed"))
        {
            return .failed;
        }
        return .completed;
    }
    return .waiting;
}

pub fn statusColor(status: NodeStatus) renderer.Color {
    return switch (status) {
        .completed => tokens.color.success,
        .running => tokens.color.accent,
        .failed => tokens.color.danger,
        .waiting => tokens.color.text_muted,
    };
}

pub fn statusLabel(status: NodeStatus) []const u8 {
    return switch (status) {
        .completed => "done",
        .running => "running",
        .failed => "failed",
        .waiting => "waiting",
    };
}

/// Returns the screen-space rectangle for a timeline node at the given index.
pub fn nodeRect(timeline_x: f32, timeline_y: f32, index: usize) struct { x: f32, y: f32, w: f32, h: f32 } {
    const x = timeline_x + @as(f32, @floatFromInt(index)) * (node_w + node_gap);
    return .{
        .x = x,
        .y = timeline_y,
        .w = node_w,
        .h = node_h,
    };
}

/// Hit-test a click in the timeline. Returns the node index if hit, null otherwise.
pub fn hitTest(timeline_x: f32, timeline_y: f32, node_count: usize, click_x: f32, click_y: f32) ?usize {
    if (click_y < timeline_y or click_y > timeline_y + node_h + label_h) return null;
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const rect = nodeRect(timeline_x, timeline_y, i);
        if (click_x >= rect.x and click_x <= rect.x + rect.w) return i;
    }
    return null;
}

/// Draw the timeline. Renders `steps` as horizontal nodes with arrows between
/// them. `selected_index` is the currently focused node (drawn with a brighter
/// border). `anim_time` is used for the running-node pulse animation.
pub fn drawTimeline(
    wb: *Workbench,
    timeline_x: f32,
    timeline_y: f32,
    timeline_w: f32,
    steps: []agent_session.AgentStep,
    selected_index: ?usize,
    anim_time: f32,
) void {
    _ = timeline_w;
    _ = wb;

    // Header.
    renderer.Renderer.drawText("AGENT TIMELINE", timeline_x, timeline_y - 24, 11.0, tokens.color.text_muted);
    renderer.Renderer.drawText("Horizontal step flow · click to expand", timeline_x, timeline_y - 10, 10.0, tokens.color.text_muted);

    if (steps.len == 0) {
        renderer.Renderer.drawText("No steps yet — start an agent run", timeline_x, timeline_y + 8, 12.0, tokens.color.text_muted);
        return;
    }

    // Draw nodes + arrows.
    for (steps, 0..) |step, i| {
        const rect = nodeRect(timeline_x, timeline_y, i);
        const status = stepStatus(&step);
        const color = statusColor(status);

        // Arrow to next node (except after the last).
        if (i + 1 < steps.len) {
            const arrow_x = rect.x + rect.w;
            const arrow_y = rect.y + rect.h / 2.0 - arrow_h / 2.0;
            renderer.Renderer.drawRect(arrow_x, arrow_y, node_gap, arrow_h, tokens.color.border);
            // Arrowhead.
            renderer.Renderer.drawRect(arrow_x + node_gap - 4, arrow_y - 3, 4, arrow_h + 6, tokens.color.border);
        }

        // Node circle (rounded rect).
        const is_selected = (selected_index != null and selected_index.? == i);
        const border_color = if (is_selected) tokens.color.accent else tokens.color.border;
        const bg_color = if (is_selected) tokens.color.surface_raised else tokens.color.surface;

        renderer.Renderer.drawRoundedRect(rect.x, rect.y, rect.w, rect.h, 8, border_color);
        renderer.Renderer.drawRoundedRect(rect.x + 1, rect.y + 1, rect.w - 2, rect.h - 2, 7, bg_color);

        // Status dot in the center of the node.
        const dot_size: f32 = 12.0;
        const dot_x = rect.x + (rect.w - dot_size) / 2.0;
        const dot_y = rect.y + (rect.h - dot_size) / 2.0;
        if (status == .running) {
            const pulse = 0.5 + 0.4 * @sin(anim_time * 6.0);
            renderer.Renderer.drawRoundedRect(dot_x, dot_y, dot_size, dot_size, 6, .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
                .a = pulse,
            });
        } else {
            renderer.Renderer.drawRoundedRect(dot_x, dot_y, dot_size, dot_size, 6, color);
        }

        // Step number (top-left of node).
        var num_buf: [8]u8 = undefined;
        const num_text = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "?";
        renderer.Renderer.drawText(num_text, rect.x + 4, rect.y + 4, 9.0, tokens.color.text_muted);

        // Tool kind label (below node).
        const kind_label = toolKindLabel(step.kind);
        renderer.Renderer.drawText(kind_label, rect.x, rect.y + rect.h + 4, 10.0, tokens.color.text_muted);

        // Status label (below tool kind).
        const slabel = statusLabel(status);
        renderer.Renderer.drawText(slabel, rect.x, rect.y + rect.h + 16, 9.0, color);
    }

    // Draw detail panel for the selected node (if any).
    if (selected_index) |idx| {
        if (idx < steps.len) {
            const step = steps[idx];
            const detail_y = timeline_y + node_h + label_h + 24;
            const detail_w: f32 = 400.0;
            renderer.Renderer.drawRoundedRect(timeline_x, detail_y, detail_w, detail_h, 6, tokens.color.border);
            renderer.Renderer.drawRoundedRect(timeline_x + 1, detail_y + 1, detail_w - 2, detail_h - 2, 5, tokens.color.surface);

            // Detail header.
            var header_buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "Step {d}: {s}", .{ idx + 1, step.kind }) catch "Step";
            renderer.Renderer.drawText(header, timeline_x + 12, detail_y + 8, 12.0, tokens.color.text_primary);

            // Summary (truncated).
            const summary_max_w = detail_w - 24;
            const summary = truncateText(step.summary, summary_max_w, 11.0);
            renderer.Renderer.drawText(summary, timeline_x + 12, detail_y + 26, 11.0, tokens.color.text_muted);

            // Content preview (if expanded).
            if (step.content) |content| {
                const preview = truncateText(content, summary_max_w, 10.0);
                renderer.Renderer.drawText(preview, timeline_x + 12, detail_y + 44, 10.0, tokens.color.text_muted);
            } else {
                renderer.Renderer.drawText("(no content)", timeline_x + 12, detail_y + 44, 10.0, tokens.color.text_muted);
            }

            // Hint.
            renderer.Renderer.drawText("←/→ navigate · b branch · Esc collapse", timeline_x + 12, detail_y + detail_h - 16, 9.0, tokens.color.text_muted);
        }
    }
}

/// Map tool kind to a short label for the timeline.
fn toolKindLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "explore")) return "explore";
    if (std.mem.eql(u8, kind, "bash") or std.mem.eql(u8, kind, "run_command")) return "run";
    if (std.mem.eql(u8, kind, "mcp")) return "mcp";
    if (std.mem.eql(u8, kind, "web")) return "web";
    if (std.mem.eql(u8, kind, "remember")) return "note";
    if (std.mem.eql(u8, kind, "propose")) return "propose";
    if (std.mem.eql(u8, kind, "thought")) return "think";
    if (std.mem.eql(u8, kind, "read_file")) return "read";
    if (std.mem.eql(u8, kind, "search")) return "search";
    if (std.mem.eql(u8, kind, "write_to_file") or std.mem.eql(u8, kind, "replace_file_content")) return "write";
    return kind;
}

/// Truncate text to fit within `max_w` pixels at `font_size`, appending "…" if truncated.
fn truncateText(text: []const u8, max_w: f32, font_size: f32) []const u8 {
    if (text.len == 0) return text;
    const full_w = renderer.Renderer.measureText(text, font_size);
    if (full_w <= max_w) return text;
    // Binary search for the longest prefix that fits (leaving room for "…").
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        var buf: [512]u8 = undefined;
        if (mid + 1 > buf.len) {
            hi = mid - 1;
            continue;
        }
        @memcpy(buf[0..mid], text[0..mid]);
        buf[mid] = '~'; // approximate width of "…"
        const w = renderer.Renderer.measureText(buf[0 .. mid + 1], font_size);
        if (w <= max_w) lo = mid else hi = mid - 1;
    }
    return text[0..lo];
}

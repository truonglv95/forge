const std = @import("std");
const Buffer = @import("forge-editor").Buffer;
const Workbench = @import("../workbench.zig").Workbench;
const Point = @import("forge-editor").core.Point;

pub const ConflictBlock = struct {
    start_row: usize, // <<<<<<<
    mid_row: usize, // =======
    end_row: usize, // >>>>>>>
};

/// Finds all conflict blocks in the buffer and populates the out_blocks list.
pub fn findConflicts(allocator: std.mem.Allocator, buf: *Buffer, out_blocks: *std.ArrayListUnmanaged(ConflictBlock)) !void {
    out_blocks.clearRetainingCapacity();
    var current_start: ?usize = null;
    var current_mid: ?usize = null;

    for (0..buf.lines.items.len) |row| {
        const line = buf.lines.items[row].items;
        if (std.mem.startsWith(u8, line, "<<<<<<< ")) {
            current_start = row;
            current_mid = null;
        } else if (std.mem.startsWith(u8, line, "=======")) {
            if (current_start != null) {
                current_mid = row;
            }
        } else if (std.mem.startsWith(u8, line, ">>>>>>> ")) {
            if (current_start) |start| {
                if (current_mid) |mid| {
                    try out_blocks.append(allocator, .{
                        .start_row = start,
                        .mid_row = mid,
                        .end_row = row,
                    });
                }
            }
            current_start = null;
            current_mid = null;
        }
    }
}

fn deleteRows(buf: *Buffer, from_row: usize, to_row: usize) !void {
    if (from_row > to_row) return;
    buf.selection_anchor = .{ .row = from_row, .col = 0 };
    const next_row = to_row + 1;
    if (next_row >= buf.lines.items.len) {
        buf.cursor = .{ .row = buf.lines.items.len - 1, .col = buf.lines.items[buf.lines.items.len - 1].items.len };
    } else {
        buf.cursor = .{ .row = next_row, .col = 0 };
    }
    _ = try buf.deleteSelection();
}

pub fn resolveCurrent(buf: *Buffer, block: ConflictBlock) !void {
    try buf.beginUndoGroup();
    try deleteRows(buf, block.mid_row, block.end_row);
    try deleteRows(buf, block.start_row, block.start_row);
    try buf.endUndoGroup();
}

pub fn resolveIncoming(buf: *Buffer, block: ConflictBlock) !void {
    try buf.beginUndoGroup();
    try deleteRows(buf, block.end_row, block.end_row);
    try deleteRows(buf, block.start_row, block.mid_row);
    try buf.endUndoGroup();
}

pub fn resolveBoth(buf: *Buffer, block: ConflictBlock) !void {
    try buf.beginUndoGroup();
    try deleteRows(buf, block.end_row, block.end_row);
    try deleteRows(buf, block.mid_row, block.mid_row);
    try deleteRows(buf, block.start_row, block.start_row);
    try buf.endUndoGroup();
}

pub fn drawInlineActions(
    wb: *Workbench,
    block: ConflictBlock,
    editor_x: f32,
    gutter: f32,
    y: f32,
    mx_x: f32,
    mx_y: f32,
) void {
    const renderer = @import("forge-renderer");

    const bg_color = renderer.Color{ .r = 0.15, .g = 0.15, .b = 0.15, .a = 0.9 };
    const text_color = renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };
    const hover_color = renderer.Color{ .r = 0.3, .g = 0.4, .b = 0.8, .a = 1.0 };

    var current_x: f32 = editor_x + gutter + 10.0; // Draw on the left side, slightly offset

    // Quick helpers to draw buttons
    const actions = [_]struct { label: []const u8, cmd: @import("commands.zig").Command }{
        .{ .label = "Accept Current", .cmd = .{ .conflict_accept_current = block.start_row } },
        .{ .label = "Accept Incoming", .cmd = .{ .conflict_accept_incoming = block.start_row } },
        .{ .label = "Accept Both", .cmd = .{ .conflict_accept_both = block.start_row } },
    };

    for (actions) |action| {
        const text_w = renderer.Renderer.measureText(action.label, 11.0);
        const btn_w = text_w + 16;
        const is_hovered = mx_x >= current_x and mx_x < current_x + btn_w and mx_y >= y and mx_y < y + 20;

        renderer.Renderer.drawRoundedRect(current_x, y, btn_w, 20, 4, if (is_hovered) hover_color else bg_color);
        renderer.Renderer.drawText(action.label, current_x + 8, y + 4, 11.0, text_color);

        wb.conflict_action_rects.append(wb.allocator, .{
            .x = current_x,
            .y = y,
            .w = btn_w,
            .h = 20,
            .cmd = action.cmd,
        }) catch {};

        current_x += btn_w + 8;
    }
}

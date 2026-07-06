const std = @import("std");
const renderer = @import("forge-renderer");
const workspace = @import("forge-workspace");
const tabs_ui = @import("tabs.zig");
const scrollbar = @import("../core/scrollbar.zig");
const review_store = @import("../../agent/review_store.zig");
const agent_session = @import("../../agent/session.zig");
const diff_line_style = @import("../diff_line_style.zig");

pub const tab_label = "Proposal Review";
pub const file_col_w: f32 = 200;
pub const row_h: f32 = 22;
pub const diff_line_h: f32 = 13;
pub const hunk_header_h: f32 = 18;
pub const hunk_gap: f32 = 6;
pub const validation_chip_h: f32 = 22;
pub const validation_gap: f32 = 6;
pub const action_bar_h: f32 = 44;
pub const content_inset: f32 = 16;
pub const summary_h: f32 = 36;
pub const validation_section_h: f32 = 52;

pub const Hit = union(enum) {
    close_tab,
    select_file: usize,
    toggle_hunk: usize,
    apply,
    reject,
};

pub fn contentTop() f32 {
    return tabs_ui.tab_bar_top + tabs_ui.tab_bar_height;
}

pub fn viewportHeight(editor_h: f32) f32 {
    return @max(0, editor_h - tabs_ui.tab_bar_height - action_bar_h);
}

fn color(rgba: workspace.Rgba) renderer.Color {
    return .{ .r = rgba.r, .g = rgba.g, .b = rgba.b, .a = rgba.a };
}

pub fn tabLayout(editor_x: f32) struct { x: f32, w: f32, close_x: f32, close_y: f32 } {
    const w = tabs_ui.tabWidth(tab_label.len);
    const x = editor_x + tabs_ui.tab_padding_start;
    return .{
        .x = x,
        .w = w,
        .close_x = x + w - tabs_ui.close_button_width + 2,
        .close_y = tabs_ui.tab_y + 10,
    };
}

pub fn hitCloseTab(editor_x: f32, px: f32, py: f32) bool {
    const tab = tabLayout(editor_x);
    return px >= tab.close_x and px < tab.close_x + 16 and py >= tab.close_y and py < tab.close_y + 16;
}

pub const FileRow = struct {
    path: []const u8,
    accepted: usize,
    total: usize,
};

pub fn collectFiles(allocator: std.mem.Allocator, hunks: []review_store.Hunk) !std.ArrayList(FileRow) {
    var out: std.ArrayList(FileRow) = .empty;
    errdefer out.deinit(allocator);
    for (hunks) |hunk| {
        var found = false;
        for (out.items) |*row| {
            if (std.mem.eql(u8, row.path, hunk.path)) {
                row.total += 1;
                if (hunk.accepted) row.accepted += 1;
                found = true;
                break;
            }
        }
        if (!found) {
            try out.append(allocator, .{
                .path = hunk.path,
                .accepted = if (hunk.accepted) 1 else 0,
                .total = 1,
            });
        }
    }
    return out;
}

pub fn diffContentHeight(hunks: []review_store.Hunk, file_index: usize, files: []const FileRow) f32 {
    if (file_index >= files.len) return 0;
    const path = files[file_index].path;
    var h: f32 = content_inset;
    for (hunks) |hunk| {
        if (!std.mem.eql(u8, hunk.path, path)) continue;
        h += hunk_header_h + @as(f32, @floatFromInt(hunk.diff_lines.len)) * diff_line_h + hunk_gap;
    }
    return h + content_inset;
}

pub fn maxScrollY(editor_h: f32, hunks: []review_store.Hunk, file_index: usize, files: []const FileRow) f32 {
    return @max(0, diffContentHeight(hunks, file_index, files) - viewportHeight(editor_h) + summary_h + validation_section_h);
}

pub fn clampScrollY(scroll_y: f32, editor_h: f32, hunks: []review_store.Hunk, file_index: usize, files: []const FileRow) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(editor_h, hunks, file_index, files));
}

fn validationStatus(result: agent_session.ValidationResult) []const u8 {
    if (result.skipped) return "skip";
    if (result.exit_code == 0) return "ok";
    return "fail";
}

fn validationColor(result: agent_session.ValidationResult) renderer.Color {
    if (result.skipped) return .{ .r = 0.85, .g = 0.75, .b = 0.35, .a = 1.0 };
    if (result.exit_code == 0) return .{ .r = 0.45, .g = 0.85, .b = 0.55, .a = 1.0 };
    return .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 };
}

pub fn drawTab(
    editor_x: f32,
    accent: renderer.Color,
    editor_bg: renderer.Color,
    border: renderer.Color,
    text_primary: renderer.Color,
    ui_size: f32,
) void {
    const tab = tabLayout(editor_x);
    renderer.Renderer.drawRect(tab.x, tabs_ui.tab_y, tab.w, tabs_ui.tab_height + 1, editor_bg);
    renderer.Renderer.drawRect(tab.x, tabs_ui.tab_y, tab.w, 1, border);
    renderer.Renderer.drawRect(tab.x, tabs_ui.tab_y, 1, tabs_ui.tab_height, border);
    renderer.Renderer.drawRect(tab.x + tab.w - 1, tabs_ui.tab_y, 1, tabs_ui.tab_height, border);
    renderer.Renderer.drawRect(tab.x, tabs_ui.tab_y, 3, tabs_ui.tab_height, accent);
    var label_buf: [64:0]u8 = undefined;
    const n = @min(tab_label.len, label_buf.len - 1);
    @memcpy(label_buf[0..n], tab_label[0..n]);
    label_buf[n] = 0;
    renderer.Renderer.drawText(@ptrCast(&label_buf), tab.x + 12, tabs_ui.tab_y + 10, ui_size, text_primary);
    renderer.Renderer.drawText("x", tab.close_x, tab.close_y, ui_size, .{ .r = 0.65, .g = 0.68, .b = 0.72, .a = 1.0 });
}

pub fn draw(
    wb: *@import("../../workbench.zig").Workbench,
    editor_x: f32,
    editor_w: f32,
    editor_h: f32,
) void {
    const theme = &wb.theme;
    const top = contentTop();
    const view_h = viewportHeight(editor_h);
    const editor_bg = color(theme.colors.editor_bg);
    const border = color(theme.colors.border);
    const text_primary = color(theme.colors.text_primary);
    const text_muted = color(theme.colors.text_muted);
    const accent = color(theme.colors.accent);

    renderer.Renderer.drawRect(editor_x, top, editor_w, view_h, editor_bg);
    renderer.Renderer.drawRect(editor_x + file_col_w, top, 1, view_h, border);

    wb.agent.lock();
    const summary = wb.agent.summary;
    const hunks = wb.agent.review.hunks;
    const validation = wb.agent.validation_results.items;
    const file_index = wb.proposal_review_file_index;
    const scroll_y = wb.proposal_review_scroll_y;
    wb.agent.unlock();

    var files = collectFiles(wb.allocator, hunks) catch return;
    defer files.deinit(wb.allocator);

    // Summary
    var y = top + content_inset - scroll_y;
    renderer.Renderer.drawText("PROPOSAL REVIEW", editor_x + content_inset, y, 11.0, accent);
    y += 16;
    if (summary) |text| {
        var sum_buf: [512:0]u8 = undefined;
        const clipped = if (text.len > 511) text[0..511] else text;
        @memcpy(sum_buf[0..clipped.len], clipped);
        sum_buf[clipped.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&sum_buf), editor_x + content_inset, y, 12.0, text_primary);
    } else {
        renderer.Renderer.drawText("Review AI-proposed changes before applying.", editor_x + content_inset, y, 12.0, text_muted);
    }
    y += summary_h - 16;

    // Validation chips
    renderer.Renderer.drawText("Validation", editor_x + content_inset, y, 10.0, text_muted);
    y += 14;
    var chip_x = editor_x + content_inset;
    if (validation.len == 0) {
        renderer.Renderer.drawText("No validation tasks", chip_x, y + 4, 10.0, text_muted);
    } else {
        for (validation) |result| {
            var chip_buf: [160:0]u8 = undefined;
            const status = validationStatus(result);
            const line = std.fmt.bufPrint(&chip_buf, "{s} {s}", .{ status, result.task }) catch continue;
            chip_buf[line.len] = 0;
            const chip_w: f32 = @floatFromInt(line.len * 6 + 16);
            if (chip_x + chip_w > editor_x + editor_w - content_inset) break;
            renderer.Renderer.drawRoundedRect(chip_x, y, chip_w, validation_chip_h, 4, .{ .r = 0.14, .g = 0.16, .b = 0.2, .a = 1.0 });
            renderer.Renderer.drawText(@ptrCast(&chip_buf), chip_x + 8, y + 5, 10.0, validationColor(result));
            chip_x += chip_w + validation_gap;
        }
    }

    // File list (left column)
    var file_y = top + content_inset;
    renderer.Renderer.drawText("FILES", editor_x + content_inset, file_y, 10.0, text_muted);
    file_y += 16;
    for (files.items, 0..) |file, idx| {
        const selected = idx == file_index;
        if (selected) {
            renderer.Renderer.drawRoundedRect(editor_x + 8, file_y - 2, file_col_w - 16, row_h, 4, .{ .r = 0.18, .g = 0.28, .b = 0.42, .a = 1.0 });
        }
        var file_buf: [384:0]u8 = undefined;
        const marker = if (file.accepted == file.total) "[x]" else if (file.accepted > 0) "[~]" else "[ ]";
        const line = std.fmt.bufPrint(&file_buf, "{s} {s} ({d}/{d})", .{ marker, file.path, file.accepted, file.total }) catch file.path;
        file_buf[line.len] = 0;
        const fg = if (selected) text_primary else text_muted;
        renderer.Renderer.drawText(@ptrCast(&file_buf), editor_x + content_inset, file_y + 3, 10.0, fg);
        file_y += row_h;
    }

    // Diff pane (right)
    const diff_x = editor_x + file_col_w + content_inset;
    const diff_w = editor_w - file_col_w - content_inset * 2;
    var diff_y = top + summary_h + validation_section_h - scroll_y;

    if (file_index < files.items.len) {
        const path = files.items[file_index].path;
        var hunk_i: usize = 0;
        while (hunk_i < hunks.len) : (hunk_i += 1) {
            const hunk = hunks[hunk_i];
            if (!std.mem.eql(u8, hunk.path, path)) continue;
            if (diff_y > top + view_h) break;

            const accepted = hunk.accepted;
            const header_bg = if (accepted)
                renderer.Color{ .r = 0.14, .g = 0.22, .b = 0.16, .a = 1.0 }
            else
                renderer.Color{ .r = 0.2, .g = 0.14, .b = 0.14, .a = 1.0 };
            const block_h = hunk_header_h + @as(f32, @floatFromInt(hunk.diff_lines.len)) * diff_line_h;
            renderer.Renderer.drawRoundedRect(diff_x - 4, diff_y, diff_w + 8, block_h + 4, 4, header_bg);

            var header_buf: [384:0]u8 = undefined;
            const marker = if (accepted) "[x] " else "[ ] ";
            const header = std.fmt.bufPrint(&header_buf, "{s}{s}", .{ marker, hunk.label }) catch hunk.label;
            header_buf[header.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&header_buf), diff_x, diff_y + 2, 10.0, if (accepted) text_primary else text_muted);

            var line_y = diff_y + hunk_header_h;
            for (hunk.diff_lines) |line| {
                if (line_y > top + view_h) break;
                diff_line_style.drawLine(line, diff_x, line_y, diff_w, diff_line_h, 10.0, accepted, text_muted);
                line_y += diff_line_h;
            }
            diff_y += block_h + hunk_gap;
        }
    }

    // Action bar
    const bar_y = top + view_h;
    renderer.Renderer.drawRect(editor_x, bar_y, editor_w, action_bar_h, .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1.0 });
    renderer.Renderer.drawRect(editor_x, bar_y, editor_w, 1, border);

    wb.agent.lock();
    const accepted_count = wb.agent.review.acceptedCount();
    const total = wb.agent.review.hunks.len;
    wb.agent.unlock();

    const apply_x = editor_x + content_inset;
    const apply_y = bar_y + 8;
    renderer.Renderer.drawRoundedRect(apply_x, apply_y, 120, 28, 6, .{ .r = 0.2, .g = 0.55, .b = 0.35, .a = 1.0 });
    var apply_buf: [32:0]u8 = undefined;
    const apply_label = std.fmt.bufPrint(&apply_buf, "Apply ({d}/{d})", .{ accepted_count, total }) catch "Apply";
    apply_buf[apply_label.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&apply_buf), apply_x + 12, apply_y + 7, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    const reject_x = apply_x + 128;
    renderer.Renderer.drawRoundedRect(reject_x, apply_y, 100, 28, 6, .{ .r = 0.45, .g = 0.2, .b = 0.2, .a = 1.0 });
    renderer.Renderer.drawText("Reject all", reject_x + 14, apply_y + 7, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    renderer.Renderer.drawText("Click hunks or file rows to toggle acceptance", editor_x + 280, apply_y + 9, 10.0, text_muted);
}

pub fn actionBarHit(editor_x: f32, editor_h: f32, px: f32, py: f32) ?Hit {
    const top = contentTop();
    const bar_y = top + viewportHeight(editor_h);
    const apply_x = editor_x + content_inset;
    const apply_y = bar_y + 8;
    if (px >= apply_x and px < apply_x + 120 and py >= apply_y and py < apply_y + 28) return .apply;
    const reject_x = apply_x + 128;
    if (px >= reject_x and px < reject_x + 100 and py >= apply_y and py < apply_y + 28) return .reject;
    return null;
}

pub fn hitTest(
    allocator: std.mem.Allocator,
    editor_x: f32,
    editor_h: f32,
    scroll_y: f32,
    hunks: []review_store.Hunk,
    file_index: usize,
    px: f32,
    py: f32,
) !?Hit {
    if (py >= tabs_ui.tab_bar_top and py < contentTop() and hitCloseTab(editor_x, px, py)) {
        return .close_tab;
    }
    if (actionBarHit(editor_x, editor_h, px, py)) |action| return action;

    const top = contentTop();
    const view_h = viewportHeight(editor_h);

    if (px >= editor_x and px < editor_x + file_col_w and py >= top and py < top + view_h) {
        var files = try collectFiles(allocator, hunks);
        defer files.deinit(allocator);
        var file_y = top + content_inset + 16;
        for (files.items, 0..) |_, idx| {
            if (py >= file_y - 2 and py < file_y + row_h) return .{ .select_file = idx };
            file_y += row_h;
        }
        return null;
    }

    if (px < editor_x + file_col_w or py < top or py >= top + view_h) return null;
    var files = try collectFiles(allocator, hunks);
    defer files.deinit(allocator);
    if (file_index >= files.items.len) return null;

    const path = files.items[file_index].path;
    var diff_y = top + summary_h + validation_section_h - scroll_y;
    var hunk_i: usize = 0;
    while (hunk_i < hunks.len) : (hunk_i += 1) {
        const hunk = hunks[hunk_i];
        if (!std.mem.eql(u8, hunk.path, path)) continue;
        const block_h = hunk_header_h + @as(f32, @floatFromInt(hunk.diff_lines.len)) * diff_line_h;
        if (py >= diff_y and py < diff_y + block_h + hunk_gap) return .{ .toggle_hunk = hunk_i };
        diff_y += block_h + hunk_gap;
    }
    return null;
}

const std = @import("std");
const layout = @import("layout.zig");
const git_status = @import("../git/status.zig");

pub const list_top: f32 = 131;
pub const row_h: f32 = 28;

pub fn contentHeight(entry_count: usize) f32 {
    return @as(f32, @floatFromInt(entry_count)) * row_h + 8;
}

pub fn viewportHeight(window_h: f32) f32 {
    return @max(0, window_h - layout.status_height - list_top);
}

pub fn maxScrollY(entry_count: usize, window_h: f32) f32 {
    return @max(0, contentHeight(entry_count) - viewportHeight(window_h));
}

pub fn clampScrollY(scroll_y: f32, entry_count: usize, window_h: f32) f32 {
    return std.math.clamp(scroll_y, 0, maxScrollY(entry_count, window_h));
}

pub const Hit = union(enum) {
    refresh,
    commit,
    ai_generate,
    view_as_tree,
    more_actions,
    focus_commit_msg,
    toggle_staged_section,
    toggle_changes_section,
    toggle_file_staged: usize,
    open_file: usize,
};

pub fn hitTest(
    entries: []const git_status.Entry,
    staged_collapsed: bool,
    changes_collapsed: bool,
    panel_x: f32,
    panel_w: f32,
    click_x: f32,
    click_y: f32,
    scroll_y: f32,
) ?Hit {
    if (click_x < panel_x or click_x >= panel_x + panel_w) return null;

    const panel_y = layout.header_height + layout.activity_bar_height;
    if (click_y < panel_y) return null;

    const header_y = panel_y;
    // Check header actions
    if (click_y >= header_y and click_y < header_y + 30) {
        if (click_x >= panel_x + panel_w - 24) return .more_actions;
        if (click_x >= panel_x + panel_w - 48) return .refresh;
        if (click_x >= panel_x + panel_w - 72) return .commit;
        if (click_x >= panel_x + panel_w - 96) return .view_as_tree;
    }

    // Commit message input
    const input_y = header_y + 36 - scroll_y;
    if (click_y >= input_y and click_y < input_y + 32) {
        if (click_x >= panel_x + panel_w - 30) return .ai_generate;
        return .focus_commit_msg;
    }

    // Commit button
    const btn_y = input_y + 40;
    if (click_y >= btn_y and click_y < btn_y + 26) {
        return .commit;
    }

    var y = btn_y + 34;

    var staged_count: usize = 0;
    var changes_count: usize = 0;
    for (entries) |e| {
        if (e.isStaged()) staged_count += 1;
        if (e.isUnstaged()) changes_count += 1;
    }

    if (staged_count > 0) {
        if (click_y >= y and click_y < y + 24) return .toggle_staged_section;
        y += 24;
        if (!staged_collapsed) {
            for (entries, 0..) |e, i| {
                if (!e.isStaged()) continue;
                if (click_y >= y and click_y < y + 22) {
                    if (click_x >= panel_x + panel_w - 40 and click_x < panel_x + panel_w - 16) {
                        return .{ .toggle_file_staged = i };
                    }
                    return .{ .open_file = i };
                }
                y += 22;
            }
        }
    }

    if (changes_count > 0) {
        if (click_y >= y and click_y < y + 24) return .toggle_changes_section;
        y += 24;
        if (!changes_collapsed) {
            for (entries, 0..) |e, i| {
                if (!e.isUnstaged()) continue;
                if (click_y >= y and click_y < y + 22) {
                    if (click_x >= panel_x + panel_w - 40 and click_x < panel_x + panel_w - 16) {
                        return .{ .toggle_file_staged = i };
                    }
                    return .{ .open_file = i };
                }
                y += 22;
            }
        }
    }

    return null;
}

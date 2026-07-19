const std = @import("std");
const layout = @import("../core/layout.zig");
const git_status = @import("../../git/status.zig");

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
    switch_branch,
    refresh,
    push,
    pull,
    commit,
    ai_generate,
    view_as_tree,
    more_actions,
    focus_commit_msg,
    toggle_staged_section,
    toggle_changes_section,
    toggle_file_staged: usize,
    discard_file_changes: usize,
    open_file: struct { index: usize, is_staged: bool },
    stage_all,
    unstage_all,
    discard_all,
};

pub const HitResult = struct {
    action: Hit,
    is_icon: bool,
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
) ?HitResult {
    if (click_x < panel_x or click_x >= panel_x + panel_w) return null;

    const panel_y = layout.header_height + layout.activity_bar_height;
    if (click_y < panel_y) return null;

    const header_y = panel_y;
    // Check header actions
    if (click_y >= header_y and click_y < header_y + 30) {
        if (click_x >= panel_x + panel_w - 24) return .{ .action = .more_actions, .is_icon = true };
        if (click_x >= panel_x + panel_w - 48) return .{ .action = .push, .is_icon = true };
        if (click_x >= panel_x + panel_w - 72) return .{ .action = .pull, .is_icon = true };
        if (click_x >= panel_x + 8 and click_x < panel_x + 100) return .{ .action = .switch_branch, .is_icon = true };
        // Sync button is now at the left (we roughly estimate branch name width here since we can't measure text)
        if (click_x >= panel_x + 80 and click_x < panel_x + 160) return .{ .action = .refresh, .is_icon = true };
    }

    // Commit message input
    const input_y = header_y + 36 - scroll_y;
    if (click_y >= input_y and click_y < input_y + 32) {
        if (click_x >= panel_x + panel_w - 30) return .{ .action = .ai_generate, .is_icon = true };
        return .{ .action = .focus_commit_msg, .is_icon = false };
    }

    // Commit button
    const btn_y = input_y + 40;
    if (click_y >= btn_y and click_y < btn_y + 26) {
        return .{ .action = .commit, .is_icon = true };
    }

    var y = btn_y + 34;

    var staged_count: usize = 0;
    var changes_count: usize = 0;
    for (entries) |e| {
        if (e.isStaged()) staged_count += 1;
        if (e.isUnstaged()) changes_count += 1;
    }

    if (staged_count > 0) {
        if (click_y >= y and click_y < y + 24) {
            if (click_x >= panel_x + panel_w - 24) return .{ .action = .unstage_all, .is_icon = true };
            return .{ .action = .toggle_staged_section, .is_icon = true };
        }
        y += 24;
        if (!staged_collapsed) {
            for (entries, 0..) |e, i| {
                if (!e.isStaged()) continue;
                if (click_y >= y and click_y < y + 22) {
                    const sp: f32 = 14.0;
                    if (click_x >= panel_x + panel_w - 24 - sp) {
                        return .{ .action = .{ .toggle_file_staged = i }, .is_icon = true };
                    } else if (click_x >= panel_x + panel_w - 48 - sp) {
                        return .{ .action = .{ .open_file = .{ .index = i, .is_staged = true } }, .is_icon = true };
                    }
                    return .{ .action = .{ .open_file = .{ .index = i, .is_staged = true } }, .is_icon = true };
                }
                y += 22;
            }
        }
    }

    if (changes_count > 0) {
        if (click_y >= y and click_y < y + 24) {
            if (click_x >= panel_x + panel_w - 24) return .{ .action = .stage_all, .is_icon = true };
            if (click_x >= panel_x + panel_w - 48) return .{ .action = .discard_all, .is_icon = true };
            return .{ .action = .toggle_changes_section, .is_icon = true };
        }
        y += 24;
        if (!changes_collapsed) {
            for (entries, 0..) |e, i| {
                if (!e.isUnstaged()) continue;
                if (click_y >= y and click_y < y + 22) {
                    const sp: f32 = 14.0;
                    if (click_x >= panel_x + panel_w - 24 - sp) {
                        return .{ .action = .{ .toggle_file_staged = i }, .is_icon = true };
                    } else if (click_x >= panel_x + panel_w - 48 - sp) {
                        return .{ .action = .{ .discard_file_changes = i }, .is_icon = true };
                    } else if (click_x >= panel_x + panel_w - 72 - sp) {
                        return .{ .action = .{ .open_file = .{ .index = i, .is_staged = false } }, .is_icon = true };
                    }
                    return .{ .action = .{ .open_file = .{ .index = i, .is_staged = false } }, .is_icon = true };
                }
                y += 22;
            }
        }
    }

    return null;
}

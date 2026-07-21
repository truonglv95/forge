const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const git_panel = @import("../../sidebar/git_panel.zig");
const ui_text_style = renderer.TextStyle.prose;
const ui_strong_style = renderer.TextStyle.prose_semibold;

fn drawUiText(text: []const u8, x: f32, y: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.drawTextWithStyle(text, x, @round(y), size, c, ui_text_style);
}

fn drawStrongText(text: []const u8, x: f32, y: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.drawTextWithStyle(text, x, @round(y), size, c, ui_strong_style);
}

fn measureUiText(text: []const u8, size: f32) f32 {
    return renderer.Renderer.measureTextWithStyle(text, size, ui_text_style);
}

fn measureStrongText(text: []const u8, size: f32) f32 {
    return renderer.Renderer.measureTextWithStyle(text, size, ui_strong_style);
}

fn gitStatusGlyph(entry: *const @import("../../../git/status.zig").Entry) []const u8 {
    if (entry.status[0] == '?' or entry.status[1] == '?') return "U";
    if (entry.status[0] == 'A' or entry.status[1] == 'A') return "A";
    if (entry.status[0] == 'D' or entry.status[1] == 'D') return "D";
    if (entry.status[0] == 'R' or entry.status[1] == 'R') return "R";
    if (entry.status[0] == 'U' or entry.status[1] == 'U') return "!";
    return "M";
}

fn gitStatusColor(entry: *const @import("../../../git/status.zig").Entry) renderer.Color {
    if (entry.status[0] == 'A' or entry.status[1] == 'A' or entry.status[0] == '?' or entry.status[1] == '?') {
        return .{ .r = 0.47, .g = 0.72, .b = 0.52, .a = 1.0 };
    }
    if (entry.status[0] == 'D' or entry.status[1] == 'D') {
        return .{ .r = 0.9, .g = 0.36, .b = 0.34, .a = 1.0 };
    }
    if (entry.status[0] == 'U' or entry.status[1] == 'U') {
        return .{ .r = 0.95, .g = 0.55, .b = 0.35, .a = 1.0 };
    }
    return .{ .r = 0.78, .g = 0.68, .b = 0.52, .a = 1.0 };
}

fn drawGitEntryLabel(entry: *const @import("../../../git/status.zig").Entry, px: f32, py: f32, pw: f32, is_hovered: bool, is_staged_section: bool) void {
    const basename = std.fs.path.basename(entry.path);
    var dir_path: []const u8 = "";
    if (entry.path.len > basename.len) {
        dir_path = entry.path[0 .. entry.path.len - basename.len];
        if (dir_path.len > 0 and (dir_path[dir_path.len - 1] == '/' or dir_path[dir_path.len - 1] == '\\')) {
            dir_path = dir_path[0 .. dir_path.len - 1];
        }
    }

    const icon_color = if (std.mem.endsWith(u8, basename, ".zig"))
        renderer.Color{ .r = 0.98, .g = 0.45, .b = 0.16, .a = 1.0 }
    else
        renderer.Color{ .r = 0.66, .g = 0.68, .b = 0.72, .a = 1.0 };
    const name_color = renderer.Color{ .r = 0.9, .g = 0.91, .b = 0.93, .a = 1.0 };
    const path_color = renderer.Color{ .r = 0.58, .g = 0.59, .b = 0.64, .a = 1.0 };
    const status_color = gitStatusColor(entry);

    drawUiText("▰", px + 16, py + 2, 11.0, icon_color);

    const name_x = px + 30;

    var right_margin: f32 = 18; // Default margin for the status glyph
    if (is_hovered) {
        if (is_staged_section) {
            right_margin = 48; // Leftmost icon is at pw - 48
        } else {
            right_margin = 72; // Leftmost icon is at pw - 72
        }
    }
    const content_right = px + pw - right_margin;
    const name_max_w = @max(0, content_right - name_x - 8);
    renderer.Renderer.pushClipRect(name_x, py, name_max_w, 22);
    drawStrongText(basename, name_x, py + 2, 11.5, name_color);
    renderer.Renderer.popClipRect();

    const name_w = measureStrongText(basename, 11.5);
    const path_x = name_x + name_w + 7;
    const path_max_w = content_right - path_x - 8;
    if (dir_path.len > 0 and path_max_w > 12) {
        renderer.Renderer.pushClipRect(path_x, py, path_max_w, 22);
        drawUiText(dir_path, path_x, py + 3, 10.5, path_color);
        renderer.Renderer.popClipRect();
    }

    if (!is_hovered) {
        const status_x = px + pw - 18;
        const glyph = gitStatusGlyph(entry);
        drawStrongText(glyph, status_x, py + 2, 11.0, status_color);
    }
}

pub fn drawGitPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    const my = state.last_mouse_y;
    const mx = state.last_mouse_x;
    const is_hovering_panel = mx >= panel_x and mx < panel_x + panel_w;

    // Header
    const branch_name = if (wb.git.status) |s| s.branch orelse "HEAD" else "CHANGES";
    renderer.Renderer.drawSvg(renderer.icons.repo, panel_x + 8, panel_y + 8, 16, 16, icon_c);
    drawStrongText(branch_name, panel_x + 28, panel_y + 9, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const header_action_y = panel_y + 5;
    // Draw ahead/behind counts and sync button next to branch name
    const branch_name_w = measureStrongText(branch_name, 11.0);
    var sync_x = panel_x + 28 + branch_name_w + 10;

    if (wb.git.status) |status| {
        if (status.ahead > 0 or status.behind > 0) {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "↑{d} ↓{d}", .{ status.ahead, status.behind }) catch "";
            const text_w = measureUiText(text, 11.0);
            if (is_hovering_panel and my >= panel_y + 5 and my < panel_y + 25 and mx >= sync_x - 4 and mx < sync_x + text_w + 4) {
                renderer.Renderer.drawRoundedRect(sync_x - 4, panel_y + 5, text_w + 8, 20, 4, hover_c);
            }
            drawUiText(text, sync_x, panel_y + 9, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            sync_x += text_w + 10;
        }
    }

    // Right-aligned actions (More, Push, Pull)
    if (is_hovering_panel and my >= header_action_y and my < header_action_y + 20) {
        if (mx >= panel_x + panel_w - 24 and mx < panel_x + panel_w - 8) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 26, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + panel_w - 48 and mx < panel_x + panel_w - 32) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 50, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + panel_w - 72 and mx < panel_x + panel_w - 56) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 74, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + 8 and mx < panel_x + 28 + branch_name_w) {
            renderer.Renderer.drawRoundedRect(panel_x + 6, header_action_y, 24 + branch_name_w, 20, 4, hover_c);
        }
    }
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, panel_x + panel_w - 24, header_action_y + 3, 16, 16, icon_c);

    // Push button
    if (wb.git.push_running) {
        renderer.Renderer.drawSvgRotated(renderer.icons.chevron_up, panel_x + panel_w - 48, header_action_y + 3, 16, 16, wb.git.sync_icon_angle * std.math.pi / 180.0, icon_c);
    } else {
        renderer.Renderer.drawSvg(renderer.icons.chevron_up, panel_x + panel_w - 48, header_action_y + 3, 16, 16, icon_c);
    }

    // Pull button
    if (wb.git.pull_running) {
        renderer.Renderer.drawSvgRotated(renderer.icons.chevron_down, panel_x + panel_w - 72, header_action_y + 3, 16, 16, -wb.git.sync_icon_angle * std.math.pi / 180.0, icon_c);
    } else {
        renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + panel_w - 72, header_action_y + 3, 16, 16, icon_c);
    }

    const scroll_y_start = panel_y + 36;
    renderer.Renderer.setClipRect(panel_x, scroll_y_start, panel_w, h - scroll_y_start - layout.status_height);

    var y = scroll_y_start;
    y -= wb.git.scroll_y;

    // Input Box
    const input_h = 32.0;
    const is_input_focused = wb.focused_panel == .git;
    const input_bg = if (is_input_focused) renderer.Color{ .r = 0.15, .g = 0.15, .b = 0.18, .a = 1.0 } else renderer.Color{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 };
    const input_border = if (is_input_focused) renderer.Color{ .r = 0.3, .g = 0.4, .b = 0.6, .a = 1.0 } else renderer.Color{ .r = 0.2, .g = 0.2, .b = 0.25, .a = 1.0 };

    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, input_h, 4, input_border);
    renderer.Renderer.drawRoundedRect(panel_x + 9, y + 1, panel_w - 18, input_h - 2, 4, input_bg);

    var commit_msg_buf: [1024]u8 = undefined;
    const msg = wb.git.commit_msg.content() catch "";
    defer if (msg.len > 0) wb.allocator.free(msg);

    if (msg.len == 0) {
        drawUiText("Message (Cmd+Enter to commit)", panel_x + 16, y + 8, 12.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
    } else {
        const display_msg = if (msg.len > 120) msg[0..120] else msg;
        @memcpy(commit_msg_buf[0..display_msg.len], display_msg);
        commit_msg_buf[display_msg.len] = 0;
        drawUiText(@ptrCast(&commit_msg_buf), panel_x + 16, y + 8, 12.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }

    if (is_input_focused) {
        const cursor_x = panel_x + 16 + measureUiText(msg, 12.0);
        if (@mod(state.time, 1.0) < 0.5) {
            renderer.Renderer.drawRect(cursor_x, y + 8, 2, 14, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });
        }
    }

    renderer.Renderer.drawSvg(renderer.icons.sparkle, panel_x + panel_w - 28, y + 8, 16, 16, icon_c);

    y += 40;

    // Commit Button
    const btn_bg = renderer.Color{ .r = 0.25, .g = 0.45, .b = 0.65, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, 26, 4, btn_bg);
    renderer.Renderer.drawSvg(renderer.icons.check, panel_x + panel_w / 2 - 30, y + 5, 16, 16, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
    drawStrongText("Commit", panel_x + panel_w / 2 - 16, y + 5, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    y += 34;

    if (wb.git.status) |status| {
        if (!status.is_repo) {
            drawUiText("Not a git repository.", panel_x + 16, y, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        } else if (status.entries.len == 0) {
            drawUiText("Working tree clean.", panel_x + 16, y, 12.0, .{ .r = 0.6, .g = 0.8, .b = 0.6, .a = 1.0 });
        } else {
            const staged_count: usize = status.staged_ptrs.len;
            const changes_count: usize = status.unstaged_ptrs.len;

            const drawSection = struct {
                fn draw(py: *f32, count: usize, title: [:0]const u8, is_collapsed: bool, ptrs: []const *const @import("../../../git/status.zig").Entry, is_staged_section: bool, px: f32, pw: f32, ch: f32, my_y: f32, mx_x: f32, hc: renderer.Color) void {
                    if (count == 0) return;

                    const is_header_hovered = mx_x >= px and mx_x < px + pw and my_y >= py.* and my_y < py.* + 24;
                    if (is_header_hovered) {
                        renderer.Renderer.drawRect(px, py.*, pw, 24, hc);
                    }

                    const svg = if (is_collapsed) renderer.icons.chevron_right else renderer.icons.chevron_down;
                    renderer.Renderer.drawSvg(svg, px + 8, py.* + 4, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
                    drawStrongText(title, px + 22, py.* + 5, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

                    var badge_buf: [16:0]u8 = undefined;
                    const badge_str = std.fmt.bufPrintZ(&badge_buf, "{d}", .{count}) catch "0";
                    const badge_w = @as(f32, @floatFromInt(badge_str.len)) * 6.5 + 8;

                    var actions_w: f32 = 0;
                    if (is_header_hovered) {
                        if (is_staged_section) {
                            actions_w = 24;
                            renderer.Renderer.drawSvg(renderer.icons.dash, px + pw - 24, py.* + 4, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                        } else {
                            actions_w = 48;
                            renderer.Renderer.drawSvg(renderer.icons.plus, px + pw - 24, py.* + 4, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                            renderer.Renderer.drawSvg(renderer.icons.reply, px + pw - 48, py.* + 4, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                        }
                    }

                    const badge_x = px + pw - badge_w - 12 - actions_w;
                    renderer.Renderer.drawRoundedRect(badge_x, py.* + 4, badge_w, 16, 8, .{ .r = 0.3, .g = 0.5, .b = 0.5, .a = 1.0 });
                    drawStrongText(badge_str, badge_x + 4, py.* + 5, 10.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

                    py.* += 24;

                    if (!is_collapsed) {
                        const row_h: f32 = 22.0;
                        const visible_top = 101.0; // panel_y (65) + 36
                        const visible_bottom = ch - layout.status_height;

                        // We compute which elements are within the visible bounds: [visible_top, visible_bottom]
                        // py.* starts at the first item's top.
                        const view_top = @max(0, visible_top - py.*);
                        const view_bottom = @max(0, visible_bottom - py.*);

                        const start_idx: usize = @min(ptrs.len, @as(usize, @intFromFloat(view_top / row_h)));
                        var end_idx = @min(ptrs.len, @as(usize, @intFromFloat(view_bottom / row_h)) + 2);
                        if (end_idx < start_idx) end_idx = start_idx;

                        // Increment py.* by the hidden rows we skipped above
                        py.* += @as(f32, @floatFromInt(start_idx)) * row_h;

                        for (ptrs[start_idx..end_idx]) |entry| {
                            if (py.* + row_h >= visible_top and py.* < visible_bottom) {
                                const is_hovered = mx_x >= px and mx_x < px + pw and my_y >= py.* and my_y < py.* + row_h;
                                if (is_hovered) {
                                    renderer.Renderer.drawRect(px, py.*, pw, row_h, hc);
                                    if (is_staged_section) {
                                        renderer.Renderer.drawSvg(renderer.icons.dash, px + pw - 24, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                        renderer.Renderer.drawSvg(renderer.icons.file, px + pw - 48, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                    } else {
                                        renderer.Renderer.drawSvg(renderer.icons.plus, px + pw - 24, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                        renderer.Renderer.drawSvg(renderer.icons.reply, px + pw - 48, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                        renderer.Renderer.drawSvg(renderer.icons.file, px + pw - 72, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                    }
                                }

                                drawGitEntryLabel(entry, px, py.*, pw, is_hovered, is_staged_section);
                            }
                            // If it's not visible at all, we don't draw anything (fast skip)
                            py.* += row_h;
                        }
                        // Add the space for rows after end_idx that we didn't iterate
                        if (end_idx < ptrs.len) {
                            py.* += @as(f32, @floatFromInt(ptrs.len - end_idx)) * row_h;
                        }
                    }
                }
            };

            drawSection.draw(&y, staged_count, "STAGED CHANGES", wb.git.staged_collapsed, status.staged_ptrs, true, panel_x, panel_w, h, my, mx, hover_c);
            drawSection.draw(&y, changes_count, "CHANGES", wb.git.changes_collapsed, status.unstaged_ptrs, false, panel_x, panel_w, h, my, mx, hover_c);
        }
    }

    renderer.Renderer.clearClipRect();

    // Calculate total height for scrollbar
    var total_entries: usize = 0;
    if (wb.git.status) |status| {
        if (status.is_repo) {
            var sc: usize = 0;
            var cc: usize = 0;
            for (status.entries) |e| {
                if (e.isStaged()) sc += 1;
                if (e.isUnstaged()) cc += 1;
            }
            if (sc > 0) total_entries += 1 + if (wb.git.staged_collapsed) 0 else sc;
            if (cc > 0) total_entries += 1 + if (wb.git.changes_collapsed) 0 else cc;
        }
    }
    // const total_h = 36 + 32 + 40 + 34 + @as(f32, @floatFromInt(total_entries)) * 24; // approx
    // Using git_panel.maxScrollY logic roughly:
    // ... we need to make maxScrollY reflect this total_h. Wait, maxScrollY depends on total_h!

    shared.drawSidebarScrollbar(panel_x, panel_w, layout.header_height + layout.activity_bar_height, h, wb.git.scroll_y, total_entries, 24);
}

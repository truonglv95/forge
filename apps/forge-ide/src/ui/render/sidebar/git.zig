const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const git_panel = @import("../../sidebar/git_panel.zig");
pub fn drawGitPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    const my = state.last_mouse_y;
    const mx = state.last_mouse_x;
    const is_hovering_panel = mx >= panel_x and mx < panel_x + panel_w;

    // Header CHANGES
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 8, 16, 16, icon_c);
    renderer.Renderer.drawText("CHANGES", panel_x + 22, panel_y + 9, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const header_action_y = panel_y + 5;
    // more, refresh, commit, tree
    if (is_hovering_panel and my >= header_action_y and my < header_action_y + 20) {
        if (mx >= panel_x + panel_w - 24 and mx < panel_x + panel_w - 8) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 26, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + panel_w - 48 and mx < panel_x + panel_w - 32) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 50, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + panel_w - 72 and mx < panel_x + panel_w - 56) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 74, header_action_y, 20, 20, 4, hover_c);
        } else if (mx >= panel_x + panel_w - 96 and mx < panel_x + panel_w - 80) {
            renderer.Renderer.drawRoundedRect(panel_x + panel_w - 98, header_action_y, 20, 20, 4, hover_c);
        }
    }
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, panel_x + panel_w - 24, header_action_y + 3, 16, 16, icon_c);
    renderer.Renderer.drawSvg(renderer.icons.sync, panel_x + panel_w - 48, header_action_y + 3, 16, 16, icon_c);
    renderer.Renderer.drawSvg(renderer.icons.check, panel_x + panel_w - 72, header_action_y + 3, 16, 16, icon_c);
    renderer.Renderer.drawSvg(renderer.icons.repo, panel_x + panel_w - 96, header_action_y + 3, 16, 16, icon_c);

    var y = panel_y + 36;
    y -= wb.git_scroll_y;

    // Input Box
    const input_h = 32.0;
    const is_input_focused = wb.focused_panel == .git;
    const input_bg = if (is_input_focused) renderer.Color{ .r = 0.15, .g = 0.15, .b = 0.18, .a = 1.0 } else renderer.Color{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 };
    const input_border = if (is_input_focused) renderer.Color{ .r = 0.3, .g = 0.4, .b = 0.6, .a = 1.0 } else renderer.Color{ .r = 0.2, .g = 0.2, .b = 0.25, .a = 1.0 };

    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, input_h, 4, input_border);
    renderer.Renderer.drawRoundedRect(panel_x + 9, y + 1, panel_w - 18, input_h - 2, 4, input_bg);

    var commit_msg_buf: [1024]u8 = undefined;
    const msg = wb.git_commit_msg.content() catch "";
    defer if (msg.len > 0) wb.allocator.free(msg);

    if (msg.len == 0) {
        renderer.Renderer.drawText("Message (Cmd+Enter to commit)", panel_x + 16, y + 8, 12.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
    } else {
        const display_msg = if (msg.len > 120) msg[0..120] else msg;
        @memcpy(commit_msg_buf[0..display_msg.len], display_msg);
        commit_msg_buf[display_msg.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&commit_msg_buf), panel_x + 16, y + 8, 12.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }

    if (is_input_focused) {
        const cursor_x = panel_x + 16 + renderer.Renderer.measureText(msg, 12.0);
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
    renderer.Renderer.drawText("Commit", panel_x + panel_w / 2 - 16, y + 5, 12.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    y += 34;

    if (wb.git_status) |status| {
        if (!status.is_repo) {
            renderer.Renderer.drawText("Not a git repository.", panel_x + 16, y, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        } else if (status.entries.len == 0) {
            renderer.Renderer.drawText("Working tree clean.", panel_x + 16, y, 12.0, .{ .r = 0.6, .g = 0.8, .b = 0.6, .a = 1.0 });
        } else {
            var staged_count: usize = 0;
            var changes_count: usize = 0;
            for (status.entries) |e| {
                if (e.isStaged()) staged_count += 1;
                if (e.isUnstaged()) changes_count += 1;
            }

            const drawSection = struct {
                fn draw(py: *f32, count: usize, title: [:0]const u8, is_collapsed: bool, entries: []const @import("../../../git/status.zig").Entry, is_staged_section: bool, px: f32, pw: f32, ch: f32, my_y: f32, mx_x: f32, hc: renderer.Color) void {
                    if (count == 0) return;

                    if (mx_x >= px and mx_x < px + pw and my_y >= py.* and my_y < py.* + 24) {
                        renderer.Renderer.drawRect(px, py.*, pw, 24, hc);
                    }

                    const svg = if (is_collapsed) renderer.icons.chevron_right else renderer.icons.chevron_down;
                    renderer.Renderer.drawSvg(svg, px + 8, py.* + 4, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
                    renderer.Renderer.drawText(title, px + 22, py.* + 5, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

                    var badge_buf: [16:0]u8 = undefined;
                    const badge_str = std.fmt.bufPrintZ(&badge_buf, "{d}", .{count}) catch "0";
                    const badge_w = @as(f32, @floatFromInt(badge_str.len)) * 6.5 + 8;
                    const badge_x = px + pw - badge_w - 12;
                    renderer.Renderer.drawRoundedRect(badge_x, py.* + 4, badge_w, 16, 8, .{ .r = 0.3, .g = 0.5, .b = 0.5, .a = 1.0 });
                    renderer.Renderer.drawText(badge_str, badge_x + 4, py.* + 5, 10.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

                    py.* += 24;

                    if (!is_collapsed) {
                        for (entries) |entry| {
                            if ((is_staged_section and !entry.isStaged()) or (!is_staged_section and !entry.isUnstaged())) continue;
                            if (py.* + 22 >= 65 and py.* < ch - layout.status_height) {
                                const is_hovered = mx_x >= px and mx_x < px + pw and my_y >= py.* and my_y < py.* + 22;
                                if (is_hovered) {
                                    renderer.Renderer.drawRect(px, py.*, pw, 22, hc);
                                    if (is_staged_section) {
                                        renderer.Renderer.drawSvg(renderer.icons.dash, px + pw - 34, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                    } else {
                                        renderer.Renderer.drawSvg(renderer.icons.plus, px + pw - 34, py.* + 3, 16, 16, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                                    }
                                }

                                const basename = std.fs.path.basename(entry.path);
                                var dir_path: []const u8 = "";
                                if (entry.path.len > basename.len) {
                                    dir_path = entry.path[0 .. entry.path.len - basename.len];
                                    if (dir_path.len > 0 and (dir_path[dir_path.len - 1] == '/' or dir_path[dir_path.len - 1] == '\\')) {
                                        dir_path = dir_path[0 .. dir_path.len - 1];
                                    }
                                }

                                var display_path_buf: [256:0]u8 = undefined;
                                var display_len: usize = basename.len;
                                @memcpy(display_path_buf[0..@min(display_len, 255)], basename[0..@min(display_len, 255)]);
                                if (dir_path.len > 0) {
                                    const combined = std.fmt.bufPrint(&display_path_buf, "{s} {s}", .{ basename, dir_path }) catch display_path_buf[0..display_len];
                                    display_len = combined.len;
                                }
                                display_path_buf[display_len] = 0;

                                const max_w = pw - 60;
                                while (display_len > 0 and renderer.Renderer.measureText(display_path_buf[0..display_len], 11.0) > max_w) {
                                    display_len -= 1;
                                    display_path_buf[display_len] = 0;
                                    if (display_len > 3) {
                                        display_path_buf[display_len - 1] = '.';
                                        display_path_buf[display_len - 2] = '.';
                                        display_path_buf[display_len - 3] = '.';
                                    }
                                }

                                renderer.Renderer.drawText("≡", px + 16, py.* + 2, 12.0, .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 1.0 });

                                const text_color = if (entry.status[0] == 'M' or entry.status[1] == 'M')
                                    renderer.Color{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 }
                                else if (entry.status[0] == 'A')
                                    renderer.Color{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 }
                                else if (entry.status[0] == '?')
                                    renderer.Color{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 }
                                else
                                    renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

                                renderer.Renderer.drawText(@ptrCast(&display_path_buf), px + 30, py.* + 2, 11.0, text_color);

                                if (entry.status[0] == 'M' or entry.status[1] == 'M') {
                                    renderer.Renderer.drawText("M", px + pw - 16, py.* + 2, 11.0, text_color);
                                } else if (entry.status[0] == 'A') {
                                    renderer.Renderer.drawText("A", px + pw - 16, py.* + 2, 11.0, text_color);
                                } else if (entry.status[0] == '?') {
                                    renderer.Renderer.drawText("U", px + pw - 16, py.* + 2, 11.0, text_color);
                                } else {
                                    renderer.Renderer.drawText("M", px + pw - 16, py.* + 2, 11.0, text_color);
                                }
                            }
                            py.* += 22;
                        }
                    }
                }
            }.draw;

            drawSection(&y, staged_count, "Staged Changes", wb.git_staged_collapsed, status.entries, true, panel_x, panel_w, h, my, mx, hover_c);
            drawSection(&y, changes_count, "Changes", wb.git_changes_collapsed, status.entries, false, panel_x, panel_w, h, my, mx, hover_c);
        }
    }

    renderer.Renderer.clearClipRect();

    // Calculate total height for scrollbar
    var total_entries: usize = 0;
    if (wb.git_status) |status| {
        if (status.is_repo) {
            var sc: usize = 0;
            var cc: usize = 0;
            for (status.entries) |e| {
                if (e.isStaged()) sc += 1;
                if (e.isUnstaged()) cc += 1;
            }
            if (sc > 0) total_entries += 1 + if (wb.git_staged_collapsed) 0 else sc;
            if (cc > 0) total_entries += 1 + if (wb.git_changes_collapsed) 0 else cc;
        }
    }
    // const total_h = 36 + 32 + 40 + 34 + @as(f32, @floatFromInt(total_entries)) * 24; // approx
    // Using git_panel.maxScrollY logic roughly:
    // ... we need to make maxScrollY reflect this total_h. Wait, maxScrollY depends on total_h!

    shared.drawSidebarScrollbar(panel_x, panel_w, layout.header_height + layout.activity_bar_height, h, wb.git_scroll_y, total_entries, 24);
}

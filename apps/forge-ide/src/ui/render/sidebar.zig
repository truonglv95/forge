const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../state.zig");
const layout = @import("../layout.zig");
const activity_bar = @import("../activity_bar.zig");
const sidebar_view = @import("../sidebar_view.zig");
const extensions_panel = @import("../extensions_panel.zig");
const search_panel = @import("../search_panel.zig");
const debug_panel = @import("../debug_panel.zig");
const explorer_scroll = @import("../explorer_scroll.zig");
const scrollbar = @import("../scrollbar.zig");
const agent_scope_picker_mod = @import("../../agent/scope_picker.zig");
const plugin = @import("forge-plugin");
const ai = @import("forge-ai");
const render_theme = @import("theme.zig");
const Workbench = @import("../../workbench.zig").Workbench;

fn c(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return render_theme.color(rgba);
}

fn drawSidebarScrollbar(
    panel_x: f32,
    panel_w: f32,
    list_top: f32,
    window_h: f32,
    scroll_y: f32,
    row_count: usize,
    row_h: f32,
) void {
    const metrics = scrollbar.sidebarMetrics(row_count, row_h, list_top, window_h, layout.status_height);
    const show = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, list_top, panel_w, metrics.viewport_h);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        list_top,
        metrics.viewport_h,
        scroll_y,
        metrics.max_scroll,
        metrics.content_h,
        metrics.viewport_h,
        show,
    );
}

pub fn drawActivityBar(wb: *Workbench, w: f32) void {
    const theme = &wb.theme;
    const accent = c(theme.colors.accent);

    // Draw bottom border for activity bar
    renderer.Renderer.drawRect(0, layout.header_height + layout.activity_bar_height - 1, w, 1, c(theme.colors.border));

    for (sidebar_view.all) |view| {
        const x = activity_bar.iconX(view);
        const y = layout.header_height;
        const selected = wb.sidebar_view == view;
        if (selected) {
            // Draw top highlight for selected horizontal tab
            renderer.Renderer.drawRect(x + 6, y, activity_bar.icon_w - 12, 2, accent);
        }
        const color = if (selected)
            renderer.Color{ .r = 1, .g = 1, .b = 1, .a = 1 }
        else
            renderer.Color{ .r = 0.65, .g = 0.65, .b = 0.65, .a = 1 };
        const center = activity_bar.iconCenter(view, w);

        const svg = switch (view) {
            .explorer => renderer.icons.file_directory,
            .search => renderer.icons.search,
            .git => renderer.icons.git_branch,
            .run => renderer.icons.gear,
            .extensions => renderer.icons.plus, // placeholder for extensions
            .ai => renderer.icons.sparkle,
        };
        renderer.Renderer.drawSvg(svg, center.x - 8, center.y - 8, 16, 16, color);
    }
}

pub fn drawSearchPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("SEARCH", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const query_y = search_panel.list_top - 32;
    renderer.Renderer.drawRoundedRect(panel_x + 12, query_y, panel_w - 24, search_panel.query_box_h, 4, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
    const show_cursor = @mod(state.time, 1.0) < 0.5;
    const query_str = wb.search_buffer.toDisplayString(show_cursor and wb.focused_panel == .search) catch return;
    defer state.gpa.free(query_str);
    renderer.Renderer.drawText(query_str, panel_x + 20, query_y + 6, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });

    renderer.Renderer.drawRoundedRect(panel_x + 12, query_y + 34, panel_w - 24, 18, 4, c(theme.colors.accent_soft));
    renderer.Renderer.drawText("Search workspace", panel_x + 20, query_y + 37, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

    var y = search_panel.list_top - wb.search_scroll_y + 28;
    if (wb.search_results) |results| {
        for (results.matches, 0..) |match, index| {
            if (y + search_panel.row_h >= 65 and y < h - layout.status_height) {
                renderer.Renderer.drawRect(panel_x, y, panel_w, search_panel.row_h - 4, c(theme.colors.selection));
                var path_buf: [160:0]u8 = undefined;
                @memcpy(path_buf[0..@min(match.path.len, path_buf.len - 1)], match.path[0..@min(match.path.len, path_buf.len - 1)]);
                path_buf[@min(match.path.len, path_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&path_buf), panel_x + 16, y + 2, 11.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                var preview_buf: [128:0]u8 = undefined;
                @memcpy(preview_buf[0..@min(match.preview.len, preview_buf.len - 1)], match.preview[0..@min(match.preview.len, preview_buf.len - 1)]);
                preview_buf[@min(match.preview.len, preview_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&preview_buf), panel_x + 16, y + 16, 10.0, .{ .r = 0.65, .g = 0.75, .b = 0.85, .a = 1.0 });
                _ = index;
            }
            y += search_panel.row_h;
        }
        if (results.matches.len == 0) {
            renderer.Renderer.drawText("No results.", panel_x + 16, search_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        }
    } else {
        renderer.Renderer.drawText("Enter query and click Search.", panel_x + 16, search_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    }
    renderer.Renderer.clearClipRect();
    const result_count = if (wb.search_results) |results| results.matches.len else 0;
    drawSidebarScrollbar(panel_x, panel_w, search_panel.list_top, h, wb.search_scroll_y, result_count, search_panel.row_h);
}

fn countLines(text: ?[]const u8) usize {
    const value = text orelse return 1;
    if (value.len == 0) return 1;
    var count: usize = 1;
    for (value) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

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
                fn draw(py: *f32, count: usize, title: [:0]const u8, is_collapsed: bool, entries: []const @import("../../git/status.zig").Entry, is_staged_section: bool, px: f32, pw: f32, ch: f32, my_y: f32, mx_x: f32, hc: renderer.Color) void {
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

    drawSidebarScrollbar(panel_x, panel_w, layout.header_height + layout.activity_bar_height, h, wb.git_scroll_y, total_entries, 24);
}

pub fn drawDebugPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const debug_active = wb.debug_lldb.isActive();
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("RUN AND DEBUG", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    var y = debug_panel.list_top - wb.run_scroll_y;
    if (y + 22 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, c(theme.colors.accent_soft));
        renderer.Renderer.drawText("Toggle breakpoint at cursor", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Clear all breakpoints", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 34;

    if (debug_active) {
        if (y + 14 >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawText("DEBUG CONTROLS", panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
        }
        y += 14;
        if (y + debug_panel.control_row_h >= 65 and y < h - layout.status_height) {
            const btn_w = (panel_w - 24) / @as(f32, @floatFromInt(debug_panel.controls.len));
            for (debug_panel.controls, 0..) |control, index| {
                const bx = panel_x + 12 + @as(f32, @floatFromInt(index)) * btn_w;
                renderer.Renderer.drawRoundedRect(bx, y, btn_w - 4, debug_panel.control_row_h - 4, 4, c(theme.colors.selection));
                renderer.Renderer.drawText(control.label, bx + 6, y + 4, 10.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
            }
        }
        y += debug_panel.controls_block_h;
    }

    if (y + 14 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawText("LAUNCH CONFIGURATIONS", panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
    }
    y += 18;
    for (debug_panel.default_launches) |launch| {
        if (y + debug_panel.launch_row_h >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, debug_panel.launch_row_h - 6, 4, c(theme.colors.selection));
            renderer.Renderer.drawText("▶", panel_x + 16, y + 6, 12.0, c(theme.colors.accent));
            renderer.Renderer.drawText(launch.label, panel_x + 32, y + 6, 11.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
        }
        y += debug_panel.launch_row_h;
    }
    y += 16;
    if (y + 14 >= 65 and y < h - layout.status_height) {
        var bp_hdr: [32:0]u8 = undefined;
        const hdr = std.fmt.bufPrint(&bp_hdr, "BREAKPOINTS ({d})", .{wb.breakpoints.items.items.len}) catch "BREAKPOINTS";
        bp_hdr[hdr.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&bp_hdr), panel_x + 16, y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
    }
    y += 18;
    for (wb.breakpoints.items.items) |bp| {
        if (y + debug_panel.row_h >= 65 and y < h - layout.status_height) {
            renderer.Renderer.drawRoundedRect(panel_x + 14, y + 4, 8, 8, 4, c(theme.colors.warning));
            var line_buf: [192:0]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}:{d}", .{ bp.path, bp.line + 1 }) catch bp.path;
            line_buf[line.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&line_buf), panel_x + 28, y + 2, 11.0, .{ .r = 0.88, .g = 0.88, .b = 0.88, .a = 1.0 });
        }
        y += debug_panel.row_h;
    }
    renderer.Renderer.clearClipRect();
    const bp_count = wb.breakpoints.items.items.len;
    const debug_viewport = debug_panel.viewportHeight(h);
    const debug_content = debug_panel.contentHeight(bp_count, debug_active);
    const debug_max = debug_panel.maxScrollY(bp_count, h, debug_active);
    const show_debug_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, debug_panel.list_top, panel_w, debug_viewport);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        debug_panel.list_top,
        debug_viewport,
        wb.run_scroll_y,
        debug_max,
        debug_content,
        debug_viewport,
        show_debug_scroll,
    );
}

pub fn drawExtensionsPanel(wb: *Workbench, panel_x: f32, panel_w: f32, h: f32) void {
    const theme = &wb.theme;
    const host = &wb.extension_host;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(panel_x, panel_y, panel_w, h - panel_y - layout.status_height);
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, panel_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText("EXTENSIONS", panel_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const filter_y = extensions_panel.list_top - 20;
    renderer.Renderer.drawRoundedRect(panel_x + 12, filter_y, panel_w - 24, 18, 4, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
    var filter_buf: [128:0]u8 = undefined;
    @memcpy(filter_buf[0..wb.extensions_filter_len], wb.extensionsFilterSlice());
    filter_buf[wb.extensions_filter_len] = 0;
    renderer.Renderer.drawText(@ptrCast(&filter_buf), panel_x + 20, filter_y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

    var y = extensions_panel.list_top - wb.extensions_scroll_y;
    const btn_w = (panel_w - 44) / 2;
    const filter = wb.extensionsFilterSlice();

    if (y + 22 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, btn_w, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Reload", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(panel_x + 16 + btn_w, y, btn_w, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Open ext/", panel_x + 24 + btn_w, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, panel_w - 24, 18, 4, .{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 });
        renderer.Renderer.drawText("Open .forge/extensions/", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += 22;
    if (y + 18 >= 65 and y < h - layout.status_height) {
        const installed_bg = if (wb.extensions_panel_mode == .installed)
            c(theme.colors.accent_soft)
        else
            renderer.Color{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 };
        const market_bg = if (wb.extensions_panel_mode == .marketplace)
            c(theme.colors.accent_soft)
        else
            renderer.Color{ .r = 0.22, .g = 0.25, .b = 0.3, .a = 1.0 };
        renderer.Renderer.drawRoundedRect(panel_x + 12, y, btn_w, 18, 4, installed_bg);
        renderer.Renderer.drawText("Installed", panel_x + 20, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        renderer.Renderer.drawRoundedRect(panel_x + 16 + btn_w, y, btn_w, 18, 4, market_bg);
        renderer.Renderer.drawText("Marketplace", panel_x + 24 + btn_w, y + 3, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    }
    y += extensions_panel.footer_h;

    if (wb.extensions_detail_index) |detail_index| {
        if (wb.marketplace_catalog) |catalog| {
            if (detail_index < catalog.entries.len) {
                const entry = catalog.entries[detail_index];
                if (y + 22 >= 65 and y < h - layout.status_height) {
                    renderer.Renderer.drawText("< Back", panel_x + 16, y + 4, 11.0, c(theme.colors.accent));
                }
                y += 24;
                var title_buf: [128:0]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}", .{ entry.name, entry.version }) catch entry.name;
                title_buf[title.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 13.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                y += 22;
                var id_buf: [128:0]u8 = undefined;
                @memcpy(id_buf[0..entry.id.len], entry.id);
                id_buf[entry.id.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&id_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.55, .g = 0.75, .b = 0.95, .a = 1.0 });
                y += 16;
                var publisher_buf: [128:0]u8 = undefined;
                const publisher_line = std.fmt.bufPrint(&publisher_buf, "Publisher: {s}", .{entry.publisher}) catch entry.publisher;
                publisher_buf[publisher_line.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&publisher_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                y += 18;
                var desc_buf: [256:0]u8 = undefined;
                @memcpy(desc_buf[0..@min(entry.description.len, desc_buf.len - 1)], entry.description);
                desc_buf[@min(entry.description.len, desc_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&desc_buf), panel_x + 16, y + 2, 10.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });
                y += 40;
                renderer.Renderer.drawRoundedRect(panel_x + 12, y + 40, panel_w - 24, 18, 4, c(theme.colors.accent_soft));
                renderer.Renderer.drawText("Install extension", panel_x + 20, y + 43, 11.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            }
        }
    } else if (wb.extensions_panel_mode == .installed) {
        for (host.extensions.items, 0..) |ext, index| {
            if (filter.len > 0 and !agent_scope_picker_mod.matchesQuery(filter, ext.name) and !agent_scope_picker_mod.matchesQuery(filter, ext.id)) continue;
            const block_h = extensions_panel.blockHeight(&ext);
            if (y + block_h >= 65 and y < h - layout.status_height) {
                const selected = wb.selected_extension_index == index;
                if (selected) {
                    renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, block_h - 4, 4, c(theme.colors.selection));
                }

                var title_buf: [128:0]u8 = undefined;
                const status = if (ext.active) "active" else "off";
                const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}  {s}", .{ ext.name, ext.version, status }) catch ext.name;
                title_buf[title.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });

                var id_buf: [128:0]u8 = undefined;
                @memcpy(id_buf[0..ext.id.len], ext.id);
                id_buf[ext.id.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&id_buf), panel_x + 16, y + 20, 10.0, .{ .r = 0.55, .g = 0.75, .b = 0.95, .a = 1.0 });

                var path_buf: [160:0]u8 = undefined;
                const path_label = if (std.mem.eql(u8, ext.root_path, "(builtin)"))
                    "(built-in)"
                else
                    ext.root_path;
                @memcpy(path_buf[0..path_label.len], path_label);
                path_buf[path_label.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&path_buf), panel_x + 16, y + 34, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });

                var cmd_y = y + extensions_panel.header_h;
                for (ext.commands.items) |cmd| {
                    var cmd_buf: [160:0]u8 = undefined;
                    const cmd_line = std.fmt.bufPrint(&cmd_buf, "> {s}", .{cmd.title}) catch cmd.title;
                    cmd_buf[cmd_line.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&cmd_buf), panel_x + 20, cmd_y, 10.0, .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 });
                    cmd_y += extensions_panel.cmd_row_h;
                }
                if (wb.canUninstallExtension(&ext)) {
                    renderer.Renderer.drawText("Uninstall", panel_x + 16, y + block_h - 20, 10.0, .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 });
                }
            }
            y += block_h;
        }

        if (host.extensions.items.len == 0) {
            renderer.Renderer.drawText("No extensions loaded.", panel_x + 16, extensions_panel.list_top + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            renderer.Renderer.drawText("Add forge.toml to extensions/", panel_x + 16, extensions_panel.list_top + 26, 10.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
        }
    } else if (wb.marketplace_catalog) |catalog| {
        for (catalog.entries, 0..) |entry, index| {
            if (filter.len > 0 and !agent_scope_picker_mod.matchesQuery(filter, entry.name) and !agent_scope_picker_mod.matchesQuery(filter, entry.id) and !agent_scope_picker_mod.matchesQuery(filter, entry.description)) continue;
            if (y + extensions_panel.marketplace_row_h >= 65 and y < h - layout.status_height) {
                renderer.Renderer.drawRoundedRect(panel_x + 8, y, panel_w - 16, extensions_panel.marketplace_row_h - 6, 4, c(theme.colors.selection));
                var title_buf: [128:0]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "{s}  v{s}", .{ entry.name, entry.version }) catch entry.name;
                title_buf[title.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&title_buf), panel_x + 16, y + 4, 12.0, .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 });
                var desc_buf: [192:0]u8 = undefined;
                @memcpy(desc_buf[0..@min(entry.description.len, desc_buf.len - 1)], entry.description);
                desc_buf[@min(entry.description.len, desc_buf.len - 1)] = 0;
                renderer.Renderer.drawText(@ptrCast(&desc_buf), panel_x + 16, y + 20, 10.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
                renderer.Renderer.drawText("Install", panel_x + 16, y + 36, 10.0, c(theme.colors.accent));
                renderer.Renderer.drawText("Details >", panel_x + panel_w - 80, y + 36, 10.0, .{ .r = 0.65, .g = 0.75, .b = 0.95, .a = 1.0 });
                _ = index;
            }
            y += extensions_panel.marketplace_row_h;
        }
        if (catalog.entries.len == 0) {
            renderer.Renderer.drawText("Catalog is empty.", panel_x + 16, y + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        }
    } else {
        renderer.Renderer.drawText("No catalog found.", panel_x + 16, y + 8, 11.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        renderer.Renderer.drawText("Add extensions/catalog.toml", panel_x + 16, y + 26, 10.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
    }

    renderer.Renderer.clearClipRect();
    const catalog_ptr: ?*const plugin.MarketplaceCatalog = if (wb.marketplace_catalog) |*catalog| catalog else null;
    const ext_content = extensions_panel.contentHeight(host, catalog_ptr, wb.extensions_panel_mode, filter, wb.extensions_detail_index);
    const ext_viewport = extensions_panel.viewportHeight(h);
    const ext_max = extensions_panel.maxScrollY(host, catalog_ptr, wb.extensions_panel_mode, h, filter, wb.extensions_detail_index);
    const show_ext_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, panel_x, extensions_panel.list_top, panel_w, ext_viewport);
    scrollbar.drawVertical(
        panel_x + panel_w - scrollbar.track_w - 2,
        extensions_panel.list_top,
        ext_viewport,
        wb.extensions_scroll_y,
        ext_max,
        ext_content,
        ext_viewport,
        show_ext_scroll,
    );
}

pub fn drawExplorerPanel(wb: *Workbench, explorer_x: f32, explorer_panel_width: f32, h: f32) void {
    const theme = &wb.theme;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(explorer_x, panel_y, explorer_panel_width, h - panel_y - layout.status_height);

    // Draw "v FORGE" header
    var ws_name_buf: [128:0]u8 = undefined;
    const basename = std.fs.path.basename(wb.workspace_path);
    var name_len: usize = 0;
    for (basename) |ch| {
        if (name_len >= ws_name_buf.len - 1) break;
        ws_name_buf[name_len] = std.ascii.toUpper(ch);
        name_len += 1;
    }
    ws_name_buf[name_len] = 0;

    // Draw chevron for workspace
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, explorer_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText(@ptrCast(&ws_name_buf), explorer_x + 22, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    var rx = explorer_x + explorer_panel_width - 24;
    const my = state.last_mouse_y;
    const mx = state.last_mouse_x;

    const action_y = panel_y + 6;
    const action_icon_y = panel_y + 9;

    if (mx >= rx and mx < rx + 16 and my >= action_y and my < action_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, action_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.chevron_down, rx, action_icon_y, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= action_y and my < action_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, action_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.sync, rx, action_icon_y, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= action_y and my < action_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, action_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.file_directory, rx, action_icon_y, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= action_y and my < action_y + 20) {
        renderer.Renderer.drawRoundedRect(rx - 2, action_y, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.file, rx, action_icon_y, 16, 16, icon_c);

    var visible: std.ArrayList(@import("../../explorer/tree.zig").VisibleEntry) = .empty;
    defer visible.deinit(state.gpa);
    wb.explorer.visibleRows(wb.activeFilePath(), &visible) catch {};

    var file_y: f32 = explorer_scroll.list_top - wb.explorer_scroll_y;
    const chevron_slot_w: f32 = 12;
    const label_gap: f32 = 8;
    for (visible.items, 0..) |row, row_index| {
        const indent = @as(f32, @floatFromInt(row.depth)) * 14.0;
        const label_x = explorer_x + 20 + indent + chevron_slot_w + label_gap;

        const row_h = explorer_scroll.row_height;
        if (file_y + row_h >= 65 and file_y < h - layout.status_height) {
            const hovered = state.explorer_hover_row == row_index and !row.selected and !row.active;

            // Full-width highlights
            if (hovered) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
            } else if (row.active) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, c(theme.colors.accent));
            } else if (row.selected) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, c(theme.colors.selection));
            }

            if (row.kind == .directory) {
                const chevron_color = if (row.selected or row.active)
                    renderer.Color{ .r = 0.89, .g = 0.89, .b = 0.89, .a = 1.0 }
                else
                    renderer.Color{ .r = 0.62, .g = 0.64, .b = 0.68, .a = 1.0 };
                renderer.Renderer.drawSvg(if (row.expanded) renderer.icons.chevron_down else renderer.icons.chevron_right, explorer_x + 20 + indent, file_y + 1, chevron_slot_w, row_h - 2, chevron_color);
            }

            if (wb.renaming and row.selected) {
                const rename_str = wb.rename_buffer.toDisplayString(true) catch "";
                defer state.gpa.free(rename_str);
                renderer.Renderer.drawRoundedRect(label_x - 4, file_y - 2, explorer_panel_width - 32, 18, 3, .{ .r = 0.2, .g = 0.25, .b = 0.35, .a = 1.0 });
                renderer.Renderer.drawText(rename_str, label_x, file_y, 13.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });
            } else {
                var label_buf: [512:0]u8 = undefined;
                const name = row.name;
                const max_name = @min(name.len, label_buf.len - 1);
                @memcpy(label_buf[0..max_name], name[0..max_name]);
                label_buf[max_name] = 0;

                // Determine color based on git status
                var is_modified = false;
                var is_added = false;
                var is_untracked = false;

                if (wb.git_status) |*status| {
                    if (std.mem.startsWith(u8, row.path, wb.workspace_path)) {
                        var rel_path = row.path[wb.workspace_path.len..];
                        if (rel_path.len > 0 and (rel_path[0] == '/' or rel_path[0] == '\\')) {
                            rel_path = rel_path[1..];
                        }

                        for (status.entries) |entry| {
                            if (std.mem.eql(u8, entry.path, rel_path)) {
                                if (entry.status[0] == 'M' or entry.status[1] == 'M') is_modified = true;
                                if (entry.status[0] == 'A') is_added = true;
                                if (entry.status[0] == '?') is_untracked = true;
                            } else if (row.kind == .directory and std.mem.startsWith(u8, entry.path, rel_path) and entry.path.len > rel_path.len and (entry.path[rel_path.len] == '/' or entry.path[rel_path.len] == '\\')) {
                                if (entry.status[0] == 'M' or entry.status[1] == 'M') is_modified = true;
                                if (entry.status[0] == 'A') is_added = true;
                                if (entry.status[0] == '?') is_untracked = true;
                            }
                        }
                    }
                }

                var color = if (row.active)
                    renderer.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }
                else if (row.selected)
                    renderer.Color{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 }
                else
                    renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

                if (!row.active and !row.selected) {
                    if (is_modified) {
                        color = .{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 };
                    } else if (is_added or is_untracked) {
                        color = .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 };
                    }
                }

                renderer.Renderer.drawText(@ptrCast(&label_buf), label_x, file_y, 13.0, color);

                // Draw git status indicator on the far right
                if (row.kind == .file) {
                    if (is_modified) {
                        renderer.Renderer.drawText("M", explorer_x + explorer_panel_width - 16, file_y + 1, 11.0, .{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 });
                    } else if (is_added) {
                        renderer.Renderer.drawText("A", explorer_x + explorer_panel_width - 16, file_y + 1, 11.0, .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 });
                    } else if (is_untracked) {
                        renderer.Renderer.drawText("U", explorer_x + explorer_panel_width - 16, file_y + 1, 11.0, .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 });
                    }
                } else if (row.kind == .directory) {
                    if (is_modified) {
                        renderer.Renderer.drawRect(explorer_x + explorer_panel_width - 12, file_y + 8, 4, 4, .{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 });
                    } else if (is_added or is_untracked) {
                        renderer.Renderer.drawRect(explorer_x + explorer_panel_width - 12, file_y + 8, 4, 4, .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 });
                    }
                }
            }
        }
        file_y += row_h;
    }
    renderer.Renderer.clearClipRect();
    drawSidebarScrollbar(explorer_x, explorer_panel_width, explorer_scroll.list_top, h, wb.explorer_scroll_y, visible.items.len, explorer_scroll.row_height);
}

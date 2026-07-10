const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const shared = @import("shared.zig");

const explorer_scroll = @import("../../sidebar/explorer_scroll.zig");
pub fn drawExplorerPanel(wb: *Workbench, explorer_x: f32, explorer_panel_width: f32, h: f32) void {
    const theme = &wb.theme;
    const panel_y = layout.header_height + layout.activity_bar_height;
    renderer.Renderer.setClipRect(explorer_x, panel_y, explorer_panel_width, h - panel_y - layout.status_height);

    // Draw "v FORGE" header
    var ws_name_buf: [128:0]u8 = undefined;
    const basename = wb.workspace_name;
    var name_len: usize = 0;
    for (basename) |ch| {
        if (name_len >= ws_name_buf.len - 1) break;
        ws_name_buf[name_len] = std.ascii.toUpper(ch);
        name_len += 1;
    }
    ws_name_buf[name_len] = 0;

    // Draw chevron for workspace
    const chevron = if (wb.explorer_root_expanded) renderer.icons.chevron_down else renderer.icons.chevron_right;
    renderer.Renderer.drawSvg(chevron, explorer_x + 8, panel_y + 14, 16, 16, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
    renderer.Renderer.drawText(ws_name_buf[0..name_len], explorer_x + 28, panel_y + 15, 11.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

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

    if (!wb.explorer_root_expanded) {
        renderer.Renderer.clearClipRect();
        return;
    }

    const active_path = wb.activeFilePath();
    const row_h = explorer_scroll.row_height;
    const start_idx: usize = if (wb.explorer_scroll_y > 0) @as(usize, @intFromFloat(wb.explorer_scroll_y / row_h)) else 0;
    const visual_count: usize = @as(usize, @intFromFloat((h - 65 - layout.status_height) / row_h)) + 2;
    const end_idx = @min(wb.explorer.entries.len, start_idx + visual_count);

    var file_y: f32 = explorer_scroll.list_top - wb.explorer_scroll_y + @as(f32, @floatFromInt(start_idx)) * row_h;
    for (wb.explorer.entries[start_idx..end_idx], start_idx..) |row, row_index| {
        const row_selected = if (wb.explorer.selected_path) |sel| std.mem.eql(u8, sel, row.path) else false;
        const row_active = if (active_path) |act| std.mem.eql(u8, act, row.path) else false;
        const row_expanded = row.kind == .directory and wb.explorer.expanded_paths.contains(row.path);

        const indent = @as(f32, @floatFromInt(row.depth)) * 14.0;
        const base_x = explorer_x + 20 + indent;
        const icon_w: f32 = 14.0;
        const label_x = base_x + icon_w + 6.0;

        if (file_y + row_h >= 65 and file_y < h - layout.status_height) {
            const hovered = state.explorer_hover_row == row_index and !row_selected and !row_active;

            // Full-width highlights
            if (hovered) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, .{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 });
            } else if (row_active) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, shared.color(theme.colors.accent));
            } else if (row_selected) {
                renderer.Renderer.drawRect(explorer_x, file_y, explorer_panel_width, row_h, shared.color(theme.colors.selection));
            }

            if (row.kind == .directory) {
                const chevron_color = if (row_selected or row_active)
                    renderer.Color{ .r = 0.89, .g = 0.89, .b = 0.89, .a = 1.0 }
                else
                    renderer.Color{ .r = 0.62, .g = 0.64, .b = 0.68, .a = 1.0 };
                renderer.Renderer.drawSvg(if (row_expanded) renderer.icons.chevron_down else renderer.icons.chevron_right, base_x, file_y + 1, icon_w, row_h - 2, chevron_color);
            } else {
                const res = @import("../icon_resolver.zig").resolveIcon(row.name);
                renderer.Renderer.drawSvg(res.svg, base_x, file_y + 3, icon_w, icon_w, res.color);
            }

            if (wb.renaming and row_selected) {
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

                var color = if (row_active)
                    renderer.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }
                else if (row_selected)
                    renderer.Color{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 }
                else
                    renderer.Color{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 };

                if (!row_active and !row_selected) {
                    if (is_modified) {
                        color = .{ .r = 0.8, .g = 0.65, .b = 0.45, .a = 1.0 };
                    } else if (is_added or is_untracked) {
                        color = .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 };
                    }
                }

                renderer.Renderer.drawText(label_buf[0..max_name], label_x, file_y, 13.0, color);

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
    shared.drawSidebarScrollbar(explorer_x, explorer_panel_width, explorer_scroll.list_top, h, wb.explorer_scroll_y, wb.explorer.entries.len, explorer_scroll.row_height);
}

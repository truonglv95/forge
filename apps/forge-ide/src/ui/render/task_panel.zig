const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../core/state.zig");
const panel_scroll = @import("../core/panel_scroll.zig");
const scrollbar = @import("../core/scrollbar.zig");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn drawTaskPanel(wb: *Workbench, editor_x: f32, editor_w: f32, panel_y: f32, panel_h: f32) void {
    const bottom_panel = @import("../panel/bottom_panel.zig");
    renderer.Renderer.setClipRect(editor_x, panel_y, editor_w, panel_h);
    const tab_y = bottom_panel.tabBarTop(panel_y);
    for (bottom_panel.tabs) |tab| {
        const selected = wb.bottom_panel_mode == tab.mode;
        const tab_x = editor_x + tab.x_offset;

        var label_buf: [32:0]u8 = undefined;
        if (tab.mode == .problems and wb.diagnostics.list.items.len > 0) {
            const prob = std.fmt.bufPrint(&label_buf, "{s} {d}", .{ tab.label, wb.diagnostics.list.items.len }) catch tab.label;
            label_buf[prob.len] = 0;
        } else {
            @memcpy(label_buf[0..tab.label.len], tab.label);
            label_buf[tab.label.len] = 0;
        }

        const text_color = if (selected)
            renderer.Color{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 }
        else
            renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };

        renderer.Renderer.drawText(@ptrCast(&label_buf), tab_x, tab_y + 3, 11.0, text_color);

        if (selected) {
            renderer.Renderer.drawRect(tab_x, tab_y + bottom_panel.tab_h + 2, tab.w - 8, 1.0, text_color);
        }
    }

    if (wb.bottom_panel_mode == .terminal) {
        const rx = editor_x + editor_w;
        const icon_y = tab_y + 3;
        const icon_color = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };

        renderer.Renderer.drawSvg(renderer.icons.x, rx - 24, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.chevron_up, rx - 44, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, rx - 64, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.trash, rx - 88, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.split, rx - 112, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.chevron_down, rx - 136, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.plus, rx - 156, icon_y, 16, 16, icon_color);
        renderer.Renderer.drawText("zsh", rx - 188, icon_y + 3, 11.0, icon_color);
        renderer.Renderer.drawSvg(renderer.icons.terminal, rx - 208, icon_y, 16, 16, icon_color);
    }

    switch (wb.bottom_panel_mode) {
        .output => {
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            if (wb.rename_preview.active) {
                renderer.Renderer.drawText("Rename preview — Enter=Accept  Esc=Reject", editor_x + 20, line_y, 12.0, .{ .r = 0.95, .g = 0.85, .b = 0.45, .a = 1.0 });
                line_y += 14.0;
                for (wb.rename_preview.lines) |item| {
                    var buf: [512:0]u8 = undefined;
                    const clipped = if (item.label.len > 511) item.label[0..511] else item.label;
                    @memcpy(buf[0..clipped.len], clipped);
                    buf[clipped.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.85, .g = 0.95, .b = 0.75, .a = 1.0 });
                    line_y += 14.0;
                }
            } else if (wb.references.active) {
                for (wb.references.items) |item| {
                    var buf: [512:0]u8 = undefined;
                    const clipped = if (item.label.len > 511) item.label[0..511] else item.label;
                    @memcpy(buf[0..clipped.len], clipped);
                    buf[clipped.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.75, .g = 0.85, .b = 1.0, .a = 1.0 });
                    line_y += 14.0;
                }
            } else {
                const task_state = wb.task_output.snapshotState();
                wb.task_output.lock();
                defer wb.task_output.unlock();
                for (wb.task_output.lines.items) |line| {
                    var buf: [512:0]u8 = undefined;
                    const clipped = if (line.len > 511) line[0..511] else line;
                    @memcpy(buf[0..clipped.len], clipped);
                    buf[clipped.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 });
                    line_y += 14.0;
                }
                if (task_state.last_exit_code) |code| {
                    var exit_buf: [64:0]u8 = undefined;
                    const exit_msg = std.fmt.bufPrint(&exit_buf, "exit code: {d}", .{code}) catch "";
                    exit_buf[exit_msg.len] = 0;
                    renderer.Renderer.drawText(@ptrCast(&exit_buf), editor_x + 20, panel_y + panel_h - 26, 12.0, .{ .r = 0.6, .g = 0.8, .b = 0.6, .a = 1.0 });
                }
            }
        },
        .problems => {
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            for (wb.diagnostics.list.items) |item| {
                var buf: [512:0]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "L{d}:{d}  {s}", .{ item.line + 1, item.character + 1, item.message }) catch item.message;
                buf[line.len] = 0;
                const color = switch (item.severity) {
                    .err => renderer.Color{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 },
                    .warning => renderer.Color{ .r = 1.0, .g = 0.75, .b = 0.35, .a = 1.0 },
                    else => renderer.Color{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1.0 },
                };
                renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, color);
                line_y += 14.0;
            }
            if (wb.diagnostics.list.items.len == 0) {
                renderer.Renderer.drawText("No problems for active file.", editor_x + 20, panel_y + 40, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            }
        },
        .terminal => {
            const terminal_panel = @import("../panel/terminal_panel.zig");
            const terminal = wb.activeTerminal();
            terminal.lock();
            defer terminal.unlock();

            const content_top = terminal_panel.contentTop(panel_y);
            const content_h = panel_h - (content_top - panel_y);
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            const git_ptr: ?*const @import("../../git/status.zig").Status = if (wb.git_status) |*status| status else null;
            const show_cursor = @mod(state.time, 1.0) < 0.5;
            const show_terminal_cursor = show_cursor and wb.focused_panel == .terminal;

            if (wb.terminal_selection) |sel| {
                terminal_panel.drawSelection(editor_x, panel_y, wb.task_scroll_y, terminal.lines.items, sel);
            }
            var line_y = content_top - wb.task_scroll_y;
            for (terminal.lines.items) |line| {
                if (line_y + terminal_panel.line_h >= content_top and line_y < content_top + content_h) {
                    terminal_panel.drawStyledLine(editor_x, editor_w, line_y, line, wb.workspace_path, git_ptr);
                }
                line_y += terminal_panel.line_h;
            }
            if (terminal.local_input != null or terminal.isActive()) {
                if (line_y + terminal_panel.line_h >= content_top and line_y < content_top + content_h) {
                    var active_buf: [512]u8 = undefined;
                    const active = terminal.activeLine(&active_buf);
                    terminal_panel.drawStyledLine(editor_x, editor_w, line_y, active, wb.workspace_path, git_ptr);
                    const col = active.len;
                    terminal_panel.drawInputCursor(editor_x, line_y, active, col, show_terminal_cursor);
                }
            } else if (terminal.lines.items.len == 0) {
                const hint = if (terminal.isActive())
                    "Shell running — type here."
                else if (terminal.exited)
                    "Shell exited — click TERMINAL tab to restart."
                else
                    "Starting terminal…";
                renderer.Renderer.drawText(hint, editor_x + 20, content_top + 8, 12.0, .{ .r = 0.50, .g = 0.58, .b = 0.68, .a = 1.0 });
            }
        },
        .debug_console => {
            wb.debug_console.lock();
            defer wb.debug_console.unlock();
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            for (wb.debug_console.lines.items) |line| {
                var buf: [512:0]u8 = undefined;
                const clipped = if (line.len > 511) line[0..511] else line;
                @memcpy(buf[0..clipped.len], clipped);
                buf[clipped.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.75, .g = 0.85, .b = 1.0, .a = 1.0 });
                line_y += 14.0;
            }
            if (wb.debug_console.lines.items.len == 0) {
                renderer.Renderer.drawText("Debug console ready.", editor_x + 20, panel_y + 40, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            }
        },
        .debug_variables => {
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            if (line_y + 14 >= content_top and line_y < content_top + content_h) {
                renderer.Renderer.drawText("LOCAL VARIABLES", editor_x + 20, line_y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
            }
            line_y += 16;
            for (wb.debug_variables.items.items) |entry| {
                if (line_y + 14 < content_top or line_y >= content_top + content_h) {
                    line_y += 14;
                    continue;
                }
                var buf: [512:0]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s} ({s}) = {s}", .{ entry.name, entry.type_name, entry.value }) catch entry.name;
                buf[label.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.85, .g = 0.92, .b = 0.75, .a = 1.0 });
                line_y += 14;
            }
            if (wb.debug_variables.items.items.len == 0) {
                renderer.Renderer.drawText("No variables — start debug session and step.", editor_x + 20, panel_y + 40, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            } else if (wb.task_scroll_y < 1) {
                renderer.Renderer.drawText("Click a variable to copy its value.", editor_x + 20, panel_y + panel_h - 18, 11.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
            }
        },
        .debug_callstack => {
            const content_top = panel_y + 34.0;
            const content_h = panel_h - 34.0;
            renderer.Renderer.setClipRect(editor_x, content_top, editor_w, content_h);
            var line_y = content_top - wb.task_scroll_y;
            if (line_y + 14 >= content_top and line_y < content_top + content_h) {
                renderer.Renderer.drawText("CALL STACK", editor_x + 20, line_y, 10.0, .{ .r = 0.55, .g = 0.55, .b = 0.55, .a = 1.0 });
            }
            line_y += 16;
            for (wb.debug_callstack.items.items) |frame| {
                if (line_y + 14 < content_top or line_y >= content_top + content_h) {
                    line_y += 14;
                    continue;
                }
                var buf: [512:0]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "#{d} {s} — {s}:{d}", .{ frame.index, frame.label, frame.path, frame.line + 1 }) catch frame.label;
                buf[label.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&buf), editor_x + 20, line_y, 12.0, .{ .r = 0.75, .g = 0.85, .b = 1.0, .a = 1.0 });
                line_y += 14;
            }
            if (wb.debug_callstack.items.items.len == 0) {
                renderer.Renderer.drawText("No stack frames — start debug session and step.", editor_x + 20, panel_y + 40, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            } else if (wb.task_scroll_y < 1) {
                renderer.Renderer.drawText("Click a frame to jump to source.", editor_x + 20, panel_y + panel_h - 18, 11.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });
            }
        },
    }
    renderer.Renderer.clearClipRect();
    const bottom_content_top = if (wb.bottom_panel_mode == .terminal)
        @import("../panel/terminal_panel.zig").contentTop(panel_y)
    else
        panel_y + 34.0;
    const bottom_content_h = panel_h - (bottom_content_top - panel_y);
    const bottom_line_count = wb.bottomPanelLineCount();
    const bottom_line_h = if (wb.bottom_panel_mode == .terminal)
        @import("../panel/terminal_panel.zig").line_h
    else
        panel_scroll.bottom_line_h;
    const bottom_content = @as(f32, @floatFromInt(@max(1, bottom_line_count))) * bottom_line_h;
    const bottom_max = @max(0, bottom_content - bottom_content_h);
    const show_bottom_scroll = scrollbar.hovered(state.last_mouse_x, state.last_mouse_y, editor_x, bottom_content_top, editor_w, bottom_content_h);
    scrollbar.drawVertical(
        editor_x + editor_w - scrollbar.track_w - 4,
        bottom_content_top,
        bottom_content_h,
        wb.task_scroll_y,
        bottom_max,
        bottom_content,
        bottom_content_h,
        show_bottom_scroll,
    );
}

const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../../core/state.zig");
const layout = @import("../../core/layout.zig");
const editor_scroll = @import("../../editor/editor_scroll.zig");
const tabs_ui = @import("../../editor/tabs.zig");
const proposal_review_panel = @import("../../editor/proposal_review_panel.zig");
const ai_settings_panel = @import("../../agent/ai_settings_panel.zig");
const Workbench = @import("../../../workbench.zig").Workbench;
const Buffer = @import("forge-editor").Buffer;
const syntax = @import("syntax.zig");
const viewport = @import("viewport.zig");
const overlays = @import("overlays.zig");

pub fn drawEditorPanel(wb: *Workbench, editor_buf: ?*Buffer, editor_x: f32, editor_w: f32, editor_h: f32, _: f32) void {
    if (wb.proposal_review_open) {
        const theme = &wb.theme;
        proposal_review_panel.drawTab(editor_x, syntax.color(theme.colors.accent), syntax.color(theme.colors.editor_bg), syntax.color(theme.colors.border), syntax.color(theme.colors.text_primary), theme.ui_font_size);
        proposal_review_panel.draw(wb, editor_x, editor_w, editor_h);
        return;
    }
    if (wb.ai_settings_open) {
        ai_settings_panel.draw(wb, editor_x, editor_w, editor_h);
        return;
    }
    const theme = &wb.theme;
    const ui_size = theme.ui_font_size;
    renderer.Renderer.drawRect(editor_x, tabs_ui.tab_bar_top, editor_w, tabs_ui.tab_bar_height, syntax.color(theme.colors.tab_bar_bg));
    renderer.Renderer.drawRect(editor_x, tabs_ui.tab_bar_top + tabs_ui.tab_bar_height - 1, editor_w, 1, syntax.color(theme.colors.border));
    const visible_tab_w = @max(10, editor_w - 60);
    renderer.Renderer.setClipRect(editor_x, tabs_ui.tab_bar_top, visible_tab_w, tabs_ui.tab_bar_height);

    var tab_layouts: std.ArrayList(tabs_ui.TabLayout) = .empty;
    defer tab_layouts.deinit(state.gpa);
    tabs_ui.collectLayouts(wb, editor_x, editor_w, &tab_layouts) catch {};

    for (tab_layouts.items) |tab_layout| {
        const tab_index = tab_layout.index;
        const doc = &wb.tabs.tabs.items[tab_index];
        var label_buf: [128]u8 = undefined;
        const label = wb.tabLabel(tab_index, &label_buf);
        const is_active = tab_index == wb.tabs.active;

        if (is_active) {
            // Draw the active tab background
            renderer.Renderer.drawRect(tab_layout.x, tabs_ui.tab_y, tab_layout.width, tabs_ui.tab_height + 1, syntax.color(theme.colors.editor_bg));

            // Clean modern top border highlight
            renderer.Renderer.drawRect(tab_layout.x, tabs_ui.tab_y, tab_layout.width, 1.5, syntax.color(theme.colors.accent));
        } else {
            // Draw a subtle left separator for inactive tabs (unless it's the first tab)
            const border = syntax.color(theme.colors.border);
            if (tab_index > 0 and tab_index - 1 != wb.tabs.active) {
                renderer.Renderer.drawRect(tab_layout.x, tabs_ui.tab_y + 8, 1, tabs_ui.tab_height - 16, .{ .r = border.r, .g = border.g, .b = border.b, .a = border.a * 0.5 });
            }
        }

        // Draw icon
        const res = @import("../icon_resolver.zig").resolveIcon(label);
        renderer.Renderer.drawSvg(res.svg, tab_layout.x + 12, 33, 14, 14, res.color);

        var tab_label_buf: [128:0]u8 = undefined;
        const max_label_chars = @min(label.len, tab_label_buf.len - 1);
        @memcpy(tab_label_buf[0..max_label_chars], label[0..max_label_chars]);
        tab_label_buf[max_label_chars] = 0;
        const color = if (is_active) syntax.color(theme.colors.text_primary) else syntax.color(theme.colors.text_muted);
        renderer.Renderer.drawText(@ptrCast(&tab_label_buf), tab_layout.x + 32, 43, ui_size, color);

        if (doc.external_conflict) {
            renderer.Renderer.drawText("!", tab_layout.x + tab_layout.width - tabs_ui.close_button_width - 10, 43, ui_size, syntax.color(theme.colors.warning));
        }

        const close_x = tab_layout.x + tab_layout.width - tabs_ui.close_button_width + 4;
        const close_color = if (is_active) syntax.color(theme.colors.text_secondary) else syntax.color(theme.colors.text_muted);
        renderer.Renderer.drawText("x", close_x, 43, ui_size, close_color);
    }

    const max_tab_scroll = tabs_ui.maxScroll(wb, visible_tab_w);
    if (max_tab_scroll > 0) {
        const scroll_ratio = wb.tab_scroll_x / max_tab_scroll;
        const bar_w: f32 = @max(24.0, visible_tab_w * (visible_tab_w / tabs_ui.totalContentWidth(wb)));
        const bar_x = editor_x + scroll_ratio * (visible_tab_w - bar_w);
        renderer.Renderer.drawRoundedRect(bar_x, tabs_ui.tab_bar_top + tabs_ui.tab_bar_height - 4, bar_w, 3, 1.5, .{ .r = 0.35, .g = 0.35, .b = 0.35, .a = 0.7 });
    }

    const icon_c = renderer.Color{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 };
    const hover_c = renderer.Color{ .r = 0.18, .g = 0.2, .b = 0.24, .a = 1.0 };
    var rx = editor_x + editor_w - 24;
    const my = state.last_mouse_y;
    const mx = state.last_mouse_x;

    if (mx >= rx and mx < rx + 16 and my >= layout.header_height + 4 and my < layout.header_height + 24) {
        renderer.Renderer.drawRoundedRect(rx - 2, layout.header_height + 4, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.kebab_horizontal, rx, layout.header_height + 7, 16, 16, icon_c);
    rx -= 24;

    if (mx >= rx and mx < rx + 16 and my >= layout.header_height + 4 and my < layout.header_height + 24) {
        renderer.Renderer.drawRoundedRect(rx - 2, layout.header_height + 4, 20, 20, 4, hover_c);
    }
    renderer.Renderer.drawSvg(renderer.icons.repo, rx, layout.header_height + 7, 16, 16, icon_c);

    renderer.Renderer.clearClipRect();

    const pane_w = wb.paneWidth(editor_w);
    if (wb.editor_split) {
        if (wb.docForPane(.primary)) |doc| {
            viewport.drawEditorViewport(
                wb,
                &doc.buffer,
                editor_x,
                pane_w,
                editor_h,
                wb.editor_scroll_y,
                wb.editor_scroll_x,
                doc.path,
                wb.editor_pane_focus == .primary,
            );
        }
        const divider_x = editor_x + pane_w;
        renderer.Renderer.drawRect(divider_x, 65, 4, editor_scroll.viewportHeight(editor_h), syntax.color(theme.colors.tab_bar_bg));
        if (wb.docForPane(.secondary)) |doc| {
            viewport.drawEditorViewport(
                wb,
                &doc.buffer,
                divider_x + 4,
                pane_w,
                editor_h,
                wb.split_scroll_y,
                wb.split_scroll_x,
                doc.path,
                wb.editor_pane_focus == .secondary,
            );
        }
    } else if (editor_buf) |buf| {
        const path = wb.activeFilePath() orelse "";
        viewport.drawEditorViewport(wb, buf, editor_x, editor_w, editor_h, wb.editor_scroll_y, wb.editor_scroll_x, path, true);
    }

    if (wb.completions.visible and wb.completions.list.items.len > 0 and wb.focused_panel == .editor) {
        const gutter = editor_scroll.gutterWidth(theme);
        const focus_x = wb.paneOriginX(editor_x, editor_w, wb.focusedPane());
        const focus_w = pane_w;
        const popup_x = focus_x + gutter + 8;
        const popup_y: f32 = 90;
        const popup_w = @min(focus_w - gutter - 16, 360);
        const row_h: f32 = 16;
        const count = @min(wb.completions.list.items.len, 10);
        const popup_h = @as(f32, @floatFromInt(count)) * row_h + 8;
        renderer.Renderer.drawRoundedRect(popup_x, popup_y, popup_w, popup_h, 6, .{ .r = 0.14, .g = 0.16, .b = 0.22, .a = 0.98 });
        var row: usize = 0;
        while (row < count) : (row += 1) {
            const item = wb.completions.list.items[row];
            const row_y = popup_y + 4 + @as(f32, @floatFromInt(row)) * row_h;
            if (row == wb.completions.selected) {
                renderer.Renderer.drawRect(popup_x + 4, row_y, popup_w - 8, row_h, .{ .r = 0.22, .g = 0.34, .b = 0.52, .a = 1.0 });
            }
            var label_buf: [128:0]u8 = undefined;
            const clipped = if (item.label.len > 127) item.label[0..127] else item.label;
            @memcpy(label_buf[0..clipped.len], clipped);
            label_buf[clipped.len] = 0;
            renderer.Renderer.drawText(@ptrCast(&label_buf), popup_x + 8, row_y + 3, 11.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
        }
    }
    if (wb.find_bar.open or wb.goto_bar.open or wb.rename_bar.open) {
        overlays.drawEditorOverlay(wb, editor_x, editor_w);
    }
    if (wb.focused_panel == .editor) {
        overlays.drawHoverTooltip(wb, wb.paneOriginX(editor_x, editor_w, wb.focusedPane()), pane_w);
    }
    renderer.Renderer.clearClipRect();
}

const editor_scroll = @import("../editor/editor_scroll.zig");
const word_wrap = @import("../editor/word_wrap.zig");
const layout = @import("../core/layout.zig");
const Workbench = @import("../../workbench.zig").Workbench;
const Buffer = @import("forge-editor").Buffer;

pub fn editorPosAt(
    wb: *Workbench,
    editor_buf: *Buffer,
    pane_x: f32,
    pane_w: f32,
    scroll_y: f32,
    scroll_x: f32,
    x: f32,
    y: f32,
) ?struct { row: usize, col: usize } {
    const click_y = y - editor_scroll.firstLineY(&wb.theme) + scroll_y;
    const click_x = x - pane_x - editor_scroll.gutterWidth(&wb.theme) + scroll_x;
    if (click_y < 0) return null;

    if (wb.user_settings.word_wrap) {
        const viewport_w = editor_scroll.viewportWidth(pane_w, &wb.theme);
        const visual_row: usize = @intFromFloat(click_y / editor_scroll.lineHeight(&wb.theme));
        const effective_x = click_x - scroll_x;
        if (effective_x < 0) return null;
        const pos = word_wrap.columnAtVisualRow(
            editor_buf,
            visual_row,
            effective_x,
            viewport_w,
            wb.theme.editor_font_size,
        ) orelse return null;
        return .{ .row = pos.row, .col = pos.col };
    }

    var row: usize = @intFromFloat(click_y / editor_scroll.lineHeight(&wb.theme));
    if (row >= editor_buf.lineCount()) row = if (editor_buf.lineCount() > 0) editor_buf.lineCount() - 1 else 0;
    const line = editor_buf.lineAt(row);
    const col = editor_scroll.columnAtX(line, click_x, wb.theme.editor_font_size);
    return .{ .row = row, .col = col };
}

pub fn isEditorContentArea(geo: layout.Geometry, x: f32, y: f32) bool {
    return x >= geo.editor_x and x < geo.agent_splitter_x and y > @import("../editor/editor_scroll.zig").content_top and y < geo.task_panel_y - 35;
}

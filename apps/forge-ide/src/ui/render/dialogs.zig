const std = @import("std");
const renderer = @import("forge-renderer");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn drawConflictDialog(wb: *@import("../../workbench.zig").Workbench, w: f32, h: f32) void {
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const box_w: f32 = 520;
    const box_h: f32 = 180;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 2;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 10, .{ .r = 0.18, .g = 0.14, .b = 0.12, .a = 1.0 });
    renderer.Renderer.drawText("External file change", box_x + 20, box_y + 16, 16.0, .{ .r = 1.0, .g = 0.85, .b = 0.55, .a = 1.0 });

    var path_buf: [384:0]u8 = undefined;
    const path = wb.conflict_path orelse "active file";
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&path_buf), box_x + 20, box_y + 46, 13.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    renderer.Renderer.drawText("Enter: reload from disk    Esc: keep local edits", box_x + 20, box_y + 78, 12.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
}

pub fn drawRecoveryDialog(wb: *@import("../../workbench.zig").Workbench, w: f32, h: f32) void {
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const box_w: f32 = 520;
    const box_h: f32 = 180;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 2;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 10, .{ .r = 0.12, .g = 0.18, .b = 0.22, .a = 1.0 });
    renderer.Renderer.drawText("Recover unsaved work?", box_x + 20, box_y + 16, 16.0, .{ .r = 0.55, .g = 0.85, .b = 1.0, .a = 1.0 });

    var count_buf: [64:0]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&count_buf, "{d} recovery snapshot(s) found in .forge/recovery/", .{wb.recovery_count}) catch "";
    count_buf[count_msg.len] = 0;
    renderer.Renderer.drawText(@ptrCast(&count_buf), box_x + 20, box_y + 50, 13.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
    renderer.Renderer.drawText("Enter: restore    Esc: discard", box_x + 20, box_y + 82, 12.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });
}

pub fn drawPalette(wb: *@import("../../workbench.zig").Workbench, w: f32, h: f32) void {
    const theme = &wb.theme;
    const overlay = syntax.color(.{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const panel_bg = syntax.color(theme.colors.sidebar_bg);
    const input_bg = syntax.color(theme.colors.tab_bar_bg);
    const border = syntax.color(theme.colors.border);
    const text_primary = syntax.color(theme.colors.text_primary);
    const text_muted = syntax.color(theme.colors.text_muted);
    const text_secondary = syntax.color(theme.colors.text_secondary);
    const accent = syntax.color(theme.colors.accent);
    const accent_soft = syntax.color(theme.colors.accent_soft);

    renderer.Renderer.drawRect(0, 0, w, h, overlay);
    const box_w: f32 = 600;
    const box_h: f32 = 400;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 3;

    // Drop shadow under the panel (offset 4px down-right) — gives the modal
    // depth so it visually floats above the editor instead of looking pasted.
    renderer.Renderer.drawRoundedRect(box_x + 4, box_y + 6, box_w, box_h, 12, .{ .r = 0, .g = 0, .b = 0, .a = 0.35 });
    // Panel with subtle accent border top
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 12, panel_bg);
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, 3, 1.5, accent);

    // Header
    drawZText("Command Palette", box_x + 16, box_y + 14, 13, text_muted);
    drawZText("Type to search commands", box_x + box_w - 180, box_y + 14, 11, text_muted);

    // Input box
    renderer.Renderer.drawRoundedRect(box_x + 12, box_y + 36, box_w - 24, 32, 6, input_bg);
    renderer.Renderer.drawRect(box_x + 12, box_y + 36 + 31, box_w - 24, 1, border);

    var query_buf: [320:0]u8 = undefined;
    @memcpy(query_buf[0..wb.palette.query_len], wb.palette.querySlice());
    query_buf[wb.palette.query_len] = 0;
    // Search icon (forge_icons)
    renderer.Renderer.drawSvg(renderer.forge_icons.search, box_x + 18, box_y + 42, 16, 16, accent);
    renderer.Renderer.drawText(@ptrCast(&query_buf), box_x + 42, box_y + 43, 14.0, text_primary);

    // Blinking cursor indicator (uses the same 1.06s blink cycle as the editor)
    const blink_phase = @mod(@import("../core/state.zig").time, 1.06);
    if (blink_phase < 0.53) {
        renderer.Renderer.drawRect(box_x + 42 + @as(f32, @floatFromInt(wb.palette.query_len)) * 8, box_y + 42, 1, 16, accent);
    }

    // Results
    var row_y = box_y + 82;
    const max_rows: usize = 11;
    const show_rows = @min(wb.palette.filtered.len, max_rows);
    for (0..show_rows) |visible_index| {
        const entry_index = wb.palette.filtered[visible_index];
        const entry = wb.palette.entries[entry_index];
        const selected = visible_index == wb.palette.selected;
        if (selected) {
            renderer.Renderer.drawRoundedRect(box_x + 10, row_y - 3, box_w - 20, 26, 5, accent_soft);
            renderer.Renderer.drawRoundedRect(box_x + 10, row_y - 3, 3, 26, 1.5, accent);
        }
        // Category (muted) + title (primary)
        var cat_buf: [128:0]u8 = undefined;
        const cat_len = @min(entry.category.len, cat_buf.len - 1);
        @memcpy(cat_buf[0..cat_len], entry.category[0..cat_len]);
        cat_buf[cat_len] = 0;
        renderer.Renderer.drawText(@ptrCast(&cat_buf), box_x + 20, row_y, 12.0, text_muted);

        var title_buf: [256:0]u8 = undefined;
        const title_len = @min(entry.title.len, title_buf.len - 1);
        @memcpy(title_buf[0..title_len], entry.title[0..title_len]);
        title_buf[title_len] = 0;
        renderer.Renderer.drawText(@ptrCast(&title_buf), box_x + 20 + @as(f32, @floatFromInt(cat_len)) * 6.5 + 16, row_y, 13.0, if (selected) text_primary else text_secondary);

        // Right-aligned shortcut hint for some common commands. Helps users
        // discover keyboard shortcuts without leaving the palette.
        const shortcut: ?[]const u8 = shortcutForCommand(entry.id);
        if (shortcut) |sc| {
            var sc_buf: [32:0]u8 = undefined;
            const sc_len = @min(sc.len, sc_buf.len - 1);
            @memcpy(sc_buf[0..sc_len], sc[0..sc_len]);
            sc_buf[sc_len] = 0;
            const sc_w: f32 = @as(f32, @floatFromInt(sc_len)) * 6.5;
            // Background pill behind the shortcut for VSCode-like look
            renderer.Renderer.drawRoundedRect(box_x + box_w - 24 - sc_w - 14, row_y - 1, sc_w + 12, 18, 4, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.06 });
            renderer.Renderer.drawText(@ptrCast(&sc_buf), box_x + box_w - 24 - sc_w - 8, row_y + 1, 10.0, text_muted);
        }

        row_y += 26;
    }

    // Footer hint with category-coloured key chips
    renderer.Renderer.drawRect(box_x, box_y + box_h - 28, box_w, 1, border);
    drawZText("↑↓ navigate  ↵ select  esc close", box_x + 16, box_y + box_h - 20, 11, text_muted);
    // Result count on the right
    var count_buf: [64:0]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&count_buf, "{d} results", .{wb.palette.filtered.len}) catch "";
    count_buf[count_msg.len] = 0;
    drawZText(@ptrCast(&count_buf), box_x + box_w - 100, box_y + box_h - 20, 11, text_muted);
}

/// Returns a friendly shortcut string for well-known command IDs, or null
/// if the command has no canonical shortcut. Used by the palette to surface
/// keyboard hints next to entries so users learn shortcuts over time.
fn shortcutForCommand(id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, id, "file.save")) return "⌘S";
    if (std.mem.eql(u8, id, "file.close")) return "⌘W";
    if (std.mem.eql(u8, id, "editor.find")) return "⌘F";
    if (std.mem.eql(u8, id, "editor.replace")) return "⌘⌥F";
    if (std.mem.eql(u8, id, "editor.goto")) return "⌃G";
    if (std.mem.eql(u8, id, "editor.definition")) return "F12";
    if (std.mem.eql(u8, id, "editor.references")) return "⇧F12";
    if (std.mem.eql(u8, id, "editor.rename")) return "F2";
    if (std.mem.eql(u8, id, "editor.format")) return "⇧⌥F";
    if (std.mem.eql(u8, id, "editor.add_cursor_next")) return "⌘D";
    if (std.mem.eql(u8, id, "editor.add_cursor_all")) return "⌘⇧L";
    if (std.mem.eql(u8, id, "palette.open")) return "⌘⇧P";
    if (std.mem.eql(u8, id, "view.toggle")) return "⌘⇧A";
    if (std.mem.eql(u8, id, "agent.edit_selection")) return "⌘K";
    return null;
}

const syntax = @import("theme.zig");

fn drawZText(text: []const u8, x: f32, y: f32, size: f32, color: renderer.Color) void {
    var buf: [256:0]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    renderer.Renderer.drawText(@ptrCast(&buf), x, y, size, color);
}

pub fn drawWorkspaceSymbolPicker(wb: *@import("../../workbench.zig").Workbench, w: f32, h: f32) void {
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const box_w: f32 = 640;
    const box_h: f32 = 420;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 3;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 10, .{ .r = 0.16, .g = 0.16, .b = 0.18, .a = 1.0 });
    renderer.Renderer.drawText("Workspace Symbol Search", box_x + 16, box_y + 12, 14.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });

    var query_buf: [320:0]u8 = undefined;
    @memcpy(query_buf[0..wb.workspace_symbol_picker.query_len], wb.workspace_symbol_picker.query[0..wb.workspace_symbol_picker.query_len]);
    query_buf[wb.workspace_symbol_picker.query_len] = 0;
    renderer.Renderer.drawRoundedRect(box_x + 12, box_y + 36, box_w - 24, 28, 6, .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 });
    renderer.Renderer.drawText(@ptrCast(&query_buf), box_x + 20, box_y + 42, 14.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    var row_y = box_y + 76;
    const max_rows: usize = 12;
    const show_rows = @min(wb.workspace_symbol_picker.entries.items.len, max_rows);
    for (0..show_rows) |visible_index| {
        const entry = wb.workspace_symbol_picker.entries.items[visible_index];
        const selected = visible_index == wb.workspace_symbol_picker.selected;
        if (selected) {
            renderer.Renderer.drawRoundedRect(box_x + 10, row_y - 2, box_w - 20, 22, 4, .{ .r = 0.22, .g = 0.35, .b = 0.55, .a = 1.0 });
        }
        var line_buf: [384:0]u8 = undefined;
        var len: usize = 0;

        if (entry.container_name) |c| {
            len = (std.fmt.bufPrint(line_buf[len..], "{s}::{s}", .{ c, entry.name }) catch entry.name).len;
        } else {
            len = (std.fmt.bufPrint(line_buf[len..], "{s}", .{entry.name}) catch entry.name).len;
        }
        const basename = std.fs.path.basename(entry.location.uri);
        _ = std.fmt.bufPrint(line_buf[len..], "  - {s}", .{basename}) catch "";

        line_buf[line_buf.len - 1] = 0;

        // Find a null terminator or trim to fit
        var term_idx: usize = 0;
        while (term_idx < line_buf.len and line_buf[term_idx] != 0) : (term_idx += 1) {}
        if (term_idx >= line_buf.len) term_idx = line_buf.len - 1;
        line_buf[term_idx] = 0;

        renderer.Renderer.drawText(@ptrCast(&line_buf), box_x + 18, row_y, 13.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
        row_y += 24;
    }
}

pub fn drawGitBranchPicker(wb: *@import("../../workbench.zig").Workbench, w: f32, h: f32) void {
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const box_w: f32 = 400;
    const box_h: f32 = 320;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 3;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 10, .{ .r = 0.16, .g = 0.16, .b = 0.18, .a = 1.0 });
    renderer.Renderer.drawText("Switch Branch", box_x + 16, box_y + 12, 14.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });

    var query_buf: [320:0]u8 = undefined;
    @memcpy(query_buf[0..wb.git_branch_picker.query_len], wb.git_branch_picker.query[0..wb.git_branch_picker.query_len]);
    query_buf[wb.git_branch_picker.query_len] = 0;
    renderer.Renderer.drawRoundedRect(box_x + 12, box_y + 36, box_w - 24, 28, 6, .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 });
    renderer.Renderer.drawText(@ptrCast(&query_buf), box_x + 20, box_y + 42, 14.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    var row_y = box_y + 76;
    const max_rows: usize = 9;
    const show_rows = @min(wb.git_branch_picker.filtered.items.len, max_rows);
    for (0..show_rows) |visible_index| {
        const entry_index = wb.git_branch_picker.filtered.items[visible_index];
        const entry = wb.git_branch_picker.entries.items[entry_index];
        const selected = visible_index == wb.git_branch_picker.selected;
        if (selected) {
            renderer.Renderer.drawRoundedRect(box_x + 8, row_y - 4, box_w - 16, 24, 4, .{ .r = 0.25, .g = 0.45, .b = 0.85, .a = 1.0 });
        }

        var line_buf: [256]u8 = undefined;
        const len = (std.fmt.bufPrint(&line_buf, "{s}", .{entry.name}) catch entry.name).len;
        line_buf[len] = 0;

        renderer.Renderer.drawText(@ptrCast(&line_buf), box_x + 18, row_y, 13.0, .{ .r = 0.92, .g = 0.92, .b = 0.92, .a = 1.0 });
        row_y += 24;
    }
}

pub fn drawOutputChannelPicker(wb: *@import("../../workbench.zig").Workbench, w: f32, h: f32) void {
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    const box_w: f32 = 400;
    const box_h: f32 = 320;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 3;
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 10, .{ .r = 0.16, .g = 0.16, .b = 0.18, .a = 1.0 });
    renderer.Renderer.drawText("Select Output Channel", box_x + 16, box_y + 12, 14.0, .{ .r = 0.7, .g = 0.7, .b = 0.7, .a = 1.0 });

    var query_buf: [320:0]u8 = undefined;
    @memcpy(query_buf[0..wb.output_channel_picker.query_len], wb.output_channel_picker.query[0..wb.output_channel_picker.query_len]);
    query_buf[wb.output_channel_picker.query_len] = 0;
    renderer.Renderer.drawRoundedRect(box_x + 12, box_y + 36, box_w - 24, 28, 6, .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 });
    renderer.Renderer.drawText(@ptrCast(&query_buf), box_x + 20, box_y + 42, 14.0, .{ .r = 1, .g = 1, .b = 1, .a = 1.0 });

    var row_y = box_y + 76;
    const max_rows: usize = 9;
    const show_rows = @min(wb.output_channel_picker.filtered.items.len, max_rows);
    for (0..show_rows) |visible_index| {
        const entry_index = wb.output_channel_picker.filtered.items[visible_index];
        const entry = wb.output_channel_picker.entries.items[entry_index];
        if (visible_index == wb.output_channel_picker.selected) {
            renderer.Renderer.drawRoundedRect(box_x + 12, row_y, box_w - 24, 24, 4, .{ .r = 0.25, .g = 0.4, .b = 0.6, .a = 1.0 });
        } else {
            // renderer.Renderer.drawRoundedRect(box_x + 12, row_y, box_w - 24, 24, 4, .{ .r = 0.2, .g = 0.2, .b = 0.22, .a = 1.0 });
        }
        var name_buf: [256:0]u8 = undefined;
        const name_len = @min(entry.name.len, 255);
        @memcpy(name_buf[0..name_len], entry.name[0..name_len]);
        name_buf[name_len] = 0;
        renderer.Renderer.drawText(@ptrCast(&name_buf), box_x + 24, row_y + 4, 13.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
        row_y += 26;
    }
}

pub fn drawQuickOpen(wb: *@import("../../workbench.zig").Workbench, w: f32, h: f32) void {
    if (!wb.quick_open_open) return;

    const overlay = syntax.color(.{ .r = 0, .g = 0, .b = 0, .a = 0.55 });
    renderer.Renderer.drawRect(0, 0, w, h, overlay);

    const box_w: f32 = 600;
    const box_h: f32 = 400;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 3;

    // Drop shadow
    renderer.Renderer.drawRoundedRect(box_x + 4, box_y + 6, box_w, box_h, 12, .{ .r = 0, .g = 0, .b = 0, .a = 0.35 });
    // Panel
    const panel_bg = syntax.color(wb.theme.colors.sidebar_bg);
    const accent = syntax.color(wb.theme.colors.accent);
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 12, panel_bg);
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, 3, 1.5, accent);

    // Header
    drawZText("Go to File", box_x + 16, box_y + 14, 13, syntax.color(wb.theme.colors.text_muted));
    drawZText("Type to search files", box_x + box_w - 180, box_y + 14, 11, syntax.color(wb.theme.colors.text_muted));

    // Input box
    const input_bg = syntax.color(wb.theme.colors.tab_bar_bg);
    const border = syntax.color(wb.theme.colors.border);
    renderer.Renderer.drawRoundedRect(box_x + 12, box_y + 36, box_w - 24, 32, 6, input_bg);
    renderer.Renderer.drawRect(box_x + 12, box_y + 36 + 31, box_w - 24, 1, border);

    // Search icon
    renderer.Renderer.drawSvg(renderer.forge_icons.search, box_x + 18, box_y + 42, 16, 16, accent);

    // Query text
    var query_buf: [320:0]u8 = undefined;
    @memcpy(query_buf[0..wb.quick_open_query_len], wb.quick_open_query[0..wb.quick_open_query_len]);
    query_buf[wb.quick_open_query_len] = 0;
    renderer.Renderer.drawText(@ptrCast(&query_buf), box_x + 42, box_y + 43, 14.0, syntax.color(wb.theme.colors.text_primary));

    // Blinking cursor
    const blink_phase = @mod(@import("../core/state.zig").time, 1.06);
    if (blink_phase < 0.53) {
        renderer.Renderer.drawRect(box_x + 42 + @as(f32, @floatFromInt(wb.quick_open_query_len)) * 8, box_y + 42, 1, 16, accent);
    }

    // Results — fuzzy match files
    var row_y = box_y + 82;
    const max_rows: usize = 11;
    var visible_count: usize = 0;
    for (wb.quick_open_files) |path| {
        if (visible_count >= max_rows) break;
        // Simple fuzzy: check if query is a substring (case-insensitive)
        if (wb.quick_open_query_len > 0) {
            const query = wb.quick_open_query[0..wb.quick_open_query_len];
            if (!fuzzyMatch(query, path)) continue;
        }

        const selected = visible_count == wb.quick_open_selected;
        if (selected) {
            renderer.Renderer.drawRoundedRect(box_x + 10, row_y - 3, box_w - 20, 26, 5, syntax.color(wb.theme.colors.accent_soft));
            renderer.Renderer.drawRoundedRect(box_x + 10, row_y - 3, 3, 26, 1.5, accent);
        }

        // Show filename (bold) + path (muted)
        const basename = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "";
        var name_buf: [128:0]u8 = undefined;
        const name_len = @min(basename.len, name_buf.len - 1);
        @memcpy(name_buf[0..name_len], basename[0..name_len]);
        name_buf[name_len] = 0;
        renderer.Renderer.drawText(@ptrCast(&name_buf), box_x + 20, row_y, 13.0, if (selected) syntax.color(wb.theme.colors.text_primary) else syntax.color(wb.theme.colors.text_secondary));

        var dir_buf: [256:0]u8 = undefined;
        const dir_len = @min(dir.len, dir_buf.len - 1);
        @memcpy(dir_buf[0..dir_len], dir[0..dir_len]);
        dir_buf[dir_len] = 0;
        const dir_w = @as(f32, @floatFromInt(dir_len)) * 6.0;
        renderer.Renderer.drawText(@ptrCast(&dir_buf), box_x + box_w - 24 - dir_w - 8, row_y, 11.0, syntax.color(wb.theme.colors.text_muted));

        row_y += 26;
        visible_count += 1;
    }

    // Footer
    renderer.Renderer.drawRect(box_x, box_y + box_h - 28, box_w, 1, border);
    drawZText("↑↓ navigate  ↵ open  esc close", box_x + 16, box_y + box_h - 20, 11, syntax.color(wb.theme.colors.text_muted));
    var count_buf: [64:0]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&count_buf, "{d} files", .{wb.quick_open_files.len}) catch "";
    count_buf[count_msg.len] = 0;
    drawZText(@ptrCast(&count_buf), box_x + box_w - 100, box_y + box_h - 20, 11, syntax.color(wb.theme.colors.text_muted));
}

fn fuzzyMatch(query: []const u8, text: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (text) |ch| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[qi])) {
            qi += 1;
        }
    }
    return qi >= query.len;
}

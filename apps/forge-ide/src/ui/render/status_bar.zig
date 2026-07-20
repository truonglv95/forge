//! Status bar — bottom strip with clickable items.
//!
//! Items are laid out left-to-right and right-to-left. Each item has:
//!   - An icon/glyph (optional)
//!   - A label
//!   - An action (dispatched when clicked)
//!
//! Items include: mode, file path, cursor position (row:col), language,
//! LSP status, problems count, agent model, git branch, encoding.
//!
//! Hover highlights the item; click dispatches its action. For example:
//!   - Click "row:col" → opens Go to Line
//!   - Click "language" → opens language settings
//!   - Click "model" → opens model selector menu
//!   - Click "branch" → opens branch switcher

const std = @import("std");
const renderer = @import("forge-renderer");
const layout = @import("../core/layout.zig");
const state = @import("../core/state.zig");
const theme_mod = @import("theme.zig");
const Workbench = @import("../../workbench.zig").Workbench;
const Command = @import("../../workbench/commands.zig").Command;

pub const ItemAction = enum {
    none,
    goto_line,
    open_settings,
    open_model_menu,
    open_branch_menu,
    git_sync,
    open_problems,
    open_language_settings,
    open_command_palette,
};

pub const Item = struct {
    /// Icon glyph (optional, drawn before label).
    icon: ?[]const u8 = null,
    /// Label text (e.g. "Ln 42, Col 8", "zig", "main").
    label: []const u8,
    /// Action when clicked.
    action: ItemAction = .none,
    /// Whether this item is currently hovered (for highlight).
    hovered: bool = false,
    /// Click bounds (set during draw, used by hitTest).
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const bar_height: f32 = 22;

/// Draw the status bar with clickable items.
pub fn drawStatusBar(wb: *Workbench, w: f32, h: f32, shell_mode: layout.ShellMode) void {
    const theme = &wb.theme;
    const font_size = 11.0;
    const bar_y = h - bar_height;

    // Background.
    renderer.Renderer.drawRect(0, bar_y, w, bar_height, theme_mod.color(theme.colors.status_bg));

    // Border on top.
    renderer.Renderer.drawRect(0, bar_y, w, 1, theme_mod.color(theme.colors.border));

    // Build hit test items from scratch
    wb.status_bar_item_count = 0;

    var left_x: f32 = 8;

    // ---- LEFT ITEMS ----
    // 1. Mode
    const mode_label = switch (shell_mode) {
        .ide => "IDE",
        .agent_window => "Agent",
    };
    const mode_w = estimateWidth(mode_label, font_size) + 16;
    renderer.Renderer.drawText(mode_label, left_x + 8, bar_y + 4, font_size, theme_mod.color(theme.colors.text_secondary));
    left_x += mode_w + 8;

    // 2. Git branch
    if (wb.git.status) |gs| {
        if (gs.branch) |branch| {
            if (branch.len > 0) {
                const branch_w = estimateWidth(branch, font_size) + 16 + 18; // 18 for icon
                const is_hover = isHovered(wb, left_x, bar_y, branch_w, bar_height);
                if (is_hover) {
                    renderer.Renderer.drawRect(left_x, bar_y, branch_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
                }
                renderer.Renderer.drawSvg(renderer.icons.git_branch, left_x + 8, bar_y + 4, 14, 14, theme_mod.color(theme.colors.text_secondary));
                renderer.Renderer.drawText(branch, left_x + 8 + 18, bar_y + 4, font_size, theme_mod.color(theme.colors.text_secondary));
                wb.status_bar_items[wb.status_bar_item_count] = .{
                    .icon = "branch",
                    .label = branch,
                    .action = .open_branch_menu,
                    .hovered = is_hover,
                    .x = left_x,
                    .y = bar_y,
                    .w = branch_w,
                    .h = bar_height,
                };
                wb.status_bar_item_count += 1;
                left_x += branch_w + 8;

                // 3. Git sync
                if (gs.ahead > 0 or gs.behind > 0) {
                    var sync_buf: [64]u8 = undefined;
                    const sync_label = std.fmt.bufPrint(&sync_buf, "{d}↓ {d}↑", .{ gs.behind, gs.ahead }) catch "";
                    const sync_w = estimateWidth(sync_label, font_size) + 16 + 18;
                    const is_sync_hover = isHovered(wb, left_x, bar_y, sync_w, bar_height);
                    if (is_sync_hover) {
                        renderer.Renderer.drawRect(left_x, bar_y, sync_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
                    }
                    renderer.Renderer.drawSvgRotated(renderer.icons.sync, left_x + 8, bar_y + 4, 14, 14, wb.sync_icon_angle, theme_mod.color(theme.colors.text_secondary));
                    renderer.Renderer.drawText(sync_label, left_x + 8 + 18, bar_y + 4, font_size, theme_mod.color(theme.colors.text_secondary));
                    wb.status_bar_items[wb.status_bar_item_count] = .{
                        .icon = "sync",
                        .label = sync_label,
                        .action = .git_sync,
                        .hovered = is_sync_hover,
                        .x = left_x,
                        .y = bar_y,
                        .w = sync_w,
                        .h = bar_height,
                    };
                    wb.status_bar_item_count += 1;
                    left_x += sync_w + 8;
                }
            }
        }
    }

    // 4. Problems count
    const prob_count = wb.lsp.diagnostics.list.items.len;
    if (prob_count > 0) {
        var prob_buf: [32]u8 = undefined;
        const prob_label = std.fmt.bufPrint(&prob_buf, "{d} problems", .{prob_count}) catch "problems";
        const prob_w = estimateWidth(prob_label, font_size) + 16;
        const is_hover = isHovered(wb, left_x, bar_y, prob_w, bar_height);
        if (is_hover) {
            renderer.Renderer.drawRect(left_x, bar_y, prob_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
        }
        renderer.Renderer.drawText(prob_label, left_x + 8, bar_y + 4, font_size, theme_mod.color(theme.colors.text_primary));
        wb.status_bar_items[wb.status_bar_item_count] = .{
            .icon = "!",
            .label = prob_label,
            .action = .open_problems,
            .hovered = is_hover,
            .x = left_x,
            .y = bar_y,
            .w = prob_w,
            .h = bar_height,
        };
        wb.status_bar_item_count += 1;
        left_x += prob_w + 8;
    }

    // ---- RIGHT ITEMS ----
    var right_x = w - 8;

    // Agent model
    if (wb.agent_ui.model) |model| {
        const model_w = estimateWidth(model, font_size) + 16;
        right_x -= model_w;
        const is_hover = isHovered(wb, right_x, bar_y, model_w, bar_height);
        if (is_hover) {
            renderer.Renderer.drawRect(right_x, bar_y, model_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
        }
        renderer.Renderer.drawText(model, right_x + 8, bar_y + 4, font_size, theme_mod.color(theme.colors.accent));
        wb.status_bar_items[wb.status_bar_item_count] = .{
            .icon = "model",
            .label = model,
            .action = .open_model_menu,
            .hovered = is_hover,
            .x = right_x,
            .y = bar_y,
            .w = model_w,
            .h = bar_height,
        };
        wb.status_bar_item_count += 1;
        right_x -= 8;
    }

    if (wb.activeFilePath()) |path| {
        // LSP status
        const lsp_label = "LSP";
        const lsp_w = estimateWidth(lsp_label, font_size) + 16;
        right_x -= lsp_w;
        renderer.Renderer.drawText(lsp_label, right_x + 8, bar_y + 4, font_size, theme_mod.color(theme.colors.text_secondary));
        right_x -= 8;

        // Language
        const lang_label: []const u8 = blk: {
            wb.lsp.registry.mutex.lock();
            defer wb.lsp.registry.mutex.unlock();
            if (wb.lsp.registry.findForPathUnlocked(path)) |server| {
                break :blk server.language_id;
            }
            break :blk "plaintext";
        };
        const lang_w = estimateWidth(lang_label, font_size) + 16;
        right_x -= lang_w;
        const is_lang_hover = isHovered(wb, right_x, bar_y, lang_w, bar_height);
        if (is_lang_hover) {
            renderer.Renderer.drawRect(right_x, bar_y, lang_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
        }
        renderer.Renderer.drawText(lang_label, right_x + 8, bar_y + 4, font_size, theme_mod.color(theme.colors.text_primary));
        wb.status_bar_items[wb.status_bar_item_count] = .{
            .label = lang_label,
            .action = .open_language_settings,
            .hovered = is_lang_hover,
            .x = right_x,
            .y = bar_y,
            .w = lang_w,
            .h = bar_height,
        };
        wb.status_bar_item_count += 1;
        right_x -= 8;

        // Cursor position
        if (wb.activeBuffer()) |buf| {
            var pos_buf: [32]u8 = undefined;
            const pos_label = std.fmt.bufPrint(&pos_buf, "Ln {d}, Col {d}", .{ buf.cursor.row + 1, buf.cursor.col + 1 }) catch "Ln ?, Col ?";
            const pos_w = estimateWidth(pos_label, font_size) + 16;
            right_x -= pos_w;
            const is_pos_hover = isHovered(wb, right_x, bar_y, pos_w, bar_height);
            if (is_pos_hover) {
                renderer.Renderer.drawRect(right_x, bar_y, pos_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
            }
            renderer.Renderer.drawText(pos_label, right_x + 8, bar_y + 4, font_size, theme_mod.color(theme.colors.text_primary));
            wb.status_bar_items[wb.status_bar_item_count] = .{
                .label = pos_label,
                .action = .goto_line,
                .hovered = is_pos_hover,
                .x = right_x,
                .y = bar_y,
                .w = pos_w,
                .h = bar_height,
            };
            wb.status_bar_item_count += 1;
            right_x -= 8;
        }
    }

    // Status message in the middle (taking remaining space)
    if (wb.status_message.len > 0) {
        if (right_x > left_x + 16) {
            renderer.Renderer.pushClipRect(left_x + 8, bar_y, right_x - left_x - 16, bar_height);
            defer renderer.Renderer.popClipRect();
            renderer.Renderer.drawText(wb.status_message, left_x + 12, bar_y + 4, font_size, .{ .r = 0.9, .g = 0.9, .b = 0.6, .a = 1.0 });
        }
    }
}

fn isHovered(wb: *Workbench, x: f32, y: f32, w: f32, h: f32) bool {
    _ = wb;
    const mx = state.last_mouse_x;
    const my = state.last_mouse_y;
    return mx >= x and mx <= x + w and my >= y and my <= y + h;
}

fn estimateWidth(text: []const u8, font_size: f32) f32 {
    return @as(f32, @floatFromInt(text.len)) * font_size * 0.6;
}

/// Hit-test a click on the status bar. Returns the action to dispatch,
/// or .none if the click missed all items.
pub fn hitTest(wb: *Workbench, click_x: f32, click_y: f32) ItemAction {
    for (wb.status_bar_items[0..wb.status_bar_item_count]) |item| {
        if (click_x >= item.x and click_x <= item.x + item.w and
            click_y >= item.y and click_y <= item.y + item.h)
        {
            return item.action;
        }
    }
    return .none;
}

/// Dispatch the action for a clicked status bar item.
pub fn dispatchAction(wb: *Workbench, action: ItemAction) void {
    switch (action) {
        .none => {},
        .goto_line => wb.dispatch(.editor_goto_line) catch {},
        .open_settings => wb.dispatch(.open_settings_modal) catch {},
        .open_model_menu => wb.dispatch(.agent_toggle_model_menu) catch {},
        .open_branch_menu => wb.dispatch(.git_refresh) catch {},
        .git_sync => wb.dispatch(.git_pull) catch {},
        .open_problems => wb.dispatch(.{ .set_bottom_panel_mode = .problems }) catch {},
        .open_language_settings => wb.dispatch(.open_settings_modal) catch {},
        .open_command_palette => wb.dispatch(.palette_open) catch {},
    }
}

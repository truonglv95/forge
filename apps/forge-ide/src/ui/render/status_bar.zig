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

    // Build items dynamically.
    var items: [16]Item = undefined;
    var item_count: usize = 0;

    // Left items: mode, file, cursor pos, language.
    items[item_count] = .{
        .label = switch (shell_mode) {
            .ide => "IDE",
            .agent_window => "Agent",
        },
        .action = .none,
    };
    item_count += 1;

    // File path + modified indicator.
    if (wb.activeFilePath()) |path| {
        const basename = std.fs.path.basename(path);
        var file_buf: [128]u8 = undefined;
        const modified_str = if (wb.tabs.tabs.items.len > 0 and wb.tabs.active < wb.tabs.tabs.items.len and wb.tabs.tabs.items[wb.tabs.active].isDirty()) " •" else "";
        const file_label = std.fmt.bufPrint(&file_buf, "{s}{s}", .{ basename, modified_str }) catch basename;
        items[item_count] = .{
            .icon = "file",
            .label = file_label,
            .action = .none,
        };
        item_count += 1;

        // Cursor position.
        if (wb.activeBuffer()) |buf| {
            var pos_buf: [32]u8 = undefined;
            const pos_label = std.fmt.bufPrint(&pos_buf, "Ln {d}, Col {d}", .{ buf.cursor.row + 1, buf.cursor.col + 1 }) catch "Ln ?, Col ?";
            items[item_count] = .{
                .label = pos_label,
                .action = .goto_line,
            };
            item_count += 1;
        }

        // Language (from LSP registry).
        const lang_label: []const u8 = blk: {
            wb.lsp_registry.mutex.lock();
            defer wb.lsp_registry.mutex.unlock();
            if (wb.lsp_registry.findForPathUnlocked(path)) |server| {
                break :blk server.language_id;
            }
            break :blk "plaintext";
        };
        items[item_count] = .{
            .label = lang_label,
            .action = .open_language_settings,
        };
        item_count += 1;

        // LSP status.
        items[item_count] = .{
            .icon = "lsp",
            .label = "LSP",
            .action = .none,
        };
        item_count += 1;
    }

    // Problems count.
    const prob_count = wb.diagnostics.list.items.len;
    if (prob_count > 0) {
        var prob_buf: [32]u8 = undefined;
        const prob_label = std.fmt.bufPrint(&prob_buf, "{d} problems", .{prob_count}) catch "problems";
        items[item_count] = .{
            .icon = "!",
            .label = prob_label,
            .action = .open_problems,
        };
        item_count += 1;
    }

    // Right items: agent model, git branch.
    // Draw right-to-left for these.
    var right_x = w - 8;

    // Agent model.
    if (wb.ai_model) |model| {
        const model_label = model;
        const model_w = estimateWidth(model_label, font_size) + 16;
        right_x -= model_w;
        const is_hover = isHovered(wb, right_x, bar_y, model_w, bar_height);
        if (is_hover) {
            renderer.Renderer.drawRect(right_x, bar_y, model_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
        }
        renderer.Renderer.drawText(model_label, right_x + 8, bar_y + 4, font_size, theme_mod.color(theme.colors.accent));
        // Store for hit-test.
        wb.status_bar_items[wb.status_bar_item_count] = .{
            .icon = "model",
            .label = model_label,
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

    // Git branch.
    if (wb.git_status) |gs| {
        if (gs.branch) |branch| {
            if (branch.len > 0) {
                var branch_buf: [64]u8 = undefined;
                const branch_label = std.fmt.bufPrint(&branch_buf, "{s} {s}", .{ "branch", branch }) catch branch;
                const branch_w = estimateWidth(branch_label, font_size) + 16;
                right_x -= branch_w;
                const is_hover = isHovered(wb, right_x, bar_y, branch_w, bar_height);
                if (is_hover) {
                    renderer.Renderer.drawRect(right_x, bar_y, branch_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
                }
                renderer.Renderer.drawText(branch_label, right_x + 8, bar_y + 4, font_size, theme_mod.color(theme.colors.text_secondary));
                wb.status_bar_items[wb.status_bar_item_count] = .{
                    .icon = "branch",
                    .label = branch,
                    .action = .open_branch_menu,
                    .hovered = is_hover,
                    .x = right_x,
                    .y = bar_y,
                    .w = branch_w,
                    .h = bar_height,
                };
                wb.status_bar_item_count += 1;
                right_x -= 8;
            }
        }
    }

    // Status message (rightmost).
    if (wb.status_message.len > 0) {
        const msg_w = estimateWidth(wb.status_message, font_size) + 16;
        right_x -= msg_w;
        renderer.Renderer.drawText(wb.status_message, right_x + 8, bar_y + 4, font_size, .{ .r = 0.9, .g = 0.9, .b = 0.6, .a = 1.0 });
    }

    // Draw left items.
    var left_x: f32 = 8;
    wb.status_bar_item_count = 0; // reset, we'll re-add left items
    for (items[0..item_count]) |item| {
        const label_w = estimateWidth(item.label, font_size);
        const item_w = label_w + 16;
        const is_hover = isHovered(wb, left_x, bar_y, item_w, bar_height);

        if (is_hover and item.action != .none) {
            renderer.Renderer.drawRect(left_x, bar_y, item_w, bar_height, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
        }

        const color = if (item.action != .none)
            theme_mod.color(theme.colors.text_primary)
        else
            theme_mod.color(theme.colors.text_secondary);

        renderer.Renderer.drawText(item.label, left_x + 8, bar_y + 4, font_size, color);

        // Store clickable items for hit-test.
        if (item.action != .none) {
            wb.status_bar_items[wb.status_bar_item_count] = .{
                .icon = item.icon,
                .label = item.label,
                .action = item.action,
                .hovered = is_hover,
                .x = left_x,
                .y = bar_y,
                .w = item_w,
                .h = bar_height,
            };
            wb.status_bar_item_count += 1;
        }

        left_x += item_w + 8;
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
        .open_problems => wb.dispatch(.{ .set_bottom_panel_mode = .problems }) catch {},
        .open_language_settings => wb.dispatch(.open_settings_modal) catch {},
        .open_command_palette => wb.dispatch(.palette_open) catch {},
    }
}

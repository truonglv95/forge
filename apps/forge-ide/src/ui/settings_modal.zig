const std = @import("std");
const renderer = @import("forge-renderer");
const workspace = @import("forge-workspace");
const layout = @import("core/layout.zig");
const state = @import("core/state.zig");
const theme_loader = @import("../theme_loader.zig");
const Workbench = @import("../workbench.zig").Workbench;

fn color(rgba: workspace.Rgba) renderer.Color {
    return theme_loader.toColor(rgba);
}

pub const Tab = enum {
    general,
    account,
    permissions,
    appearance,
    models,
    customizations,
    browser,
    app,
    project_forge,
};

pub const Hit = union(enum) {
    close_modal,
    switch_tab: Tab,
    toggle_word_wrap,
    ai_panel_font_decrease,
    ai_panel_font_increase,
    ai_edit_provider,
    ai_edit_model,
    ai_edit_embedding_provider,
    ai_edit_embedding_model,
    ai_set_embedding_model: usize,
    ai_toggle_hyde,
    none,
};

pub fn draw(wb: *Workbench, window_w: f32, window_h: f32) void {
    if (!wb.settings_modal_open) return;

    const theme = &wb.theme;

    // Draw Backdrop
    renderer.Renderer.drawRect(0, 0, window_w, window_h, .{ .r = 0, .g = 0, .b = 0, .a = 0.6 });

    // Draw Modal Container
    const modal_w: f32 = 860;
    const modal_h: f32 = 620;
    const modal_x: f32 = (window_w - modal_w) / 2.0;
    const modal_y: f32 = (window_h - modal_h) / 2.0;

    const bg_color = color(theme.colors.editor_bg);
    const border_color = color(theme.colors.border);
    const text_primary = color(theme.colors.text_primary);
    const text_muted = color(theme.colors.text_muted);

    renderer.Renderer.drawRoundedRect(modal_x - 1, modal_y - 1, modal_w + 2, modal_h + 2, 12, border_color);
    renderer.Renderer.drawRoundedRect(modal_x, modal_y, modal_w, modal_h, 12, bg_color);

    // Layout
    const sidebar_w: f32 = 220;
    const content_x: f32 = modal_x + sidebar_w;
    const content_w: f32 = modal_w - sidebar_w;

    // Sidebar line
    renderer.Renderer.drawRect(content_x, modal_y, 1, modal_h, border_color);

    // Sidebar Tab Menu
    var sy: f32 = modal_y + 20;
    const tab_h: f32 = 32;

    const tabs = [_]struct { label: []const u8, id: Tab }{
        .{ .label = "General", .id = .general },
        .{ .label = "Account", .id = .account },
        .{ .label = "Permissions", .id = .permissions },
        .{ .label = "Appearance", .id = .appearance },
        .{ .label = "Models", .id = .models },
        .{ .label = "Customizations", .id = .customizations },
        .{ .label = "Browser", .id = .browser },
        .{ .label = "App", .id = .app },
    };

    for (tabs) |tab| {
        const is_active = wb.settings_modal_tab == tab.id;
        if (is_active) {
            renderer.Renderer.drawRoundedRect(modal_x + 12, sy, sidebar_w - 24, tab_h, 6, color(theme.colors.tab_active_bg));
            renderer.Renderer.drawText(tab.label, modal_x + 24, sy + 10, 13.0, text_primary);
        } else {
            renderer.Renderer.drawText(tab.label, modal_x + 24, sy + 10, 13.0, text_muted);
        }
        sy += tab_h;
    }

    sy += 20;
    renderer.Renderer.drawText("Projects", modal_x + 16, sy, 11.0, text_muted);
    sy += 24;

    const project_tabs = [_]struct { label: []const u8, id: Tab }{
        .{ .label = wb.workspace_name, .id = .project_forge },
    };

    for (project_tabs) |tab| {
        const is_active = wb.settings_modal_tab == tab.id;
        if (is_active) {
            renderer.Renderer.drawRoundedRect(modal_x + 12, sy, sidebar_w - 24, tab_h, 6, color(theme.colors.tab_active_bg));
            renderer.Renderer.drawText(tab.label, modal_x + 24, sy + 10, 13.0, text_primary);
        } else {
            renderer.Renderer.drawText(tab.label, modal_x + 24, sy + 10, 13.0, text_muted);
        }
        sy += tab_h;
    }

    // Content Area
    var cy: f32 = modal_y + 32;
    renderer.Renderer.setClipRect(content_x + 1, modal_y, content_w - 1, modal_h);

    if (wb.settings_modal_tab == .general) {
        renderer.Renderer.drawText("General", content_x + 32, cy, 20.0, text_primary);
        cy += 30;
        renderer.Renderer.drawText("Editor defaults", content_x + 32, cy, 13.0, text_muted);
        cy += 32;

        drawToggleRow(content_x + 32, cy, content_w - 64, "Word Wrap", "Wrap long lines inside the editor viewport.", wb.user_settings.word_wrap, theme);
        cy += 54;

        var ai_font_buf: [64:0]u8 = undefined;
        const ai_font_text = std.fmt.bufPrintZ(&ai_font_buf, "{d:.1}px", .{wb.user_settings.ai_panel_font_size}) catch "default";
        drawStepperRow(content_x + 32, cy, content_w - 64, "AI Panel Font Size", "Controls AI chat prose size and derived markdown spacing.", ai_font_text, theme);
        cy += 54;

        var tab_buf: [64:0]u8 = undefined;
        const tab_text = std.fmt.bufPrintZ(&tab_buf, "{d} spaces", .{wb.user_settings.tab_width}) catch "default";
        drawValueRow(content_x + 32, cy, content_w - 64, "Tab Width", tab_text, theme);
        cy += 44;

        var font_buf: [64:0]u8 = undefined;
        const font_text = std.fmt.bufPrintZ(&font_buf, "{d:.1}px", .{wb.user_settings.font_size}) catch "default";
        drawValueRow(content_x + 32, cy, content_w - 64, "Font Size", font_text, theme);
        cy += 44;

        drawValueRow(content_x + 32, cy, content_w - 64, "Format on Save", if (wb.user_settings.format_on_save) "enabled" else "disabled", theme);
    } else if (wb.settings_modal_tab == .models) {
        renderer.Renderer.drawText("Models", content_x + 32, cy, 20.0, text_primary);
        cy += 30;
        renderer.Renderer.drawText("AI routing currently loaded by Forge.", content_x + 32, cy, 13.0, text_muted);
        cy += 32;

        drawValueRow(content_x + 32, cy, content_w - 64, "Chat Provider", wb.agent_ui.provider, theme);
        cy += 44;
        drawValueRow(content_x + 32, cy, content_w - 64, "Chat Model", wb.agent_ui.model orelse "default", theme);
        cy += 44;
        drawValueRow(content_x + 32, cy, content_w - 64, "Embedding Provider", wb.agent_ui.embedding_provider orelse "default", theme);
        cy += 44;

        // Draw the embedding model row
        const embedding_model_label = "Embedding Model";
        const embedding_model_value = wb.agent_ui.embedding_model orelse "default";
        drawValueRow(content_x + 32, cy, content_w - 64, embedding_model_label, embedding_model_value, theme);

        if (wb.settings_embedding_picker_open) {
            const row_y = cy;
            const dropdown_x = content_x + 32 + @max(220, (content_w - 64) * 0.48) - 10;
            const dropdown_y = row_y + 35;

            var max_w: f32 = 200;
            for (wb.agent_ui.embedding_models) |opt| {
                const w = renderer.Renderer.measureText(opt.label, 13.0) + 32;
                if (w > max_w) max_w = w;
            }
            const dropdown_w = max_w;
            const item_h: f32 = 30;
            const dropdown_h = @as(f32, @floatFromInt(wb.agent_ui.embedding_models.len)) * item_h + 8;

            renderer.Renderer.drawRoundedRect(dropdown_x, dropdown_y, dropdown_w, dropdown_h, 6, color(theme.colors.editor_bg));

            var item_y = dropdown_y + 4;
            for (wb.agent_ui.embedding_models) |opt| {
                // If it matches the current, maybe highlight it? (simplified)
                renderer.Renderer.drawText(opt.label, dropdown_x + 16, item_y + 6, 13.0, text_primary);
                item_y += item_h;
            }
        }

        cy += 44;
        drawToggleRow(content_x + 32, cy, content_w - 64, "HyDE Search", "Use LLM to generate hypothetical snippet for better search accuracy.", wb.agent_ui.enable_hyde, theme);
    } else if (wb.settings_modal_tab == .permissions) {
        renderer.Renderer.drawText("Permissions", content_x + 32, cy, 20.0, text_primary);
        cy += 30;
        renderer.Renderer.drawText("Agent tool and integration state.", content_x + 32, cy, 13.0, text_muted);
        cy += 32;

        drawValueRow(content_x + 32, cy, content_w - 64, "MCP Tools", if (wb.agent_ui.mcp_enabled) "enabled" else "disabled", theme);
        cy += 44;
        drawValueRow(content_x + 32, cy, content_w - 64, "MCP Status", wb.ai_mcp_status orelse "not checked", theme);
        cy += 44;
        drawValueRow(content_x + 32, cy, content_w - 64, "Agent Mode", @tagName(wb.agent_ui.session.mode), theme);
    } else if (wb.settings_modal_tab == .appearance) {
        renderer.Renderer.drawText("Appearance", content_x + 32, cy, 20.0, text_primary);
        cy += 30;
        renderer.Renderer.drawText("Theme and typography settings.", content_x + 32, cy, 13.0, text_muted);
        cy += 32;

        var ai_font_buf: [64:0]u8 = undefined;
        const ai_font_text = std.fmt.bufPrintZ(&ai_font_buf, "{d:.1}px", .{wb.user_settings.ai_panel_font_size}) catch "default";
        drawStepperRow(content_x + 32, cy, content_w - 64, "AI Panel Font Size", "Applies immediately to chat prose, markdown spacing, and wrapping.", ai_font_text, theme);
        cy += 54;

        var editor_font_buf: [64:0]u8 = undefined;
        const editor_font_text = std.fmt.bufPrintZ(&editor_font_buf, "{d:.1}px", .{wb.user_settings.font_size}) catch "default";
        drawValueRow(content_x + 32, cy, content_w - 64, "Editor Font Size", editor_font_text, theme);
    } else if (wb.settings_modal_tab == .project_forge) {
        // Draw Project Header
        renderer.Renderer.drawText(wb.workspace_name, content_x + 32, cy, 20.0, text_primary);
        cy += 28;
        renderer.Renderer.drawText("Manage project folders, agent settings, and permissions.", content_x + 32, cy, 13.0, text_muted);
        cy += 40;

        // Draw "Agent Settings"
        renderer.Renderer.drawText("Agent Settings", content_x + 32, cy, 14.0, text_primary);
        cy += 24;

        // Settings Card
        const card_h: f32 = 80;
        renderer.Renderer.drawRoundedRect(content_x + 32, cy, content_w - 64, card_h, 8, color(theme.colors.selection));
        renderer.Renderer.drawText("Security Preset", content_x + 48, cy + 16, 14.0, text_primary);
        renderer.Renderer.drawText("Choose a predefined security preset for the agent.", content_x + 48, cy + 38, 12.0, text_muted);

        // Placeholder Dropdown
        const drop_w: f32 = 120;
        renderer.Renderer.drawRoundedRect(content_x + 32 + content_w - 64 - drop_w - 16, cy + 16, drop_w, 32, 6, color(theme.colors.editor_bg));
        renderer.Renderer.drawText("Default", content_x + 32 + content_w - 64 - drop_w - 16 + 12, cy + 26, 13.0, text_primary);

        cy += card_h + 32;
    } else {
        renderer.Renderer.drawText("Coming soon", content_x + 32, cy, 20.0, text_primary);
        cy += 30;
        renderer.Renderer.drawText("This category will be backed by user and workspace settings.", content_x + 32, cy, 13.0, text_muted);
    }

    renderer.Renderer.clearClipRect();

    // Close button
    const close_btn_x = modal_x + modal_w - 40;
    const close_btn_y = modal_y + 16;
    renderer.Renderer.drawText("×", close_btn_x + 12, close_btn_y + 8, 20.0, text_muted);
}

pub fn hitTestPoint(wb: *Workbench, window_w: f32, window_h: f32, px: f32, py: f32) Hit {
    if (!wb.settings_modal_open) return .none;

    const modal_w: f32 = 860;
    const modal_h: f32 = 620;
    const modal_x: f32 = (window_w - modal_w) / 2.0;
    const modal_y: f32 = (window_h - modal_h) / 2.0;

    // Check if click is outside modal
    if (px < modal_x or px > modal_x + modal_w or py < modal_y or py > modal_y + modal_h) {
        return .close_modal;
    }

    // Check Close Button
    const close_btn_x = modal_x + modal_w - 40;
    const close_btn_y = modal_y + 16;
    if (px >= close_btn_x and px <= close_btn_x + 32 and py >= close_btn_y and py <= close_btn_y + 32) {
        return .close_modal;
    }

    // Check Sidebar Tabs
    const sidebar_w: f32 = 220;
    if (px >= modal_x and px < modal_x + sidebar_w) {
        var sy: f32 = modal_y + 20;
        const tab_h: f32 = 32;

        const tabs = [_]struct { id: Tab }{
            .{ .id = .general },
            .{ .id = .account },
            .{ .id = .permissions },
            .{ .id = .appearance },
            .{ .id = .models },
            .{ .id = .customizations },
            .{ .id = .browser },
            .{ .id = .app },
        };

        for (tabs) |tab| {
            if (py >= sy and py < sy + tab_h) return .{ .switch_tab = tab.id };
            sy += tab_h;
        }

        sy += 20 + 24; // Projects header space
        const project_tabs = [_]struct { id: Tab }{
            .{ .id = .project_forge },
        };

        for (project_tabs) |tab| {
            if (py >= sy and py < sy + tab_h) return .{ .switch_tab = tab.id };
            sy += tab_h;
        }
    }

    if (wb.settings_modal_tab == .general) {
        const content_x: f32 = modal_x + sidebar_w;
        const content_w: f32 = modal_w - sidebar_w;
        const row_x = content_x + 32;
        const row_y = modal_y + 94;
        const row_w = content_w - 64;
        if (px >= row_x and px <= row_x + row_w and py >= row_y and py <= row_y + 40) {
            return .toggle_word_wrap;
        }
        const font_row_y = row_y + 54;
        if (px >= row_x and px <= row_x + row_w and py >= font_row_y and py <= font_row_y + 44) {
            const button_w: f32 = 32;
            const gap: f32 = 8;
            const plus_x = row_x + row_w - button_w;
            const minus_x = plus_x - gap - button_w;
            const hit_pad: f32 = 6;
            if (px >= minus_x - hit_pad and px <= minus_x + button_w + hit_pad) return .ai_panel_font_decrease;
            if (px >= plus_x - hit_pad and px <= plus_x + button_w + hit_pad) return .ai_panel_font_increase;
        }
    } else if (wb.settings_modal_tab == .appearance) {
        const content_x: f32 = modal_x + sidebar_w;
        const content_w: f32 = modal_w - sidebar_w;
        const row_x = content_x + 32;
        const row_y = modal_y + 94;
        const row_w = content_w - 64;
        if (px >= row_x and px <= row_x + row_w and py >= row_y and py <= row_y + 44) {
            const button_w: f32 = 32;
            const gap: f32 = 8;
            const plus_x = row_x + row_w - button_w;
            const minus_x = plus_x - gap - button_w;
            const hit_pad: f32 = 6;
            if (px >= minus_x - hit_pad and px <= minus_x + button_w + hit_pad) return .ai_panel_font_decrease;
            if (px >= plus_x - hit_pad and px <= plus_x + button_w + hit_pad) return .ai_panel_font_increase;
        }
    } else if (wb.settings_modal_tab == .models) {
        const content_x: f32 = modal_x + sidebar_w;
        const content_w: f32 = modal_w - sidebar_w;
        const row_x = content_x + 32;
        const row_w = content_w - 64;
        var cy: f32 = modal_y + 94;
        if (px >= row_x and px <= row_x + row_w) {
            if (py >= cy and py <= cy + 40) return .ai_edit_provider;
            cy += 44;
            if (py >= cy and py <= cy + 40) return .ai_edit_model;
            cy += 44;
            if (py >= cy and py <= cy + 40) return .ai_edit_embedding_provider;
            cy += 44;

            if (wb.settings_embedding_picker_open) {
                const dropdown_x = row_x + @max(220, row_w * 0.48) - 10;
                var max_w: f32 = 200;
                for (wb.agent_ui.embedding_models) |opt| {
                    const w = renderer.Renderer.measureText(opt.label, 13.0) + 32;
                    if (w > max_w) max_w = w;
                }
                const dropdown_w = max_w;
                const dropdown_y = cy + 35;
                const item_h: f32 = 30;
                const dropdown_h = @as(f32, @floatFromInt(wb.agent_ui.embedding_models.len)) * item_h + 8;

                if (px >= dropdown_x and px <= dropdown_x + dropdown_w and py >= dropdown_y and py <= dropdown_y + dropdown_h) {
                    const index = @as(usize, @intFromFloat((py - dropdown_y - 4) / item_h));
                    if (index < wb.agent_ui.embedding_models.len) {
                        return .{ .ai_set_embedding_model = index };
                    }
                } else {
                    // Close if clicked outside the dropdown box
                    return .ai_edit_embedding_model;
                }
            }
            if (py >= cy and py <= cy + 40) return .ai_edit_embedding_model;
            cy += 44;
            if (py >= cy and py <= cy + 48) return .ai_toggle_hyde;
        }
    }

    // Returning none because the click was inside the modal but not on anything interactive yet.
    // It prevents the click from falling through to the background.
    return .none;
}

fn drawValueRow(x: f32, y: f32, w: f32, label: []const u8, value: []const u8, theme: *const workspace.Theme) void {
    const text_primary = color(theme.colors.text_primary);
    const text_muted = color(theme.colors.text_muted);
    const border = color(theme.colors.border);
    renderer.Renderer.drawRect(x, y + 35, w, 1, border);
    renderer.Renderer.drawText(label, x, y + 9, 13.0, text_primary);
    renderer.Renderer.drawText(value, x + @max(220, w * 0.48), y + 9, 13.0, text_muted);
}

fn drawToggleRow(x: f32, y: f32, w: f32, label: []const u8, desc: []const u8, enabled: bool, theme: *const workspace.Theme) void {
    const text_primary = color(theme.colors.text_primary);
    const text_muted = color(theme.colors.text_muted);
    const border = color(theme.colors.border);
    const accent = color(theme.colors.accent);
    renderer.Renderer.drawRect(x, y + 43, w, 1, border);
    renderer.Renderer.drawText(label, x, y + 4, 13.0, text_primary);
    renderer.Renderer.drawText(desc, x, y + 23, 12.0, text_muted);

    const toggle_w: f32 = 42;
    const toggle_h: f32 = 22;
    const toggle_x = x + w - toggle_w;
    const toggle_y = y + 10;
    const bg = if (enabled) accent else color(theme.colors.selection);
    renderer.Renderer.drawRoundedRect(toggle_x, toggle_y, toggle_w, toggle_h, toggle_h / 2, bg);
    const knob_x = if (enabled) toggle_x + toggle_w - 19 else toggle_x + 3;
    renderer.Renderer.drawRoundedRect(knob_x, toggle_y + 3, 16, 16, 8, text_primary);
}

fn drawStepperRow(x: f32, y: f32, w: f32, label: []const u8, desc: []const u8, value: []const u8, theme: *const workspace.Theme) void {
    const text_primary = color(theme.colors.text_primary);
    const text_muted = color(theme.colors.text_muted);
    const border = color(theme.colors.border);
    const surface = color(theme.colors.selection);
    renderer.Renderer.drawRect(x, y + 43, w, 1, border);
    renderer.Renderer.drawText(label, x, y + 4, 13.0, text_primary);
    renderer.Renderer.drawText(desc, x, y + 23, 12.0, text_muted);

    const button_w: f32 = 32;
    const button_h: f32 = 24;
    const gap: f32 = 8;
    const plus_x = x + w - button_w;
    const minus_x = plus_x - gap - button_w;
    const value_x = minus_x - 74;
    const button_y = y + 9;
    renderer.Renderer.drawText(value, value_x, y + 13, 13.0, text_muted);
    renderer.Renderer.drawRoundedRect(minus_x, button_y, button_w, button_h, 5, surface);
    renderer.Renderer.drawRoundedRect(plus_x, button_y, button_w, button_h, 5, surface);
    renderer.Renderer.drawText("-", minus_x + 12, button_y + 5, 13.0, text_primary);
    renderer.Renderer.drawText("+", plus_x + 11, button_y + 5, 13.0, text_primary);
}

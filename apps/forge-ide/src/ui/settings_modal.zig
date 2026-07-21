const std = @import("std");
const renderer = @import("forge-renderer");
const workspace = @import("forge-workspace");
const layout = @import("core/layout.zig");
const scroll_region = @import("core/scroll_region.zig");
const state = @import("core/state.zig");
const theme_loader = @import("../theme_loader.zig");
const Workbench = @import("../workbench.zig").Workbench;
const ai_model_config = @import("../workbench/ai_model_config.zig");
pub const ModelKind = ai_model_config.ModelKind;
pub const ModelEditorField = ai_model_config.ModelEditorField;

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
    editor_font_decrease,
    editor_font_increase,
    editor_line_height_decrease,
    editor_line_height_increase,
    ai_edit_provider,
    ai_edit_model,
    ai_edit_embedding_provider,
    ai_edit_embedding_model,
    ai_set_embedding_model: usize,
    ai_model_select: struct { kind: ModelKind, index: usize },
    ai_model_add: ModelKind,
    ai_model_edit: struct { kind: ModelKind, index: usize },
    ai_model_delete: struct { kind: ModelKind, index: usize },
    ai_model_editor_field: ModelEditorField,
    ai_model_editor_provider_preset: ai_model_config.ProviderPreset,
    ai_model_editor_save,
    ai_model_editor_cancel,
    ai_toggle_hyde,
    none,
};

pub fn maxScrollY(wb: *Workbench) f32 {
    const modal_h: f32 = 620;
    const visible_bottom: f32 = modal_h - 24;

    const content_h = switch (wb.settings_modal_tab) {
        .models => modelsContentHeight(wb),
        else => modal_h,
    };

    return scroll_region.region(content_h, visible_bottom).maxScrollY();
}

fn modelsContentHeight(wb: *Workbench) f32 {
    const row_h: f32 = 48;
    const chat_rows = @max(wb.agent_ui.models.len, 1);
    const embedding_rows = @max(wb.agent_ui.embedding_models.len, 1);
    const section_chrome: f32 = 32 + 8;
    const title_and_intro: f32 = 32 + 30 + 30;
    const chat_h = section_chrome + @as(f32, @floatFromInt(chat_rows)) * row_h;
    const embedding_h = section_chrome + @as(f32, @floatFromInt(embedding_rows)) * row_h;
    const gaps_and_toggle: f32 = 18 + 18 + 54 + 32;
    return title_and_intro + chat_h + embedding_h + gaps_and_toggle;
}

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
        cy -= wb.settings_modal_scroll_y;
        renderer.Renderer.drawText("Models", content_x + 32, cy, 20.0, text_primary);
        cy += 30;
        renderer.Renderer.drawText("Manage chat and embedding model presets. Click a row to make it active.", content_x + 32, cy, 13.0, text_muted);
        cy += 30;

        cy = drawModelSection(wb, content_x + 32, cy, content_w - 64, "Chat Models", .chat, wb.agent_ui.models, wb.agent_ui.model, theme);
        cy += 18;
        cy = drawModelSection(wb, content_x + 32, cy, content_w - 64, "Embedding Models", .embedding, wb.agent_ui.embedding_models, wb.agent_ui.embedding_model, theme);
        cy += 18;
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
        drawStepperRow(content_x + 32, cy, content_w - 64, "Editor Font Size", "Controls code text size in editor panes.", editor_font_text, theme);
        cy += 54;

        var line_height_buf: [64:0]u8 = undefined;
        const line_height_text = std.fmt.bufPrintZ(&line_height_buf, "{d:.2}", .{wb.user_settings.line_height}) catch "default";
        drawStepperRow(content_x + 32, cy, content_w - 64, "Editor Line Height", "Controls vertical rhythm for code, cursor, and selections.", line_height_text, theme);
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

    if (wb.settings_model_editor_open) {
        drawModelEditor(wb, modal_x, modal_y, modal_w, modal_h, theme);
    }

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

    if (wb.settings_model_editor_open) {
        if (hitModelEditor(wb, modal_x, modal_y, modal_w, modal_h, px, py)) |hit| return hit;
        return .none;
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
        var row_y = modal_y + 94;
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
        row_y += 54;
        if (px >= row_x and px <= row_x + row_w and py >= row_y and py <= row_y + 44) {
            const button_w: f32 = 32;
            const gap: f32 = 8;
            const plus_x = row_x + row_w - button_w;
            const minus_x = plus_x - gap - button_w;
            const hit_pad: f32 = 6;
            if (px >= minus_x - hit_pad and px <= minus_x + button_w + hit_pad) return .editor_font_decrease;
            if (px >= plus_x - hit_pad and px <= plus_x + button_w + hit_pad) return .editor_font_increase;
        }
        row_y += 54;
        if (px >= row_x and px <= row_x + row_w and py >= row_y and py <= row_y + 44) {
            const button_w: f32 = 32;
            const gap: f32 = 8;
            const plus_x = row_x + row_w - button_w;
            const minus_x = plus_x - gap - button_w;
            const hit_pad: f32 = 6;
            if (px >= minus_x - hit_pad and px <= minus_x + button_w + hit_pad) return .editor_line_height_decrease;
            if (px >= plus_x - hit_pad and px <= plus_x + button_w + hit_pad) return .editor_line_height_increase;
        }
    } else if (wb.settings_modal_tab == .models) {
        const content_x: f32 = modal_x + sidebar_w;
        const content_w: f32 = modal_w - sidebar_w;
        const row_x = content_x + 32;
        const row_w = content_w - 64;
        var cy: f32 = modal_y + 92 - wb.settings_modal_scroll_y;
        if (hitModelSection(.chat, wb.agent_ui.models.len, row_x, cy, row_w, px, py)) |hit| return hit;
        cy += 32 + @as(f32, @floatFromInt(@max(wb.agent_ui.models.len, 1))) * 48 + 26;
        if (hitModelSection(.embedding, wb.agent_ui.embedding_models.len, row_x, cy, row_w, px, py)) |hit| return hit;
        cy += 32 + @as(f32, @floatFromInt(@max(wb.agent_ui.embedding_models.len, 1))) * 48 + 26;
        if (px >= row_x and px <= row_x + row_w and py >= cy and py <= cy + 48) return .ai_toggle_hyde;
    }

    // Returning none because the click was inside the modal but not on anything interactive yet.
    // It prevents the click from falling through to the background.
    return .none;
}

fn modelBaseUrl(model: @import("agent/agent_composer.zig").ModelOption) []const u8 {
    if (model.base_url) |url| return url;
    if (std.mem.eql(u8, model.provider, "ollama")) return "http://127.0.0.1:11434";
    if (std.mem.eql(u8, model.provider, "openrouter")) return "https://openrouter.ai/api/v1";
    if (std.mem.eql(u8, model.provider, "nvidia")) return "https://integrate.api.nvidia.com/v1";
    if (std.mem.eql(u8, model.provider, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, model.provider, "gemini")) return "https://generativelanguage.googleapis.com/v1beta";
    return "provider default";
}

fn hitModelSection(kind: ModelKind, count: usize, x: f32, y: f32, w: f32, px: f32, py: f32) ?Hit {
    const add_x = x + w - 76;
    if (px >= add_x and px <= add_x + 76 and py >= y and py <= y + 24) return .{ .ai_model_add = kind };

    const row_h: f32 = 48;
    var row_y = y + 32;
    const rows = @max(count, 1);
    var index: usize = 0;
    while (index < rows) : (index += 1) {
        if (py >= row_y - 2 and py <= row_y + row_h - 4 and px >= x - 4 and px <= x + w + 4) {
            if (index >= count) return null;
            const action_w: f32 = 104;
            const edit_x = x + w - action_w;
            const del_x = edit_x + 48;
            if (px >= edit_x and px <= edit_x + 42 and py >= row_y + 11 and py <= row_y + 33) {
                return .{ .ai_model_edit = .{ .kind = kind, .index = index } };
            }
            if (px >= del_x and px <= del_x + 42 and py >= row_y + 11 and py <= row_y + 33) {
                return .{ .ai_model_delete = .{ .kind = kind, .index = index } };
            }
            return .{ .ai_model_select = .{ .kind = kind, .index = index } };
        }
        row_y += row_h;
    }
    return null;
}

fn drawClippedText(text: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, c: renderer.Color) void {
    renderer.Renderer.pushClipRect(x, y - 2, @max(0, w), h);
    renderer.Renderer.drawText(text, x, y, size, c);
    renderer.Renderer.popClipRect();
}

fn modelEditorValue(wb: *Workbench, field: ModelEditorField) []const u8 {
    return switch (field) {
        .label => wb.settings_model_editor_label[0..wb.settings_model_editor_label_len],
        .id => wb.settings_model_editor_id[0..wb.settings_model_editor_id_len],
        .provider => wb.settings_model_editor_provider[0..wb.settings_model_editor_provider_len],
        .base_url => wb.settings_model_editor_base_url[0..wb.settings_model_editor_base_url_len],
    };
}

fn modelEditorList(wb: *Workbench) []const @import("agent/agent_composer.zig").ModelOption {
    return switch (wb.settings_model_editor_kind) {
        .chat => wb.agent_ui.models,
        .embedding => wb.agent_ui.embedding_models,
    };
}

fn modelEditorValidation(wb: *Workbench) ?[]const u8 {
    return ai_model_config.validationMessage(
        modelEditorList(wb),
        wb.settings_model_editor_index,
        modelEditorValue(wb, .id),
        modelEditorValue(wb, .provider),
        modelEditorValue(wb, .base_url),
    );
}

fn drawInputRow(wb: *Workbench, x: f32, y: f32, w: f32, label: []const u8, field: ModelEditorField, theme: *const workspace.Theme) void {
    const active = wb.settings_model_editor_field == field;
    const bg: renderer.Color = if (active) color(theme.colors.selection) else .{ .r = 0.13, .g = 0.14, .b = 0.16, .a = 1.0 };
    const border = if (active) color(theme.colors.accent) else color(theme.colors.border);
    renderer.Renderer.drawText(label, x, y, 11.0, color(theme.colors.text_muted));
    renderer.Renderer.drawRoundedRect(x, y + 18, w, 34, 6, bg);
    renderer.Renderer.drawRoundedRect(x, y + 18, w, 1, 0, border);
    drawClippedText(modelEditorValue(wb, field), x + 10, y + 28, w - 20, 18, 12.0, color(theme.colors.text_primary));
}

fn drawModelEditor(wb: *Workbench, modal_x: f32, modal_y: f32, modal_w: f32, modal_h: f32, theme: *const workspace.Theme) void {
    _ = modal_w;
    renderer.Renderer.drawRect(modal_x, modal_y, 860, modal_h, .{ .r = 0, .g = 0, .b = 0, .a = 0.35 });

    const panel_w: f32 = 560;
    const panel_h: f32 = 430;
    const x = modal_x + (860 - panel_w) / 2;
    const y = modal_y + (modal_h - panel_h) / 2;
    renderer.Renderer.drawRoundedRect(x - 1, y - 1, panel_w + 2, panel_h + 2, 10, color(theme.colors.border));
    renderer.Renderer.drawRoundedRect(x, y, panel_w, panel_h, 10, color(theme.colors.editor_bg));

    const title = if (wb.settings_model_editor_index == null) "Add model preset" else "Edit model preset";
    renderer.Renderer.drawText(title, x + 22, y + 20, 17.0, color(theme.colors.text_primary));
    renderer.Renderer.drawText("Saved presets apply immediately to the AI panel.", x + 22, y + 46, 12.0, color(theme.colors.text_muted));

    var cy = y + 82;
    const row_w = panel_w - 44;
    drawInputRow(wb, x + 22, cy, row_w, "Name", .label, theme);
    cy += 62;
    drawInputRow(wb, x + 22, cy, row_w, "Model ID", .id, theme);
    cy += 62;
    drawInputRow(wb, x + 22, cy, row_w, "Provider", .provider, theme);
    cy += 56;
    drawProviderPresets(wb, x + 22, cy, row_w, theme);
    cy += 34;
    drawInputRow(wb, x + 22, cy, row_w, "Base URL", .base_url, theme);

    if (modelEditorValidation(wb)) |message| {
        renderer.Renderer.drawText(message, x + 22, y + panel_h - 78, 11.0, .{ .r = 0.95, .g = 0.58, .b = 0.52, .a = 1.0 });
    } else {
        renderer.Renderer.drawText("Ready to save. Changes apply immediately to this workspace.", x + 22, y + panel_h - 78, 11.0, color(theme.colors.text_muted));
    }

    const btn_y = y + panel_h - 54;
    const cancel_x = x + panel_w - 184;
    const save_x = x + panel_w - 94;
    renderer.Renderer.drawRoundedRect(cancel_x, btn_y, 76, 30, 6, color(theme.colors.selection));
    renderer.Renderer.drawText("Cancel", cancel_x + 18, btn_y + 9, 12.0, color(theme.colors.text_primary));
    renderer.Renderer.drawRoundedRect(save_x, btn_y, 72, 30, 6, color(theme.colors.accent));
    renderer.Renderer.drawText("Save", save_x + 22, btn_y + 9, 12.0, color(theme.colors.text_primary));
}

fn drawProviderPresets(wb: *Workbench, x: f32, y: f32, w: f32, theme: *const workspace.Theme) void {
    _ = w;
    const current = modelEditorValue(wb, .provider);
    renderer.Renderer.drawText("Presets", x, y, 10.5, color(theme.colors.text_muted));
    var px = x + 62;
    for (ai_model_config.provider_presets) |preset| {
        const active = std.mem.eql(u8, current, preset.id);
        const pill_w = renderer.Renderer.measureText(preset.id, 10.5) + 18;
        const bg: renderer.Color = if (active) color(theme.colors.accent) else color(theme.colors.selection);
        renderer.Renderer.drawRoundedRect(px, y - 4, pill_w, 22, 11, bg);
        renderer.Renderer.drawText(preset.id, px + 9, y + 2, 10.5, color(theme.colors.text_primary));
        px += pill_w + 6;
    }
}

fn hitModelEditor(wb: *Workbench, modal_x: f32, modal_y: f32, modal_w: f32, modal_h: f32, px: f32, py: f32) ?Hit {
    _ = wb;
    _ = modal_w;
    const panel_w: f32 = 560;
    const panel_h: f32 = 430;
    const x = modal_x + (860 - panel_w) / 2;
    const y = modal_y + (modal_h - panel_h) / 2;
    const row_w = panel_w - 44;
    var cy = y + 82;
    const fields = [_]ModelEditorField{ .label, .id, .provider, .base_url };
    for (fields, 0..) |field, field_index| {
        if (px >= x + 22 and px <= x + 22 + row_w and py >= cy + 18 and py <= cy + 52) {
            return .{ .ai_model_editor_field = field };
        }
        cy += if (field_index == 2) @as(f32, 90) else @as(f32, 62);
    }
    var preset_x = x + 22 + 62;
    const preset_y = y + 82 + 62 + 62 + 56;
    for (ai_model_config.provider_presets) |preset| {
        const pill_w = renderer.Renderer.measureText(preset.id, 10.5) + 18;
        if (px >= preset_x and px <= preset_x + pill_w and py >= preset_y - 4 and py <= preset_y + 18) {
            return .{ .ai_model_editor_provider_preset = preset.preset };
        }
        preset_x += pill_w + 6;
    }
    const btn_y = y + panel_h - 54;
    const cancel_x = x + panel_w - 184;
    const save_x = x + panel_w - 94;
    if (px >= cancel_x and px <= cancel_x + 76 and py >= btn_y and py <= btn_y + 30) return .ai_model_editor_cancel;
    if (px >= save_x and px <= save_x + 72 and py >= btn_y and py <= btn_y + 30) return .ai_model_editor_save;
    return null;
}

fn drawModelSection(
    wb: *Workbench,
    x: f32,
    y: f32,
    w: f32,
    title: []const u8,
    kind: ModelKind,
    models: []const @import("agent/agent_composer.zig").ModelOption,
    active_model: ?[]const u8,
    theme: *const workspace.Theme,
) f32 {
    _ = wb;
    const text_primary = color(theme.colors.text_primary);
    const text_muted = color(theme.colors.text_muted);
    const border = color(theme.colors.border);
    const surface = color(theme.colors.selection);
    const accent = color(theme.colors.accent);

    var cy = y;
    renderer.Renderer.drawText(title, x, cy + 4, 14.0, text_primary);
    const add_x = x + w - 76;
    renderer.Renderer.drawRoundedRect(add_x, cy, 76, 24, 5, color(theme.colors.accent));
    renderer.Renderer.drawText("+ Add", add_x + 18, cy + 6, 11.5, text_primary);
    cy += 32;

    const row_h: f32 = 48;
    const visible_top: f32 = 0;
    const visible_bottom: f32 = 10000;
    var start_index: usize = 0;
    var end_index: usize = models.len;
    if (models.len > 0) {
        const first_row_y = cy;
        const first_float = @floor(@max(0, visible_top - first_row_y) / row_h);
        start_index = @min(models.len, @as(usize, @intFromFloat(first_float)));
        end_index = @min(models.len, start_index + 28);
        cy += @as(f32, @floatFromInt(start_index)) * row_h;
    }

    var index = start_index;
    while (index < end_index) : (index += 1) {
        const model = models[index];
        if (cy + row_h < visible_top) {
            cy += row_h;
            continue;
        }
        if (cy > visible_bottom) break;
        const selected = if (active_model) |active| std.mem.eql(u8, active, model.id) else false;
        if (selected) {
            renderer.Renderer.drawRoundedRect(x - 4, cy - 2, w + 8, row_h - 4, 6, .{ .r = accent.r, .g = accent.g, .b = accent.b, .a = 0.16 });
        } else {
            renderer.Renderer.drawRoundedRect(x - 4, cy - 2, w + 8, row_h - 4, 6, surface);
        }

        const action_w: f32 = 104;
        const text_w = w - action_w - 14;
        const name_w = text_w * 0.36;
        const provider_w = 74.0;
        const id_w = text_w * 0.28;
        const url_w = text_w - name_w - provider_w - id_w - 24;

        drawClippedText(model.label, x + 10, cy + 7, name_w, 16, 12.5, text_primary);
        drawClippedText(model.provider, x + 10 + name_w + 8, cy + 7, provider_w, 16, 11.0, text_muted);
        drawClippedText(model.id, x + 10, cy + 26, id_w + name_w, 14, 10.5, text_muted);
        drawClippedText(modelBaseUrl(model), x + 10 + name_w + id_w + 16, cy + 26, url_w, 14, 10.5, text_muted);

        const edit_x = x + w - action_w;
        const del_x = edit_x + 48;
        renderer.Renderer.drawRoundedRect(edit_x, cy + 11, 42, 22, 5, .{ .r = 0.2, .g = 0.22, .b = 0.26, .a = 1.0 });
        renderer.Renderer.drawText("Edit", edit_x + 10, cy + 16, 10.5, text_primary);
        renderer.Renderer.drawRoundedRect(del_x, cy + 11, 42, 22, 5, .{ .r = 0.26, .g = 0.16, .b = 0.16, .a = 1.0 });
        renderer.Renderer.drawText("Del", del_x + 12, cy + 16, 10.5, .{ .r = 0.95, .g = 0.5, .b = 0.5, .a = 1.0 });
        _ = kind;
        cy += row_h;
    }
    if (end_index < models.len) {
        cy += @as(f32, @floatFromInt(models.len - end_index)) * row_h;
    }

    if (models.len == 0) {
        renderer.Renderer.drawRoundedRect(x - 4, cy - 2, w + 8, 38, 6, surface);
        renderer.Renderer.drawText("No models configured.", x + 10, cy + 10, 12.0, text_muted);
        cy += 42;
    }

    renderer.Renderer.drawRect(x, cy, w, 1, border);
    return cy + 8;
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

const std = @import("std");
const ai_model_config = @import("ai_model_config.zig");

pub fn openSettingsModal(wb: anytype) !void {
    if (!wb.settings_modal_open) {
        wb.previous_focus = wb.focused_panel;
    }
    wb.settings_modal_open = true;
    wb.focused_panel = .settings_modal;
    wb.settings_modal_scroll_y = 0;
}

pub fn closeSettingsModal(wb: anytype) void {
    wb.settings_modal_open = false;
    wb.settings_model_editor_open = false;
    if (wb.focused_panel == .settings_modal) {
        wb.focused_panel = if (wb.previous_focus == .settings_modal) .editor else wb.previous_focus;
    }
}

fn modelList(wb: anytype, kind: ai_model_config.ModelKind) []const @import("../ui/agent/agent_composer.zig").ModelOption {
    return switch (kind) {
        .chat => wb.agent_ui.models,
        .embedding => wb.agent_ui.embedding_models,
    };
}

fn setModelEditorField(wb: anytype, field: ai_model_config.ModelEditorField, value: []const u8) void {
    switch (field) {
        .label => {
            const len = @min(value.len, wb.settings_model_editor_label.len);
            @memcpy(wb.settings_model_editor_label[0..len], value[0..len]);
            wb.settings_model_editor_label_len = len;
        },
        .id => {
            const len = @min(value.len, wb.settings_model_editor_id.len);
            @memcpy(wb.settings_model_editor_id[0..len], value[0..len]);
            wb.settings_model_editor_id_len = len;
        },
        .provider => {
            const len = @min(value.len, wb.settings_model_editor_provider.len);
            @memcpy(wb.settings_model_editor_provider[0..len], value[0..len]);
            wb.settings_model_editor_provider_len = len;
        },
        .base_url => {
            const len = @min(value.len, wb.settings_model_editor_base_url.len);
            @memcpy(wb.settings_model_editor_base_url[0..len], value[0..len]);
            wb.settings_model_editor_base_url_len = len;
        },
    }
}

fn modelEditorSlice(wb: anytype, field: ai_model_config.ModelEditorField) []const u8 {
    return switch (field) {
        .label => wb.settings_model_editor_label[0..wb.settings_model_editor_label_len],
        .id => wb.settings_model_editor_id[0..wb.settings_model_editor_id_len],
        .provider => wb.settings_model_editor_provider[0..wb.settings_model_editor_provider_len],
        .base_url => wb.settings_model_editor_base_url[0..wb.settings_model_editor_base_url_len],
    };
}

pub fn openSettingsModelEditor(wb: anytype, kind: ai_model_config.ModelKind, index: ?usize) !void {
    wb.settings_modal_open = true;
    wb.settings_modal_tab = .models;
    wb.focused_panel = .settings_modal;
    wb.settings_model_editor_open = true;
    wb.settings_model_editor_kind = kind;
    wb.settings_model_editor_index = index;
    wb.settings_model_editor_field = .label;

    const list = modelList(wb, kind);
    if (index) |i| {
        if (i < list.len) {
            const model = list[i];
            setModelEditorField(wb, .label, model.label);
            setModelEditorField(wb, .id, model.id);
            setModelEditorField(wb, .provider, model.provider);
            setModelEditorField(wb, .base_url, model.base_url orelse ai_model_config.baseUrlForProvider(model.provider) orelse "");
            return;
        }
    }

    const next_index = list.len + 1;
    const provider = if (kind == .chat) "openrouter" else "ollama";
    var label_buf: [96]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buf, "Custom {s} Model {d}", .{ @tagName(kind), next_index });
    var id_buf: [128]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{s}-{d}", .{ if (kind == .chat) "custom/model" else "custom-embed-model", next_index });
    setModelEditorField(wb, .label, label);
    setModelEditorField(wb, .id, id);
    setModelEditorField(wb, .provider, provider);
    setModelEditorField(wb, .base_url, ai_model_config.baseUrlForProvider(provider) orelse "");
}

pub fn closeSettingsModelEditor(wb: anytype) void {
    wb.settings_model_editor_open = false;
}

pub fn focusSettingsModelEditorField(wb: anytype, field: ai_model_config.ModelEditorField) void {
    wb.settings_model_editor_field = field;
}

pub fn applySettingsModelProviderPreset(wb: anytype, preset: ai_model_config.ProviderPreset) void {
    setModelEditorField(wb, .provider, ai_model_config.providerId(preset));
    setModelEditorField(wb, .base_url, ai_model_config.providerBaseUrl(preset));
    wb.settings_model_editor_field = .id;
}

pub fn focusNextSettingsModelEditorField(wb: anytype) void {
    wb.settings_model_editor_field = switch (wb.settings_model_editor_field) {
        .label => .id,
        .id => .provider,
        .provider => .base_url,
        .base_url => .label,
    };
}

pub fn appendSettingsModelEditorText(wb: anytype, text: []const u8) void {
    if (text.len == 0) return;
    switch (wb.settings_model_editor_field) {
        .label => {
            const n = @min(text.len, wb.settings_model_editor_label.len - wb.settings_model_editor_label_len);
            @memcpy(wb.settings_model_editor_label[wb.settings_model_editor_label_len .. wb.settings_model_editor_label_len + n], text[0..n]);
            wb.settings_model_editor_label_len += n;
        },
        .id => {
            const n = @min(text.len, wb.settings_model_editor_id.len - wb.settings_model_editor_id_len);
            @memcpy(wb.settings_model_editor_id[wb.settings_model_editor_id_len .. wb.settings_model_editor_id_len + n], text[0..n]);
            wb.settings_model_editor_id_len += n;
        },
        .provider => {
            const n = @min(text.len, wb.settings_model_editor_provider.len - wb.settings_model_editor_provider_len);
            @memcpy(wb.settings_model_editor_provider[wb.settings_model_editor_provider_len .. wb.settings_model_editor_provider_len + n], text[0..n]);
            wb.settings_model_editor_provider_len += n;
        },
        .base_url => {
            const n = @min(text.len, wb.settings_model_editor_base_url.len - wb.settings_model_editor_base_url_len);
            @memcpy(wb.settings_model_editor_base_url[wb.settings_model_editor_base_url_len .. wb.settings_model_editor_base_url_len + n], text[0..n]);
            wb.settings_model_editor_base_url_len += n;
        },
    }
}

pub fn backspaceSettingsModelEditor(wb: anytype) void {
    switch (wb.settings_model_editor_field) {
        .label => {
            if (wb.settings_model_editor_label_len > 0) wb.settings_model_editor_label_len -= 1;
        },
        .id => {
            if (wb.settings_model_editor_id_len > 0) wb.settings_model_editor_id_len -= 1;
        },
        .provider => {
            if (wb.settings_model_editor_provider_len > 0) wb.settings_model_editor_provider_len -= 1;
        },
        .base_url => {
            if (wb.settings_model_editor_base_url_len > 0) wb.settings_model_editor_base_url_len -= 1;
        },
    }
}

pub fn saveSettingsModelEditor(wb: anytype) !void {
    const list = modelList(wb, wb.settings_model_editor_kind);
    if (ai_model_config.validationMessage(
        list,
        wb.settings_model_editor_index,
        modelEditorSlice(wb, .id),
        modelEditorSlice(wb, .provider),
        modelEditorSlice(wb, .base_url),
    )) |message| {
        try wb.setStatus(message);
        return error.InvalidModelConfig;
    }
    try ai_model_config.upsert(
        wb,
        wb.settings_model_editor_kind,
        wb.settings_model_editor_index,
        modelEditorSlice(wb, .label),
        modelEditorSlice(wb, .id),
        modelEditorSlice(wb, .provider),
        modelEditorSlice(wb, .base_url),
    );
    wb.settings_model_editor_open = false;
    try wb.setStatus("Model preset saved");
}

pub fn handleSettingsModalClick(wb: anytype, hit: @import("../ui/settings_modal.zig").Hit) !void {
    switch (hit) {
        .close_modal => closeSettingsModal(wb),
        .switch_tab => |tab| {
            wb.settings_modal_tab = tab;
            wb.settings_modal_scroll_y = 0;
        },
        .toggle_word_wrap => try wb.dispatch(.settings_toggle_word_wrap),
        .ai_panel_font_decrease => try wb.setAiPanelFontSize(wb.user_settings.ai_panel_font_size - 0.5),
        .ai_panel_font_increase => try wb.setAiPanelFontSize(wb.user_settings.ai_panel_font_size + 0.5),
        .editor_font_decrease => try wb.setEditorFontSize(wb.user_settings.font_size - 0.5),
        .editor_font_increase => try wb.setEditorFontSize(wb.user_settings.font_size + 0.5),
        .editor_line_height_decrease => try wb.setEditorLineHeight(wb.user_settings.line_height - 0.05),
        .editor_line_height_increase => try wb.setEditorLineHeight(wb.user_settings.line_height + 0.05),
        .agent_edit_mode_next => try wb.setAgentEditMode(wb.agent_ui.edit_mode.next()),
        .ai_edit_provider => try wb.dispatch(.ai_edit_provider),
        .ai_edit_model => try wb.dispatch(.ai_edit_model),
        .ai_edit_embedding_provider => try wb.dispatch(.ai_edit_embedding_provider),
        .ai_edit_embedding_model => try wb.dispatch(.ai_edit_embedding_model),
        .ai_set_embedding_model => |index| try wb.dispatch(.{ .ai_set_embedding_model = index }),
        .ai_model_select => |sel| try wb.dispatch(.{ .ai_model_select = .{ .kind = sel.kind, .index = sel.index } }),
        .ai_model_add => |kind| try wb.dispatch(.{ .ai_model_add = kind }),
        .ai_model_edit => |sel| try wb.dispatch(.{ .ai_model_edit = .{ .kind = sel.kind, .index = sel.index } }),
        .ai_model_delete => |sel| try wb.dispatch(.{ .ai_model_delete = .{ .kind = sel.kind, .index = sel.index } }),
        .ai_model_editor_field => |field| focusSettingsModelEditorField(wb, field),
        .ai_model_editor_provider_preset => |preset| applySettingsModelProviderPreset(wb, preset),
        .ai_model_editor_save => try saveSettingsModelEditor(wb),
        .ai_model_editor_cancel => closeSettingsModelEditor(wb),
        .ai_toggle_hyde => try wb.dispatch(.ai_toggle_hyde),
        .none => {},
    }
}

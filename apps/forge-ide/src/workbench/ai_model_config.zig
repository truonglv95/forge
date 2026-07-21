const std = @import("std");
const composer = @import("../ui/agent/agent_composer.zig");
const ai_config_io = @import("ai_config_io.zig");

pub const ModelKind = enum { chat, embedding };

fn listFor(wb: anytype, kind: ModelKind) []const composer.ModelOption {
    return switch (kind) {
        .chat => wb.agent_ui.models,
        .embedding => wb.agent_ui.embedding_models,
    };
}

fn replaceList(wb: anytype, kind: ModelKind, models: []const composer.ModelOption) void {
    switch (kind) {
        .chat => {
            freeModels(wb.allocator, wb.agent_ui.models);
            wb.agent_ui.models = models;
        },
        .embedding => {
            freeModels(wb.allocator, wb.agent_ui.embedding_models);
            wb.agent_ui.embedding_models = models;
        },
    }
}

fn freeModels(allocator: std.mem.Allocator, models: []const composer.ModelOption) void {
    for (models) |model| {
        allocator.free(model.id);
        allocator.free(model.label);
        allocator.free(model.provider);
        if (model.base_url) |url| allocator.free(url);
    }
    if (models.len > 0) allocator.free(models);
}

fn cloneModel(allocator: std.mem.Allocator, model: composer.ModelOption) !composer.ModelOption {
    return .{
        .id = try allocator.dupe(u8, model.id),
        .label = try allocator.dupe(u8, model.label),
        .provider = try allocator.dupe(u8, model.provider),
        .base_url = if (model.base_url) |url| try allocator.dupe(u8, url) else null,
    };
}

fn persist(wb: anytype, kind: ModelKind) !void {
    switch (kind) {
        .chat => try ai_config_io.writeAiCustomModels(wb.allocator, wb.io, wb.workspace_root, wb.agent_ui.models),
        .embedding => try ai_config_io.writeAiCustomEmbeddingModels(wb.allocator, wb.io, wb.workspace_root, wb.agent_ui.embedding_models),
    }
}

fn baseUrlForProvider(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "ollama")) return "http://127.0.0.1:11434";
    if (std.mem.eql(u8, provider, "openrouter")) return "https://openrouter.ai/api/v1";
    if (std.mem.eql(u8, provider, "nvidia")) return "https://integrate.api.nvidia.com/v1";
    if (std.mem.eql(u8, provider, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, provider, "gemini")) return "https://generativelanguage.googleapis.com/v1beta";
    return null;
}

fn containsModelId(models: []const composer.ModelOption, id: []const u8) bool {
    for (models) |model| {
        if (std.mem.eql(u8, model.id, id)) return true;
    }
    return false;
}

fn activeModelId(wb: anytype, kind: ModelKind) ?[]const u8 {
    return switch (kind) {
        .chat => wb.agent_ui.model,
        .embedding => wb.agent_ui.embedding_model,
    };
}

fn nextProvider(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "ollama")) return "openrouter";
    if (std.mem.eql(u8, provider, "openrouter")) return "nvidia";
    if (std.mem.eql(u8, provider, "nvidia")) return "openai";
    if (std.mem.eql(u8, provider, "openai")) return "gemini";
    return "ollama";
}

pub fn select(wb: anytype, kind: ModelKind, index: usize) !void {
    const models = listFor(wb, kind);
    if (index >= models.len) return;
    const model = models[index];
    switch (kind) {
        .chat => {
            if (wb.agent_ui.model) |old| wb.allocator.free(old);
            wb.agent_ui.model = try wb.allocator.dupe(u8, model.id);
            wb.allocator.free(wb.agent_ui.provider);
            wb.agent_ui.provider = try wb.allocator.dupe(u8, model.provider);
            try ai_config_io.writeAiModel(wb.allocator, wb.io, wb.workspace_root, model.id);
            try ai_config_io.writeAiProvider(wb.allocator, wb.io, wb.workspace_root, model.provider);
            if (model.base_url) |url| try applyChatBaseUrl(wb, model.provider, url);
        },
        .embedding => {
            if (wb.agent_ui.embedding_model) |old| wb.allocator.free(old);
            wb.agent_ui.embedding_model = try wb.allocator.dupe(u8, model.id);
            if (wb.agent_ui.embedding_provider) |old| wb.allocator.free(old);
            wb.agent_ui.embedding_provider = try wb.allocator.dupe(u8, model.provider);
            try ai_config_io.writeAiEmbeddingModel(wb.allocator, wb.io, wb.workspace_root, model.id);
            try ai_config_io.writeAiEmbeddingProvider(wb.allocator, wb.io, wb.workspace_root, model.provider);
            if (model.base_url) |url| {
                if (wb.agent_ui.embedding_url) |old| wb.allocator.free(old);
                wb.agent_ui.embedding_url = try wb.allocator.dupe(u8, url);
                try ai_config_io.writeTomlQuotedString(wb.allocator, wb.io, wb.workspace_root, "ai", "embedding_url", url);
            }
        },
    }
}

fn applyChatBaseUrl(wb: anytype, provider: []const u8, url: []const u8) !void {
    if (std.mem.eql(u8, provider, "ollama")) {
        if (wb.agent_ui.ollama_url) |old| wb.allocator.free(old);
        wb.agent_ui.ollama_url = try wb.allocator.dupe(u8, url);
        try ai_config_io.writeAiOllamaUrl(wb.allocator, wb.io, wb.workspace_root, url);
    } else if (std.mem.eql(u8, provider, "openrouter") or std.mem.eql(u8, provider, "nvidia") or std.mem.eql(u8, provider, "openai")) {
        if (wb.agent_ui.openrouter_url) |old| wb.allocator.free(old);
        wb.agent_ui.openrouter_url = try wb.allocator.dupe(u8, url);
        try ai_config_io.writeTomlQuotedString(wb.allocator, wb.io, wb.workspace_root, "ai", "openrouter_url", url);
    }
}

pub fn add(wb: anytype, kind: ModelKind) !void {
    const source = listFor(wb, kind);
    var next = try wb.allocator.alloc(composer.ModelOption, source.len + 1);
    errdefer wb.allocator.free(next);
    for (source, 0..) |model, index| next[index] = try cloneModel(wb.allocator, model);

    const next_index = source.len + 1;
    const provider = if (kind == .chat) "openrouter" else "ollama";
    var id_buf: [96]u8 = undefined;
    var suffix = next_index;
    var id = try std.fmt.bufPrint(&id_buf, "{s}-{d}", .{ if (kind == .chat) "custom/model" else "custom-embed-model", suffix });
    while (containsModelId(source, id)) {
        suffix += 1;
        id = try std.fmt.bufPrint(&id_buf, "{s}-{d}", .{ if (kind == .chat) "custom/model" else "custom-embed-model", suffix });
    }
    var label_buf: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buf, "Custom {s} Model {d}", .{ @tagName(kind), suffix });
    next[source.len] = .{
        .id = try wb.allocator.dupe(u8, id),
        .label = try wb.allocator.dupe(u8, label),
        .provider = try wb.allocator.dupe(u8, provider),
        .base_url = if (baseUrlForProvider(provider)) |url| try wb.allocator.dupe(u8, url) else null,
    };
    replaceList(wb, kind, next);
    try persist(wb, kind);
}

pub fn edit(wb: anytype, kind: ModelKind, index: usize) !void {
    const source = listFor(wb, kind);
    if (index >= source.len) return;
    var next = try wb.allocator.alloc(composer.ModelOption, source.len);
    errdefer wb.allocator.free(next);
    for (source, 0..) |model, i| {
        if (i == index) {
            const provider = nextProvider(model.provider);
            next[i] = .{
                .id = try wb.allocator.dupe(u8, model.id),
                .label = try wb.allocator.dupe(u8, model.label),
                .provider = try wb.allocator.dupe(u8, provider),
                .base_url = if (baseUrlForProvider(provider)) |url| try wb.allocator.dupe(u8, url) else null,
            };
        } else {
            next[i] = try cloneModel(wb.allocator, model);
        }
    }
    replaceList(wb, kind, next);
    try persist(wb, kind);
}

pub fn delete(wb: anytype, kind: ModelKind, index: usize) !void {
    const source = listFor(wb, kind);
    if (index >= source.len or source.len == 0) return;
    const deleted_id = source[index].id;
    const deleted_active = if (activeModelId(wb, kind)) |active| std.mem.eql(u8, active, deleted_id) else false;
    var next = try wb.allocator.alloc(composer.ModelOption, source.len - 1);
    errdefer wb.allocator.free(next);
    var out_i: usize = 0;
    for (source, 0..) |model, i| {
        if (i == index) continue;
        next[out_i] = try cloneModel(wb.allocator, model);
        out_i += 1;
    }
    replaceList(wb, kind, next);
    try persist(wb, kind);
    if (deleted_active and next.len > 0) {
        try select(wb, kind, 0);
    }
}

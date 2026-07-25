const std = @import("std");
const workspace = @import("forge-workspace");
const config_store = @import("config_store.zig");

pub fn writeTomlKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    // Delegate to the unified config_store. This ensures consistent
    // no-op detection (skip if value unchanged) and section handling
    // (no duplicate sections) across all AI config writes.
    try config_store.writeKey(allocator, io, root, section_name, key, value);
}

pub fn writeTomlQuotedString(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    try config_store.writeStringKey(allocator, io, root, section_name, key, value);
}

/// Write both model AND provider to the [ai] section in a single file
/// read-modify-write cycle. Skips if both keys already have the correct
/// values.
pub fn writeAiChatConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    model: []const u8,
    provider: []const u8,
) !void {
    try config_store.writeStringKeys(allocator, io, root, "ai", &.{
        .{ .key = "model", .value = model },
        .{ .key = "provider", .value = provider },
    });
}

/// Write both embedding model AND provider in a single file operation.
pub fn writeAiEmbeddingConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    model: []const u8,
    provider: []const u8,
) !void {
    try config_store.writeStringKeys(allocator, io, root, "ai", &.{
        .{ .key = "embedding_model", .value = model },
        .{ .key = "embedding_provider", .value = provider },
    });
}

pub fn writeAiProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    provider: []const u8,
) !void {
    try config_store.writeStringKey(allocator, io, root, "ai", "provider", provider);
}

pub fn writeAiModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    model: []const u8,
) !void {
    try config_store.writeStringKey(allocator, io, root, "ai", "model", model);
}

pub fn writeAiOllamaUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    url: []const u8,
) !void {
    try config_store.writeStringKey(allocator, io, root, "ai", "ollama_url", url);
}

pub fn writeAiMcp(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    enabled: bool,
) !void {
    try config_store.writeBoolKey(allocator, io, root, "ai", "mcp", enabled);
}

pub fn writeAiEmbeddingProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    provider: []const u8,
) !void {
    try config_store.writeStringKey(allocator, io, root, "ai", "embedding_provider", provider);
}

pub fn writeAiEmbeddingModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    model: []const u8,
) !void {
    try config_store.writeStringKey(allocator, io, root, "ai", "embedding_model", model);
}

pub fn writeAiEnableHyde(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    enabled: bool,
) !void {
    try config_store.writeBoolKey(allocator, io, root, "ai", "enable_hyde", enabled);
}

pub fn writeAiCustomModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    models: []const @import("../ui/agent/agent_composer.zig").ModelOption,
) !void {
    const serialized = try serializeModels(allocator, models);
    defer allocator.free(serialized);
    try config_store.writeStringKey(allocator, io, root, "ai", "custom_models", serialized);
}

pub fn writeAiCustomEmbeddingModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    models: []const @import("../ui/agent/agent_composer.zig").ModelOption,
) !void {
    const serialized = try serializeModels(allocator, models);
    defer allocator.free(serialized);
    try config_store.writeStringKey(allocator, io, root, "ai", "custom_embedding_models", serialized);
}

fn serializeModels(
    allocator: std.mem.Allocator,
    models: []const @import("../ui/agent/agent_composer.zig").ModelOption,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (models, 0..) |model, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, model.id);
        try out.append(allocator, '|');
        try out.appendSlice(allocator, model.label);
        try out.append(allocator, '|');
        try out.appendSlice(allocator, model.provider);
        if (model.base_url) |url| {
            if (url.len > 0) {
                try out.append(allocator, '|');
                try out.appendSlice(allocator, url);
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

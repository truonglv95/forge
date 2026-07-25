const std = @import("std");
const workspace = @import("forge-workspace");

pub fn writeTomlKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    // Always prefer the workspace `.forge/settings.toml` for AI settings
    // so users get per-project configuration (different provider/model
    // per project). The previous logic only wrote to the workspace file
    // when the key ALREADY existed — meaning the very first time the
    // user changed a setting it would silently fall through to the home
    // file (~/.forge/settings.toml) and never appear in the project.
    //
    // New behavior:
    //   1. Read workspace .forge/settings.toml (may not exist yet).
    //   2. upsertTomlValue handles both edit-existing and create-new
    //      cases (it appends a new [section] block if the section is
    //      missing entirely).
    //   3. Atomically replace the workspace file. Creates the file if
    //      it doesn't exist yet.
    //   4. Home file (~/.forge/settings.toml) is only used as a fallback
    //      when the workspace is read-only (e.g. opened from /tmp).
    const wp = workspace.WorkspacePath.parse(".forge/settings.toml") catch return;

    var workspace_content: []const u8 = "";
    var snap_owned: ?workspace.snapshot.FileSnapshot = null;
    if (workspace.snapshot.FileSnapshot.read(allocator, io, root, wp)) |snap_const| {
        snap_owned = snap_const;
        workspace_content = snap_owned.?.content;
    } else |_| {}

    defer if (snap_owned) |*s| s.deinit();

    // upsertTomlValue: if key exists → edit; if section exists but key
    // doesn't → append key to section; if section doesn't exist → append
    // new [section] block with the key. This handles all 3 cases.
    const updated = @import("settings.zig").upsertTomlValue(
        allocator,
        workspace_content,
        section_name,
        key,
        value,
    ) catch |err| {
        // Workspace write failed (e.g. read-only mount). Fall back to home.
        if (err == error.WorkspaceFailed or err == error.AccessDenied) {
            try writeTomlKeyHomeFallback(allocator, io, section_name, key, value);
            return;
        }
        return err;
    };
    defer allocator.free(updated);

    // Ensure the .forge directory exists in the workspace before writing.
    // The first time a user opens a project and changes an AI setting,
    // the .forge directory won't exist yet — atomic.replaceFile calls
    // createFile which fails if the parent directory is missing.
    // createDirPath is idempotent (no-op if the directory exists).
    root.dir.createDirPath(io, ".forge") catch {};

    workspace.atomic.replaceFile(io, root, wp, updated) catch |err| {
        // Workspace write failed — try home as fallback.
        if (err == error.WorkspaceFailed or err == error.AccessDenied) {
            try writeTomlKeyHomeFallback(allocator, io, section_name, key, value);
            return;
        }
        return err;
    };
}

/// Home fallback for writeTomlKey — used only when the workspace is
/// read-only. Reads ~/.forge/settings.toml (creating it if missing),
/// upserts the key, and writes it back.
fn writeTomlKeyHomeFallback(
    allocator: std.mem.Allocator,
    io: std.Io,
    section_name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const settings_abs = try workspace.global_store.joinHome(allocator, "settings.toml");
    defer allocator.free(settings_abs);

    const content = workspace.global_store.readAbsoluteFile(allocator, io, settings_abs) catch {
        // File doesn't exist — create with section + key.
        const default_content = try std.fmt.allocPrint(allocator, "[{s}]\n{s} = {s}\n", .{ section_name, key, value });
        defer allocator.free(default_content);
        try workspace.global_store.replaceAbsoluteFile(io, settings_abs, default_content);
        return;
    };
    defer allocator.free(content);

    const updated = try @import("settings.zig").upsertTomlValue(allocator, content, section_name, key, value);
    defer allocator.free(updated);
    try workspace.global_store.replaceAbsoluteFile(io, settings_abs, updated);
}

pub fn writeTomlQuotedString(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    var quoted_buf: [512]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{value}) catch {
        return;
    };
    try writeTomlKey(allocator, io, root, section_name, key, quoted);
}

pub fn writeAiProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    provider: []const u8,
) !void {
    try writeTomlQuotedString(allocator, io, root, "ai", "provider", provider);
}

pub fn writeAiModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    model: []const u8,
) !void {
    try writeTomlQuotedString(allocator, io, root, "ai", "model", model);
}

pub fn writeAiOllamaUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    url: []const u8,
) !void {
    try writeTomlQuotedString(allocator, io, root, "ai", "ollama_url", url);
}

pub fn writeAiMcp(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    enabled: bool,
) !void {
    const value = if (enabled) "true" else "false";
    try writeTomlKey(allocator, io, root, "ai", "mcp", value);
}

pub fn writeAiEmbeddingProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    provider: []const u8,
) !void {
    try writeTomlQuotedString(allocator, io, root, "ai", "embedding_provider", provider);
}

pub fn writeAiEmbeddingModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    model: []const u8,
) !void {
    try writeTomlQuotedString(allocator, io, root, "ai", "embedding_model", model);
}

pub fn writeAiEnableHyde(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    enabled: bool,
) !void {
    const value = if (enabled) "true" else "false";
    try writeTomlKey(allocator, io, root, "ai", "enable_hyde", value);
}

pub fn writeAiCustomModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    models: []const @import("../ui/agent/agent_composer.zig").ModelOption,
) !void {
    const serialized = try serializeModels(allocator, models);
    defer allocator.free(serialized);
    try writeTomlQuotedString(allocator, io, root, "ai", "custom_models", serialized);
}

pub fn writeAiCustomEmbeddingModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    models: []const @import("../ui/agent/agent_composer.zig").ModelOption,
) !void {
    const serialized = try serializeModels(allocator, models);
    defer allocator.free(serialized);
    try writeTomlQuotedString(allocator, io, root, "ai", "custom_embedding_models", serialized);
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

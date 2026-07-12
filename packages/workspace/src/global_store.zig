const std = @import("std");
const path_mod = @import("path.zig");

pub const sessions_subdir = "sessions";
pub const config_file = "config.toml";
pub const recent_workspaces_file = "recent_workspaces.toml";

pub const GlobalStoreError = error{
    NoHome,
    PathTooLong,
};

threadlocal var test_forge_home_override: ?[]const u8 = null;

/// Returns the Forge home directory (`$FORGE_HOME` or `~/.forge`).
pub fn homeDirPath(allocator: std.mem.Allocator) GlobalStoreError![]u8 {
    if (test_forge_home_override) |override| {
        return allocator.dupe(u8, override) catch return error.PathTooLong;
    }
    if (std.c.getenv("FORGE_HOME")) |override| {
        return allocator.dupe(u8, std.mem.span(override)) catch return error.PathTooLong;
    }
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.forge", .{std.mem.span(home)}) catch return error.PathTooLong;
}

pub fn joinHome(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const home = try homeDirPath(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, suffix }) catch error.PathTooLong;
}

fn mkdirAll(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    _ = std.c.mkdir(z, 0o755);
}

/// Creates a directory at an absolute path (all intermediate dirs as needed).
pub fn mkdirAllAbsolute(abs_path: []const u8) !void {
    // Walk each prefix and mkdir
    var i: usize = 1;
    while (i <= abs_path.len) : (i += 1) {
        if (i == abs_path.len or abs_path[i] == '/') {
            var buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{abs_path[0..i]}) catch continue;
            _ = std.c.mkdir(z, 0o755);
        }
    }
}

pub fn ensureLayout(io: std.Io) !void {
    const home = homeDirPath(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(home);
    mkdirAll(home) catch {};
    var sessions_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sessions_path = try std.fmt.bufPrint(&sessions_buf, "{s}/{s}", .{ home, sessions_subdir });
    mkdirAll(sessions_path) catch {};

    var settings_buf: [std.fs.max_path_bytes]u8 = undefined;
    const settings_path = try std.fmt.bufPrint(&settings_buf, "{s}/settings.toml", .{home});
    var file = std.Io.Dir.openFileAbsolute(io, settings_path, .{}) catch {
        const default_settings =
            \\[ai]
            \\provider = "auto"
            \\custom_models = "qwen3.5:35b|Qwen 3.5 35B (Ollama)|ollama,qwen2.5-coder:7b|Qwen 2.5 Coder 7B (Ollama)|ollama,gemini-2.5-flash|Gemini 2.5 Flash|gemini,gemini-2.5-pro|Gemini 2.5 Pro|gemini,gemini-2.0-flash|Gemini 2.0 Flash|gemini,openai/gpt-4o-mini|GPT-4o Mini (OpenRouter)|openrouter,anthropic/claude-sonnet-4|Claude Sonnet 4 (OpenRouter)|openrouter,z-ai/glm-5.2|GLM-5.2 (NVIDIA)|nvidia,meta/llama-3.1-70b-instruct|Llama 3.1 70B (NVIDIA)|nvidia"
            \\
            \\[ghost_completion]
            \\provider = "ollama"
            \\model = "qwen2.5-coder:7b"
            \\
        ;
        try replaceAbsoluteFile(io, settings_path, default_settings);
        return;
    };
    file.close(io);

    var theme_buf: [std.fs.max_path_bytes]u8 = undefined;
    const theme_path = try std.fmt.bufPrint(&theme_buf, "{s}/theme.toml", .{home});
    var theme_file = std.Io.Dir.openFileAbsolute(io, theme_path, .{}) catch {
        try replaceAbsoluteFile(io, theme_path, "");
        return;
    };
    theme_file.close(io);
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {}
    return path[0..end];
}

/// Stable absolute workspace identity for ~/.forge storage keys.
pub fn canonicalWorkspacePathFromRoot(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) ![]u8 {
    if (std.fs.path.isAbsolute(root.path)) {
        return try allocator.dupe(u8, trimTrailingSeparators(root.path));
    }
    const resolved = try root.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(resolved);
    const len = if (resolved.len > 0 and resolved[resolved.len - 1] == 0) resolved.len - 1 else resolved.len;
    return try allocator.dupe(u8, trimTrailingSeparators(resolved[0..len]));
}

/// String-only fallback when an opened workspace root is unavailable.
pub fn canonicalWorkspacePath(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8) ![]u8 {
    var abs: []const u8 = workspace_path;
    var owned_abs: ?[]u8 = null;
    defer if (owned_abs) |path| allocator.free(path);

    if (!std.fs.path.isAbsolute(workspace_path)) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(io, &cwd_buf);
        const cwd = cwd_buf[0..cwd_len];
        if (workspace_path.len == 0 or std.mem.eql(u8, workspace_path, ".")) {
            abs = cwd;
        } else {
            owned_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, workspace_path });
            abs = owned_abs.?;
        }
    }

    var end = abs.len;
    while (end > 1 and (abs[end - 1] == '/' or abs[end - 1] == '\\')) : (end -= 1) {}
    return try allocator.dupe(u8, abs[0..end]);
}

fn sessionDirForStorageKey(allocator: std.mem.Allocator, storage_key: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, storage_key);
    var suffix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_buf, "sessions/{x}", .{hash});
    return try joinHome(allocator, suffix);
}

pub fn getIndexDir(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) ![]u8 {
    const canonical = try canonicalWorkspacePathFromRoot(allocator, io, root);
    defer allocator.free(canonical);
    const hash = std.hash.Wyhash.hash(0, canonical);
    var suffix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_buf, "sessions/{x}/index/v1", .{hash});
    return try joinHome(allocator, suffix);
}

pub fn getSessionDir(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) ![]u8 {
    const canonical = try canonicalWorkspacePathFromRoot(allocator, io, root);
    defer allocator.free(canonical);
    return sessionDirForStorageKey(allocator, canonical);
}

/// Legacy lookup for data written before workspace paths were canonicalized.
pub fn getSessionDirForStorageKey(allocator: std.mem.Allocator, storage_key: []const u8) ![]u8 {
    return sessionDirForStorageKey(allocator, storage_key);
}

pub fn getExtensionsDir(allocator: std.mem.Allocator) ![]u8 {
    return try joinHome(allocator, "extensions");
}

pub fn getParsersDir(allocator: std.mem.Allocator) ![]u8 {
    return try joinHome(allocator, "parsers");
}

pub fn deleteAbsoluteFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub fn readAbsoluteFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

pub fn replaceAbsoluteFile(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
    }

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

    {
        var file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }

    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

pub fn appendAbsoluteFile(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirPath(.cwd(), io, dir) catch {};
    }

    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = false,
        .lock = .exclusive,
    });
    defer file.close(io);

    const stat = try file.stat(io);
    try file.writePositionalAll(io, content, stat.size);
}

pub fn setForgeHomeOverride(path: []const u8) !void {
    test_forge_home_override = path;
}

pub fn clearForgeHomeOverride() void {
    test_forge_home_override = null;
}

test "homeDirPath honors FORGE_HOME" {
    const allocator = std.testing.allocator;
    const abs = "/tmp/forge-home-test";
    try setForgeHomeOverride(abs);
    defer clearForgeHomeOverride();

    const home = try homeDirPath(allocator);
    defer allocator.free(home);
    try std.testing.expectEqualStrings(abs, home);
}

test "getSessionDir canonicalizes relative workspace paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const abs = try std.fmt.allocPrint(allocator, "/tmp/forge-test-{s}", .{tmp.sub_path});
    defer allocator.free(abs);
    try setForgeHomeOverride(abs);
    defer clearForgeHomeOverride();
    try ensureLayout(io);

    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");
    const canonical = try canonicalWorkspacePathFromRoot(allocator, io, root);
    defer allocator.free(canonical);
    const from_root = try getSessionDir(allocator, io, root);
    defer allocator.free(from_root);
    const from_abs = try getSessionDirForStorageKey(allocator, canonical);
    defer allocator.free(from_abs);
    try std.testing.expectEqualStrings(from_root, from_abs);
}

test "replaceAbsoluteFile writes readable content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const abs = try std.fmt.allocPrint(allocator, "/tmp/forge-test-{s}", .{tmp.sub_path});
    defer allocator.free(abs);
    try setForgeHomeOverride(abs);
    defer clearForgeHomeOverride();
    try ensureLayout(io);

    const path = try joinHome(allocator, "sessions/test.json");
    defer allocator.free(path);

    try replaceAbsoluteFile(io, path, "{\"ok\":true}\n");
    const body = try readAbsoluteFile(allocator, io, path);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "ok") != null);
}

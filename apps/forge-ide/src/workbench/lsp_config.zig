const std = @import("std");
const workspace = @import("forge-workspace");
const lsp = @import("forge-lsp");

pub const LanguageServerContribution = struct {
    language_id: []const u8,
    server: []const u8,
    args: []const u8 = "",
    file_pattern: []const u8,
    server_resolver: []const u8 = "",
    extension_id: []const u8,
};

pub fn loadBundledExtensions(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *lsp.Registry,
) !void {
    const bundled = [_]LanguageServerContribution{
        .{ .language_id = "zig", .server = "zls", .args = "", .file_pattern = "*.zig", .server_resolver = "vscode-zig-zls", .extension_id = "forge.bundled.zig" },
        .{ .language_id = "typescript", .server = "typescript-language-server", .args = "--stdio", .file_pattern = "*.ts", .extension_id = "forge.bundled.typescript" },
        .{ .language_id = "typescriptreact", .server = "typescript-language-server", .args = "--stdio", .file_pattern = "*.tsx", .extension_id = "forge.bundled.typescript" },
        .{ .language_id = "javascript", .server = "typescript-language-server", .args = "--stdio", .file_pattern = "*.js", .extension_id = "forge.bundled.typescript" },
        .{ .language_id = "javascriptreact", .server = "typescript-language-server", .args = "--stdio", .file_pattern = "*.jsx", .extension_id = "forge.bundled.typescript" },
        .{ .language_id = "python", .server = "pyright-langserver", .args = "--stdio", .file_pattern = "*.py", .extension_id = "forge.bundled.python" },
        .{ .language_id = "go", .server = "gopls", .args = "", .file_pattern = "*.go", .extension_id = "forge.bundled.go" },
        .{ .language_id = "rust", .server = "rust-analyzer", .args = "", .file_pattern = "*.rs", .extension_id = "forge.bundled.rust" },
    };
    for (bundled) |contribution| {
        try addContribution(allocator, io, registry, contribution);
    }
}

pub fn addContribution(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *lsp.Registry,
    contribution: LanguageServerContribution,
) !void {
    const server = try resolveServer(allocator, io, contribution.server, contribution.server_resolver);
    defer allocator.free(server);
    try registry.add(allocator, .{
        .language_id = contribution.language_id,
        .server = server,
        .args = contribution.args,
        .file_pattern = contribution.file_pattern,
        .extension_id = contribution.extension_id,
        .state = .configured,
    });
}

pub fn loadGlobalAndWorkspace(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    registry: *lsp.Registry,
) !void {
    try loadGlobal(allocator, io, registry);
    try loadWorkspace(allocator, io, root, registry);
}

fn resolveServer(allocator: std.mem.Allocator, io: std.Io, server: []const u8, resolver: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, resolver, "vscode-zig-zls")) return try allocator.dupe(u8, server);
    if (try findVsCodeZls(allocator, io)) |path| return path;
    return try allocator.dupe(u8, server);
}

fn findVsCodeZls(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const home_c = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_c);
    const roots = [_][]const u8{
        "Library/Application Support/Code/User/globalStorage/ziglang.vscode-zig/zls",
        "Library/Application Support/Cursor/User/globalStorage/ziglang.vscode-zig/zls",
        ".vscode/extensions/ziglang.vscode-zig/zls",
        ".cursor/extensions/ziglang.vscode-zig/zls",
    };

    for (roots) |rel| {
        const root_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, rel });
        defer allocator.free(root_path);
        if (try findZlsUnderDirectory(allocator, io, root_path)) |path| return path;
    }
    return null;
}

fn findZlsUnderDirectory(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}/zls", .{ root_path, entry.name });
        if (fileExists(io, candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn loadGlobal(allocator: std.mem.Allocator, io: std.Io, registry: *lsp.Registry) !void {
    const settings_abs = workspace.global_store.joinHome(allocator, "settings.toml") catch return;
    defer allocator.free(settings_abs);
    const content = workspace.global_store.readAbsoluteFile(allocator, io, settings_abs) catch return;
    defer allocator.free(content);
    try parseIntoRegistry(allocator, io, content, "global-settings", registry);
}

fn loadWorkspace(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, registry: *lsp.Registry) !void {
    var file = root.dir.openFile(io, "forge.toml", .{}) catch return;
    defer file.close(io);
    const stat = file.stat(io) catch return;
    const size: usize = @intCast(stat.size);
    const content = allocator.alloc(u8, size) catch return;
    defer allocator.free(content);
    const read_len = file.readPositionalAll(io, content, 0) catch return;
    if (read_len != size) return;
    try parseIntoRegistry(allocator, io, content, "workspace-forge", registry);
}

fn parseIntoRegistry(
    allocator: std.mem.Allocator,
    io: std.Io,
    content: []const u8,
    source_id: []const u8,
    registry: *lsp.Registry,
) !void {
    var in_lsp = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            in_lsp = std.mem.eql(u8, line, "[lsp]");
            continue;
        }

        if (!in_lsp) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, "servers")) continue;

        const value = parseString(std.mem.trim(u8, line[eq + 1 ..], " \t")) orelse continue;
        try parseServers(allocator, io, value, source_id, registry);
    }
}

fn parseServers(
    allocator: std.mem.Allocator,
    io: std.Io,
    value: []const u8,
    source_id: []const u8,
    registry: *lsp.Registry,
) !void {
    var entries = std.mem.splitScalar(u8, value, ',');
    while (entries.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
        if (entry.len == 0) continue;

        var fields = std.mem.splitScalar(u8, entry, '|');
        const language_id = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const server = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const args = std.mem.trim(u8, fields.next() orelse "", " \t");
        const pattern = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const resolver = std.mem.trim(u8, fields.next() orelse "", " \t");

        if (language_id.len == 0 or server.len == 0 or pattern.len == 0) continue;
        try addContribution(allocator, io, registry, .{
            .language_id = language_id,
            .server = server,
            .args = args,
            .file_pattern = pattern,
            .extension_id = source_id,
            .server_resolver = resolver,
        });
    }
}

fn parseString(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

test "lsp config parses compact server list" {
    const allocator = std.testing.allocator;
    var registry = lsp.Registry.init(allocator);
    defer registry.deinit(allocator);

    try parseIntoRegistry(
        allocator,
        std.testing.io,
        \\[lsp]
        \\servers = "typescript|typescript-language-server|--stdio|*.ts,javascript|typescript-language-server|--stdio|*.js"
    ,
        "test",
        &registry,
    );

    const ts = registry.findForPath("src/app.ts").?;
    try std.testing.expectEqualStrings("typescript", ts.language_id);
    try std.testing.expectEqualStrings("typescript-language-server", ts.server);
    try std.testing.expectEqualStrings("--stdio", ts.args);

    const js = registry.findForPath("src/app.js").?;
    try std.testing.expectEqualStrings("javascript", js.language_id);
}

test "lsp config includes builtin defaults" {
    const allocator = std.testing.allocator;
    var registry = lsp.Registry.init(allocator);
    defer registry.deinit(allocator);

    try loadBundledExtensions(allocator, std.testing.io, &registry);

    const zig = registry.findForPath("apps/forge-ide/src/main.zig").?;
    try std.testing.expectEqualStrings("zig", zig.language_id);
    try std.testing.expect(zig.server.len > 0);

    const tsx = registry.findForPath("src/App.tsx").?;
    try std.testing.expectEqualStrings("typescriptreact", tsx.language_id);
}

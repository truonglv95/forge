const std = @import("std");
const workspace = @import("forge-workspace");
const renderer = @import("forge-renderer");
const plugin = @import("forge-plugin");

pub fn loadTheme(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    host: ?*const plugin.Host,
) !workspace.Theme {
    var theme_settings = workspace.ThemeSettings{};

    const wp = workspace.WorkspacePath.parse("forge.toml") catch {
        var theme = workspace.Theme.darkDefault();
        applyToRenderer(&theme);
        return theme;
    };
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch {
        var theme = workspace.Theme.darkDefault();
        applyToRenderer(&theme);
        return theme;
    };
    defer snap.deinit();

    const config = workspace.Config.parse(snap.content) catch {
        var theme = workspace.Theme.darkDefault();
        applyToRenderer(&theme);
        return theme;
    };
    theme_settings = config.theme;

    var active_extension_theme: ?[]const u8 = null;
    defer if (active_extension_theme) |qualified| allocator.free(qualified);

    if (try readUserSettings(allocator, io, root)) |user_content| {
        defer allocator.free(user_content);
        const user = workspace.ThemeSettings.parseSection(user_content) catch workspace.ThemeOverrides{};
        theme_settings.mergeFrom(user);
        if (readExtensionThemeId(user_content)) |qualified| {
            active_extension_theme = try allocator.dupe(u8, qualified);
        }
    }

    var theme = try workspace.Theme.fromSettings(allocator, config.tab_width, theme_settings);

    if (host) |extension_host| {
        if (active_extension_theme) |qualified| {
            if (extension_host.contributions.findThemeByQualifiedId(qualified)) |contrib| {
                const overrides = plugin.theme_contrib.loadThemeOverrides(allocator, io, root, contrib) catch workspace.ThemeOverrides{};
                theme_settings.mergeFrom(overrides);
                theme.deinit();
                theme = try workspace.Theme.fromSettings(allocator, config.tab_width, theme_settings);
            }
        }
    }

    applyToRenderer(&theme);
    return theme;
}

fn readExtensionThemeId(source: []const u8) ?[]const u8 {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
            raw_line[0..index]
        else
            raw_line;
        const line = std.mem.trim(u8, &std.ascii.whitespace, without_comment);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') continue;
            section = std.mem.trim(u8, &std.ascii.whitespace, line[1 .. line.len - 1]);
            continue;
        }
        if (!std.mem.eql(u8, section, "extension_theme")) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, &std.ascii.whitespace, line[0..equals]);
        const value = std.mem.trim(u8, &std.ascii.whitespace, line[equals + 1 ..]);
        if (!std.mem.eql(u8, key, "active")) continue;
        if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
        return value[1 .. value.len - 1];
    }
    return null;
}

pub fn readUserSettings(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !?[]const u8 {
    // Read from global ~/.forge/theme.toml
    const settings_abs = workspace.global_store.joinHome(allocator, "theme.toml") catch return null;
    defer allocator.free(settings_abs);
    const content = workspace.global_store.readAbsoluteFile(allocator, io, settings_abs) catch |err| switch (err) {
        error.FileNotFound => {
            // Fallback: try project-local .forge/settings.toml
            const wp = workspace.WorkspacePath.parse(".forge/settings.toml") catch return null;
            var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return null;
            defer snap.deinit();
            return try allocator.dupe(u8, snap.content);
        },
        else => return null,
    };
    return content;
}

pub fn toColor(rgba: workspace.Rgba) renderer.Color {
    return .{ .r = rgba.r, .g = rgba.g, .b = rgba.b, .a = rgba.a };
}

pub fn applyShellColors(theme: workspace.Theme) void {
    const state = @import("ui/core/state.zig");
    const c = theme.colors;
    if (state.root_view) |v| v.bg_color = toColor(c.workbench_bg);
    if (state.header_view) |v| v.bg_color = toColor(c.header_bg);
    if (state.activity_view) |v| v.bg_color = toColor(c.activity_bg);
    if (state.explorer_view) |v| v.bg_color = toColor(c.sidebar_bg);
    if (state.agent_view) |v| v.bg_color = toColor(c.agent_bg);
    if (state.editor_view) |v| v.bg_color = toColor(c.editor_bg);
    if (state.panel_view) |v| v.bg_color = toColor(c.panel_bg);
    if (state.border_view) |v| v.bg_color = toColor(c.border);
    if (state.status_view) |v| v.bg_color = toColor(c.status_bg);
}

pub fn syncFontMetrics(theme: *workspace.Theme) void {
    var cw: f32 = 0;
    var lh: f32 = 0;
    var baseline: f32 = 0;
    renderer.Renderer.getFontMetrics(theme.editor_font_size, &cw, &lh, &baseline);
    const mono_cw = renderer.Renderer.measureTextWithStyle("M", theme.editor_font_size, renderer.TextStyle.mono);
    theme.measured_char_width = if (mono_cw > 0) mono_cw else cw;
    theme.measured_line_height = lh;
    theme.measured_baseline = baseline;
}

pub fn applyToRenderer(theme: *workspace.Theme) void {
    renderer.Renderer.applyThemeFont(theme.*);
    syncFontMetrics(theme);
    renderer.Renderer.setEditorTextMetrics(theme.editor_font_size, theme.lineHeight(), theme.baseline());
}

test "loadTheme falls back to defaults when forge.toml missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    const theme = try loadTheme(allocator, io, root, null);
    try std.testing.expectEqual(workspace.ThemePreset.dark, theme.preset);
    try std.testing.expect(theme.measured_char_width > 0);
}

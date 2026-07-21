const std = @import("std");
const workspace = @import("forge-workspace");

pub const Settings = struct {
    tab_width: u8 = 4,
    font_size: f32 = 14,
    ai_panel_font_size: f32 = @import("../ui/agent/metrics.zig").markdown.default_body_font_size,
    word_wrap: bool = false,
    format_on_save: bool = false,
    terminal_shell: ?[]const u8 = null,
    // Ghost text / inline AI completion settings ([ghost_completion] section)
    ghost_provider: []const u8 = "ai",
    ghost_model: []const u8 = "gemini-2.5-flash",
    ghost_ollama_url: []const u8 = "http://127.0.0.1:11434",
    ghost_enabled: bool = true,
    /// When ghost_provider == "ai", which forge-ai provider to use
    /// (e.g. "gemini", "openai", "openrouter", "nvidia", "ollama", "auto").
    ghost_ai_provider: []const u8 = "auto",
    /// Optional base URL override for the AI provider.
    ghost_ai_base_url: ?[]const u8 = null,
    owns_ghost_provider: bool = false,
    owns_ghost_model: bool = false,
    owns_ghost_ollama_url: bool = false,
    owns_ghost_ai_provider: bool = false,

    pub fn deinit(self: *Settings, allocator: std.mem.Allocator) void {
        if (self.terminal_shell) |shell| allocator.free(shell);
        if (self.owns_ghost_provider) allocator.free(self.ghost_provider);
        if (self.owns_ghost_model) allocator.free(self.ghost_model);
        if (self.owns_ghost_ollama_url) allocator.free(self.ghost_ollama_url);
        if (self.owns_ghost_ai_provider) allocator.free(self.ghost_ai_provider);
        if (self.ghost_ai_base_url) |url| allocator.free(url);
        self.* = undefined;
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !Settings {
    var settings: Settings = .{};
    errdefer settings.deinit(allocator);

    const home_settings = workspace.global_store.joinHome(allocator, "settings.toml") catch return settings;
    defer allocator.free(home_settings);
    if (workspace.global_store.readAbsoluteFile(allocator, io, home_settings)) |content| {
        defer allocator.free(content);
        try parseSettingsContent(&settings, allocator, content);
    } else |_| {}

    if (readWorkspaceSettings(allocator, io, root)) |content| {
        defer allocator.free(content);
        try parseSettingsContent(&settings, allocator, content);
    } else |_| {}

    return settings;
}

fn readWorkspaceSettings(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) ![]u8 {
    var file = try root.dir.openFile(io, ".forge/settings.toml", .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

fn parseSettingsContent(settings: *Settings, allocator: std.mem.Allocator, content: []const u8) !void {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');
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
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, &std.ascii.whitespace, line[0..equals]);
        const value = std.mem.trim(u8, &std.ascii.whitespace, line[equals + 1 ..]);

        if (std.mem.eql(u8, section, "editor")) {
            if (std.mem.eql(u8, key, "tab_width")) {
                const parsed = std.fmt.parseInt(u8, value, 10) catch continue;
                if (parsed >= 1 and parsed <= 16) settings.tab_width = parsed;
            } else if (std.mem.eql(u8, key, "font_size")) {
                const parsed = std.fmt.parseFloat(f32, value) catch continue;
                if (parsed >= 8 and parsed <= 48) settings.font_size = parsed;
            } else if (std.mem.eql(u8, key, "word_wrap")) {
                settings.word_wrap = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "format_on_save")) {
                settings.format_on_save = std.mem.eql(u8, value, "true");
            }
        } else if (std.mem.eql(u8, section, "terminal")) {
            if (std.mem.eql(u8, key, "shell")) {
                const unquoted = parseQuoted(value) orelse value;
                if (settings.terminal_shell) |old| allocator.free(old);
                settings.terminal_shell = try allocator.dupe(u8, unquoted);
            }
        } else if (std.mem.eql(u8, section, "ai_panel")) {
            if (std.mem.eql(u8, key, "font_size")) {
                const parsed = std.fmt.parseFloat(f32, value) catch continue;
                if (parsed >= 12 and parsed <= 20) settings.ai_panel_font_size = parsed;
            }
        } else if (std.mem.eql(u8, section, "ghost_completion")) {
            if (std.mem.eql(u8, key, "provider")) {
                const unquoted = parseQuoted(value) orelse value;
                if (std.mem.eql(u8, unquoted, "ollama") or std.mem.eql(u8, unquoted, "gemini") or std.mem.eql(u8, unquoted, "ai")) {
                    try replaceStringSetting(allocator, &settings.ghost_provider, &settings.owns_ghost_provider, unquoted);
                }
            } else if (std.mem.eql(u8, key, "model")) {
                const unquoted = parseQuoted(value) orelse value;
                try replaceStringSetting(allocator, &settings.ghost_model, &settings.owns_ghost_model, unquoted);
            } else if (std.mem.eql(u8, key, "ollama_url")) {
                const unquoted = parseQuoted(value) orelse value;
                try replaceStringSetting(allocator, &settings.ghost_ollama_url, &settings.owns_ghost_ollama_url, unquoted);
            } else if (std.mem.eql(u8, key, "ai_provider")) {
                const unquoted = parseQuoted(value) orelse value;
                try replaceStringSetting(allocator, &settings.ghost_ai_provider, &settings.owns_ghost_ai_provider, unquoted);
            } else if (std.mem.eql(u8, key, "ai_base_url")) {
                const unquoted = parseQuoted(value) orelse value;
                if (settings.ghost_ai_base_url) |old| allocator.free(old);
                settings.ghost_ai_base_url = try allocator.dupe(u8, unquoted);
            } else if (std.mem.eql(u8, key, "enabled")) {
                settings.ghost_enabled = std.mem.eql(u8, value, "true");
            }
        }
    }
}

fn replaceStringSetting(allocator: std.mem.Allocator, field: *[]const u8, owned: *bool, value: []const u8) !void {
    if (owned.*) allocator.free(field.*);
    field.* = try allocator.dupe(u8, value);
    owned.* = true;
}

pub fn applyToTheme(settings: Settings, theme: *workspace.Theme) void {
    theme.editor_font_size = settings.font_size;
    theme.tab_width = settings.tab_width;
    @import("../ui/agent/chat_markdown.zig").configureFontSize(settings.ai_panel_font_size);
}

pub fn writeAiPanelFontSize(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    font_size: f32,
) !void {
    const value = std.math.clamp(font_size, 12.0, 20.0);
    const value_text = try std.fmt.allocPrint(allocator, "{d:.1}", .{value});
    defer allocator.free(value_text);

    if (readWorkspaceSettings(allocator, io, root)) |workspace_content| {
        defer allocator.free(workspace_content);
        if (settingsContentHasKey(workspace_content, "ai_panel", "font_size")) {
            const updated = try upsertTomlValue(allocator, workspace_content, "ai_panel", "font_size", value_text);
            defer allocator.free(updated);
            const wp = try workspace.WorkspacePath.parse(".forge/settings.toml");
            try workspace.atomic.replaceFile(io, root, wp, updated);
            return;
        }
    } else |_| {}

    const home_settings = try workspace.global_store.joinHome(allocator, "settings.toml");
    defer allocator.free(home_settings);

    const content = workspace.global_store.readAbsoluteFile(allocator, io, home_settings) catch {
        const default_content = try std.fmt.allocPrint(allocator, "[ai_panel]\nfont_size = {s}\n", .{value_text});
        defer allocator.free(default_content);
        try workspace.global_store.replaceAbsoluteFile(io, home_settings, default_content);
        return;
    };
    defer allocator.free(content);

    const updated = try upsertTomlValue(allocator, content, "ai_panel", "font_size", value_text);
    defer allocator.free(updated);
    try workspace.global_store.replaceAbsoluteFile(io, home_settings, updated);
}

pub fn writeWordWrap(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    enabled: bool,
) !void {
    const value = if (enabled) "true" else "false";

    if (readWorkspaceSettings(allocator, io, root)) |workspace_content| {
        defer allocator.free(workspace_content);
        if (settingsContentHasKey(workspace_content, "editor", "word_wrap")) {
            const updated = try upsertTomlValue(allocator, workspace_content, "editor", "word_wrap", value);
            defer allocator.free(updated);
            const wp = try workspace.WorkspacePath.parse(".forge/settings.toml");
            try workspace.atomic.replaceFile(io, root, wp, updated);
            return;
        }
    } else |_| {}

    const home_settings = try workspace.global_store.joinHome(allocator, "settings.toml");
    defer allocator.free(home_settings);

    const content = workspace.global_store.readAbsoluteFile(allocator, io, home_settings) catch {
        const default_content = try std.fmt.allocPrint(allocator, "[editor]\nword_wrap = {s}\n", .{value});
        defer allocator.free(default_content);
        try workspace.global_store.replaceAbsoluteFile(io, home_settings, default_content);
        return;
    };
    defer allocator.free(content);

    const updated = try upsertTomlValue(allocator, content, "editor", "word_wrap", value);
    defer allocator.free(updated);
    try workspace.global_store.replaceAbsoluteFile(io, home_settings, updated);
}

fn settingsContentHasKey(content: []const u8, section_name: []const u8, key_name: []const u8) bool {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            section = std.mem.trim(u8, &std.ascii.whitespace, trimmed[1 .. trimmed.len - 1]);
            continue;
        }
        if (std.mem.eql(u8, section, section_name) and lineKeyMatches(trimmed, key_name)) return true;
    }
    return false;
}

pub fn upsertTomlValue(
    allocator: std.mem.Allocator,
    content: []const u8,
    section_name: []const u8,
    key_name: []const u8,
    value_text: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_target = false;
    var skipping_duplicate_target = false;
    var saw_target = false;
    var wrote_key = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (in_target and !wrote_key) {
                try appendSettingLine(allocator, &out, key_name, value_text);
                wrote_key = true;
            }

            const name = std.mem.trim(u8, &std.ascii.whitespace, trimmed[1 .. trimmed.len - 1]);
            if (std.mem.eql(u8, name, section_name)) {
                if (saw_target) {
                    in_target = false;
                    skipping_duplicate_target = true;
                    continue;
                }
                saw_target = true;
                in_target = true;
                skipping_duplicate_target = false;
            } else {
                in_target = false;
                skipping_duplicate_target = false;
            }

            try appendRawLine(allocator, &out, raw_line);
            continue;
        }

        if (skipping_duplicate_target) continue;

        if (in_target and lineKeyMatches(trimmed, key_name)) {
            if (!wrote_key) {
                try appendSettingLine(allocator, &out, key_name, value_text);
                wrote_key = true;
            }
            continue;
        }

        try appendRawLine(allocator, &out, raw_line);
    }

    if (in_target and !wrote_key) {
        try appendSettingLine(allocator, &out, key_name, value_text);
        wrote_key = true;
    }

    if (!saw_target) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.append(allocator, '[');
        try out.appendSlice(allocator, section_name);
        try out.appendSlice(allocator, "]\n");
        try appendSettingLine(allocator, &out, key_name, value_text);
    }

    while (out.items.len > 1 and out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n') {
        _ = out.pop();
    }
    return try out.toOwnedSlice(allocator);
}

fn appendRawLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw_line: []const u8) !void {
    try out.appendSlice(allocator, raw_line);
    try out.append(allocator, '\n');
}

fn appendSettingLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key_name: []const u8, value_text: []const u8) !void {
    try out.appendSlice(allocator, key_name);
    try out.appendSlice(allocator, " = ");
    try out.appendSlice(allocator, value_text);
    try out.append(allocator, '\n');
}

fn lineKeyMatches(trimmed_line: []const u8, key_name: []const u8) bool {
    if (trimmed_line.len == 0 or trimmed_line[0] == '#') return false;
    const equals = std.mem.indexOfScalar(u8, trimmed_line, '=') orelse return false;
    const key = std.mem.trim(u8, &std.ascii.whitespace, trimmed_line[0..equals]);
    return std.mem.eql(u8, key, key_name);
}

pub fn mergeExtensionTheme(allocator: std.mem.Allocator, existing: []const u8, qualified: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_extension_theme = false;
    var wrote_section = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = std.mem.trim(u8, &std.ascii.whitespace, trimmed[1 .. trimmed.len - 1]);
            if (in_extension_theme) {
                try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "active = \"{s}\"\n", .{qualified}));
                wrote_section = true;
            }
            in_extension_theme = std.mem.eql(u8, name, "extension_theme");
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            continue;
        }
        if (in_extension_theme and std.mem.startsWith(u8, std.mem.trim(u8, &std.ascii.whitespace, trimmed), "active")) {
            continue;
        }
        if (trimmed.len > 0 or raw_line.len == 0) {
            try out.appendSlice(allocator, raw_line);
            try out.append(allocator, '\n');
        }
    }

    if (!wrote_section) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, "\n[extension_theme]\n");
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "active = \"{s}\"\n", .{qualified}));
    }

    return try out.toOwnedSlice(allocator);
}

fn parseQuoted(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

test "upsertTomlValue updates one section and removes duplicate target sections" {
    const input =
        \\[theme]
        \\font_size = 14
        \\
        \\[ai_panel]
        \\font_size = 14.5
        \\
        \\[editor]
        \\word_wrap = true
        \\
        \\[ai_panel]
        \\font_size = 15.0
        \\
    ;
    const out = try upsertTomlValue(std.testing.allocator, input, "ai_panel", "font_size", "16.0");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "[theme]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[editor]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size = 16.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size = 14.5") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size = 15.0") == null);

    const first = std.mem.indexOf(u8, out, "[ai_panel]") orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOfPos(u8, out, first + 1, "[ai_panel]") == null);
}

test "upsertTomlValue appends missing setting to existing section" {
    const input =
        \\[editor]
        \\font_size = 14
        \\
    ;
    const out = try upsertTomlValue(std.testing.allocator, input, "editor", "word_wrap", "true");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "[editor]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size = 14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "word_wrap = true") != null);
}

test "parseSettingsContent uses latest ai panel font size" {
    const input =
        \\[ai_panel]
        \\font_size = 14.5
        \\
        \\[ai_panel]
        \\font_size = 16.0
        \\
    ;
    var settings: Settings = .{};
    defer settings.deinit(std.testing.allocator);

    try parseSettingsContent(&settings, std.testing.allocator, input);
    try std.testing.expectEqual(@as(f32, 16.0), settings.ai_panel_font_size);
}

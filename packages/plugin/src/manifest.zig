const std = @import("std");
const util = @import("forge-util");
const root_mod = @import("root.zig");
const wasm_mod = @import("wasm_runtime.zig");

pub const CommandContribution = struct {
    id: []const u8,
    title: []const u8,
};

pub const ThemeContribution = struct {
    id: []const u8,
    label: []const u8,
    path: []const u8,
};

pub const KeybindingContribution = struct {
    key: []const u8,
    command: []const u8,
};

pub const LanguageContribution = struct {
    id: []const u8,
    server: []const u8,
    args: []const u8 = "",
    file_pattern: []const u8,
};

pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    api_version: root_mod.ApiVersion,
    entry: []const u8 = "",
    runtime: wasm_mod.RuntimeKind = .native,
    commands: []CommandContribution,
    themes: []ThemeContribution,
    keybindings: []KeybindingContribution,
    languages: []LanguageContribution,
    wasm_max_memory: u32 = 0,
    wasm_max_read_bytes: u32 = 0,
    wasm_max_string_len: u32 = 0,
    wasm_max_path_len: u32 = 0,
    wasm_max_lsp_request: u32 = 0,
    wasm_max_lsp_response: u32 = 0,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.entry);
        for (self.commands) |cmd| {
            allocator.free(cmd.id);
            allocator.free(cmd.title);
        }
        allocator.free(self.commands);
        for (self.themes) |theme| {
            allocator.free(theme.id);
            allocator.free(theme.label);
            allocator.free(theme.path);
        }
        allocator.free(self.themes);
        for (self.keybindings) |binding| {
            allocator.free(binding.key);
            allocator.free(binding.command);
        }
        allocator.free(self.keybindings);
        for (self.languages) |lang| {
            allocator.free(lang.id);
            allocator.free(lang.server);
            allocator.free(lang.args);
            allocator.free(lang.file_pattern);
        }
        allocator.free(self.languages);
        self.* = undefined;
    }
};

pub const ParseError = error{
    InvalidSyntax,
    InvalidValue,
    UnknownKey,
    MissingExtensionSection,
    OutOfMemory,
};

const Section = enum {
    none,
    extension,
    commands,
    themes,
    keybindings,
    languages,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Manifest {
    var manifest = Manifest{
        .id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, ""),
        .version = try allocator.dupe(u8, "0.0.0"),
        .api_version = .{ .major = 1, .minor = 0 },
        .commands = &.{},
        .themes = &.{},
        .keybindings = &.{},
        .languages = &.{},
    };
    errdefer manifest.deinit(allocator);

    var section: Section = .none;
    var commands: std.ArrayList(CommandContribution) = .empty;
    var themes: std.ArrayList(ThemeContribution) = .empty;
    var keybindings: std.ArrayList(KeybindingContribution) = .empty;
    var languages: std.ArrayList(LanguageContribution) = .empty;
    errdefer freePartialLists(allocator, &commands, &themes, &keybindings, &languages);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
            raw_line[0..index]
        else
            raw_line;
        const line = util.trimAscii(without_comment);
        if (line.len == 0) continue;

        if (line[0] == '[') {
            section = parseSectionName(line) orelse return error.UnknownKey;
            continue;
        }

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSyntax;
        const key = util.trimAscii(line[0..equals]);
        const value = util.trimAscii(line[equals + 1 ..]);

        switch (section) {
            .commands => try parseCommandsRow(allocator, key, value, &commands),
            .themes => try parseThemesRow(allocator, key, value, &themes),
            .keybindings => try parseKeybindingsRow(allocator, key, value, &keybindings),
            .languages => try parseLanguagesRow(allocator, key, value, &languages),
            .extension => try parseExtensionRow(allocator, key, value, &manifest),
            .none => {},
        }
    }

    if (manifest.id.len == 0 or manifest.name.len == 0) return error.MissingExtensionSection;
    manifest.commands = try commands.toOwnedSlice(allocator);
    manifest.themes = try themes.toOwnedSlice(allocator);
    manifest.keybindings = try keybindings.toOwnedSlice(allocator);
    manifest.languages = try languages.toOwnedSlice(allocator);
    return manifest;
}

fn parseSectionName(line: []const u8) ?Section {
    var inner = line;
    while (inner.len > 0 and inner[0] == '[') inner = inner[1..];
    while (inner.len > 0 and inner[inner.len - 1] == ']') inner = inner[0 .. inner.len - 1];
    const section = util.trimAscii(inner);
    if (std.mem.eql(u8, section, "extension")) return .extension;
    if (std.mem.eql(u8, section, "commands")) return .commands;
    if (std.mem.eql(u8, section, "themes")) return .themes;
    if (std.mem.eql(u8, section, "keybindings")) return .keybindings;
    if (std.mem.eql(u8, section, "languages")) return .languages;
    return null;
}

fn parseExtensionRow(allocator: std.mem.Allocator, key: []const u8, value: []const u8, manifest: *Manifest) ParseError!void {
    if (std.mem.eql(u8, key, "id")) {
        allocator.free(manifest.id);
        manifest.id = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "name")) {
        allocator.free(manifest.name);
        manifest.name = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "version")) {
        allocator.free(manifest.version);
        manifest.version = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "entry")) {
        allocator.free(manifest.entry);
        manifest.entry = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "api_version")) {
        const parsed = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
        manifest.api_version = .{ .major = parsed, .minor = 0 };
    } else if (std.mem.eql(u8, key, "runtime")) {
        const unquoted = try parseString(allocator, value);
        defer allocator.free(unquoted);
        manifest.runtime = wasm_mod.parseRuntime(unquoted) orelse return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "wasm_max_memory")) {
        manifest.wasm_max_memory = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "wasm_max_read_bytes")) {
        manifest.wasm_max_read_bytes = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "wasm_max_string_len")) {
        manifest.wasm_max_string_len = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "wasm_max_path_len")) {
        manifest.wasm_max_path_len = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "wasm_max_lsp_request")) {
        manifest.wasm_max_lsp_request = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else if (std.mem.eql(u8, key, "wasm_max_lsp_response")) {
        manifest.wasm_max_lsp_response = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
    } else {
        return error.UnknownKey;
    }
}

fn parseCommandsRow(allocator: std.mem.Allocator, key: []const u8, value: []const u8, commands: *std.ArrayList(CommandContribution)) ParseError!void {
    if (std.mem.eql(u8, key, "id")) {
        const owned = try parseString(allocator, value);
        try commands.append(allocator, .{ .id = owned, .title = try allocator.dupe(u8, owned) });
    } else if (std.mem.eql(u8, key, "title")) {
        if (commands.items.len == 0) return error.InvalidSyntax;
        const last = commands.items.len - 1;
        allocator.free(commands.items[last].title);
        commands.items[last].title = try parseString(allocator, value);
    } else {
        return error.UnknownKey;
    }
}

fn parseThemesRow(allocator: std.mem.Allocator, key: []const u8, value: []const u8, themes: *std.ArrayList(ThemeContribution)) ParseError!void {
    if (std.mem.eql(u8, key, "id")) {
        const owned = try parseString(allocator, value);
        try themes.append(allocator, .{ .id = owned, .label = try allocator.dupe(u8, owned), .path = try allocator.dupe(u8, "") });
    } else if (std.mem.eql(u8, key, "label")) {
        if (themes.items.len == 0) return error.InvalidSyntax;
        const last = themes.items.len - 1;
        allocator.free(themes.items[last].label);
        themes.items[last].label = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "path")) {
        if (themes.items.len == 0) return error.InvalidSyntax;
        const last = themes.items.len - 1;
        allocator.free(themes.items[last].path);
        themes.items[last].path = try parseString(allocator, value);
    } else {
        return error.UnknownKey;
    }
}

fn parseKeybindingsRow(allocator: std.mem.Allocator, key: []const u8, value: []const u8, keybindings: *std.ArrayList(KeybindingContribution)) ParseError!void {
    if (std.mem.eql(u8, key, "key")) {
        const owned = try parseString(allocator, value);
        try keybindings.append(allocator, .{ .key = owned, .command = try allocator.dupe(u8, "") });
    } else if (std.mem.eql(u8, key, "command")) {
        if (keybindings.items.len == 0) return error.InvalidSyntax;
        const last = keybindings.items.len - 1;
        allocator.free(keybindings.items[last].command);
        keybindings.items[last].command = try parseString(allocator, value);
    } else {
        return error.UnknownKey;
    }
}

fn parseLanguagesRow(allocator: std.mem.Allocator, key: []const u8, value: []const u8, languages: *std.ArrayList(LanguageContribution)) ParseError!void {
    if (std.mem.eql(u8, key, "id")) {
        const owned = try parseString(allocator, value);
        try languages.append(allocator, .{
            .id = owned,
            .server = try allocator.dupe(u8, ""),
            .args = try allocator.dupe(u8, ""),
            .file_pattern = try allocator.dupe(u8, ""),
        });
    } else if (std.mem.eql(u8, key, "server")) {
        if (languages.items.len == 0) return error.InvalidSyntax;
        const last = languages.items.len - 1;
        allocator.free(languages.items[last].server);
        languages.items[last].server = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "args")) {
        if (languages.items.len == 0) return error.InvalidSyntax;
        const last = languages.items.len - 1;
        allocator.free(languages.items[last].args);
        languages.items[last].args = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "file_pattern") or std.mem.eql(u8, key, "pattern")) {
        if (languages.items.len == 0) return error.InvalidSyntax;
        const last = languages.items.len - 1;
        allocator.free(languages.items[last].file_pattern);
        languages.items[last].file_pattern = try parseString(allocator, value);
    } else {
        return error.UnknownKey;
    }
}

fn parseString(allocator: std.mem.Allocator, value: []const u8) ParseError![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidValue;
    }
    return allocator.dupe(u8, value[1 .. value.len - 1]) catch return error.OutOfMemory;
}

fn freePartialLists(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(CommandContribution),
    themes: *std.ArrayList(ThemeContribution),
    keybindings: *std.ArrayList(KeybindingContribution),
    languages: *std.ArrayList(LanguageContribution),
) void {
    for (commands.items) |cmd| {
        allocator.free(cmd.id);
        allocator.free(cmd.title);
    }
    commands.deinit(allocator);
    for (themes.items) |theme| {
        allocator.free(theme.id);
        allocator.free(theme.label);
        allocator.free(theme.path);
    }
    themes.deinit(allocator);
    for (keybindings.items) |binding| {
        allocator.free(binding.key);
        allocator.free(binding.command);
    }
    keybindings.deinit(allocator);
    for (languages.items) |lang| {
        allocator.free(lang.id);
        allocator.free(lang.server);
        allocator.free(lang.args);
        allocator.free(lang.file_pattern);
    }
    languages.deinit(allocator);
}

test "manifest parses extension with commands" {
    const allocator = std.testing.allocator;
    var manifest = try parse(allocator,
        \\[extension]
        \\id = "forge.samples.hello"
        \\name = "Hello"
        \\version = "0.1.0"
        \\api_version = 1
        \\
        \\[[commands]]
        \\id = "hello.say"
        \\title = "Say Hello"
    );
    defer manifest.deinit(allocator);

    try std.testing.expectEqualStrings("forge.samples.hello", manifest.id);
    try std.testing.expectEqual(@as(usize, 1), manifest.commands.len);
    try std.testing.expectEqualStrings("hello.say", manifest.commands[0].id);
}

test "manifest parses themes keybindings and languages" {
    const allocator = std.testing.allocator;
    var manifest = try parse(allocator,
        \\[extension]
        \\id = "forge.theme.demo"
        \\name = "Demo"
        \\version = "0.1.0"
        \\api_version = 1
        \\
        \\[[themes]]
        \\id = "demo-dark"
        \\label = "Demo Dark"
        \\path = "themes/demo.toml"
        \\
        \\[[keybindings]]
        \\key = "cmd+shift+x"
        \\command = "view.extensions"
        \\
        \\[[languages]]
        \\id = "zig"
        \\server = "zig"
        \\args = "language-server"
        \\file_pattern = "*.zig"
    );
    defer manifest.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), manifest.themes.len);
    try std.testing.expectEqual(@as(usize, 1), manifest.keybindings.len);
    try std.testing.expectEqual(@as(usize, 1), manifest.languages.len);
    try std.testing.expectEqualStrings("demo-dark", manifest.themes[0].id);
    try std.testing.expectEqualStrings("view.extensions", manifest.keybindings[0].command);
}

test "manifest parses wasm sandbox limits" {
    const allocator = std.testing.allocator;
    var manifest = try parse(allocator,
        \\[extension]
        \\id = "forge.samples.wasm"
        \\name = "Wasm"
        \\version = "0.1.0"
        \\api_version = 1
        \\runtime = "wasm"
        \\wasm_max_memory = 2097152
        \\wasm_max_read_bytes = 32768
    );
    defer manifest.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2097152), manifest.wasm_max_memory);
    try std.testing.expectEqual(@as(u32, 32768), manifest.wasm_max_read_bytes);
}

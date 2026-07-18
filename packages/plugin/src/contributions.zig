const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub const ThemeContribution = struct {
    id: []const u8,
    label: []const u8,
    path: []const u8,
    extension_id: []const u8,
    extension_root: []const u8,
};

pub const KeybindingContribution = struct {
    key: []const u8,
    command: []const u8,
    extension_id: []const u8,
};

pub const LanguageContribution = struct {
    id: []const u8,
    server: []const u8,
    args: []const u8,
    file_pattern: []const u8,
    server_resolver: []const u8,
    extension_id: []const u8,
};

pub const Registry = struct {
    themes: std.ArrayList(ThemeContribution),
    keybindings: std.ArrayList(KeybindingContribution),
    languages: std.ArrayList(LanguageContribution),

    pub fn init(_: std.mem.Allocator) Registry {
        return .{
            .themes = .empty,
            .keybindings = .empty,
            .languages = .empty,
        };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.themes.items) |item| {
            allocator.free(item.id);
            allocator.free(item.label);
            allocator.free(item.path);
            allocator.free(item.extension_id);
            allocator.free(item.extension_root);
        }
        self.themes.deinit(allocator);

        for (self.keybindings.items) |item| {
            allocator.free(item.key);
            allocator.free(item.command);
            allocator.free(item.extension_id);
        }
        self.keybindings.deinit(allocator);

        for (self.languages.items) |item| {
            allocator.free(item.id);
            allocator.free(item.server);
            allocator.free(item.args);
            allocator.free(item.file_pattern);
            allocator.free(item.server_resolver);
            allocator.free(item.extension_id);
        }
        self.languages.deinit(allocator);
    }

    pub fn clear(self: *Registry, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.* = init(allocator);
    }

    pub fn addTheme(self: *Registry, allocator: std.mem.Allocator, theme: ThemeContribution) !void {
        try self.themes.append(allocator, .{
            .id = try allocator.dupe(u8, theme.id),
            .label = try allocator.dupe(u8, theme.label),
            .path = try allocator.dupe(u8, theme.path),
            .extension_id = try allocator.dupe(u8, theme.extension_id),
            .extension_root = try allocator.dupe(u8, theme.extension_root),
        });
    }

    pub fn addKeybinding(self: *Registry, allocator: std.mem.Allocator, binding: KeybindingContribution) !void {
        try self.keybindings.append(allocator, .{
            .key = try allocator.dupe(u8, binding.key),
            .command = try allocator.dupe(u8, binding.command),
            .extension_id = try allocator.dupe(u8, binding.extension_id),
        });
    }

    pub fn addLanguage(self: *Registry, allocator: std.mem.Allocator, lang: LanguageContribution) !void {
        try self.languages.append(allocator, .{
            .id = try allocator.dupe(u8, lang.id),
            .server = try allocator.dupe(u8, lang.server),
            .args = try allocator.dupe(u8, lang.args),
            .file_pattern = try allocator.dupe(u8, lang.file_pattern),
            .server_resolver = try allocator.dupe(u8, lang.server_resolver),
            .extension_id = try allocator.dupe(u8, lang.extension_id),
        });
    }

    pub fn addRegistry(self: *Registry, allocator: std.mem.Allocator, other: *const Registry) !void {
        for (other.themes.items) |theme| try self.addTheme(allocator, theme);
        for (other.keybindings.items) |binding| try self.addKeybinding(allocator, binding);
        for (other.languages.items) |lang| try self.addLanguage(allocator, lang);
    }

    pub fn registerManifest(
        self: *Registry,
        allocator: std.mem.Allocator,
        extension_id: []const u8,
        extension_root: []const u8,
        manifest: *const manifest_mod.Manifest,
    ) !void {
        for (manifest.themes) |theme| {
            try self.addTheme(allocator, .{
                .id = theme.id,
                .label = theme.label,
                .path = theme.path,
                .extension_id = extension_id,
                .extension_root = extension_root,
            });
        }

        for (manifest.keybindings) |binding| {
            try self.addKeybinding(allocator, .{
                .key = binding.key,
                .command = binding.command,
                .extension_id = extension_id,
            });
        }

        for (manifest.languages) |lang| {
            try self.addLanguage(allocator, .{
                .id = lang.id,
                .server = lang.server,
                .args = lang.args,
                .file_pattern = lang.file_pattern,
                .server_resolver = lang.server_resolver,
                .extension_id = extension_id,
            });
        }
    }

    pub fn findTheme(self: *const Registry, theme_id: []const u8) ?*const ThemeContribution {
        for (self.themes.items) |*theme| {
            if (std.mem.eql(u8, theme.id, theme_id)) return theme;
        }
        return null;
    }

    pub fn findThemeByQualifiedId(self: *const Registry, qualified: []const u8) ?*const ThemeContribution {
        const slash = std.mem.indexOfScalar(u8, qualified, '/') orelse return self.findTheme(qualified);
        const extension_id = qualified[0..slash];
        const theme_id = qualified[slash + 1 ..];
        for (self.themes.items) |*theme| {
            if (std.mem.eql(u8, theme.extension_id, extension_id) and std.mem.eql(u8, theme.id, theme_id)) {
                return theme;
            }
        }
        return null;
    }
};

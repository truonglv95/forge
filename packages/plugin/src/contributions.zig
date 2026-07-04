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
            allocator.free(item.extension_id);
        }
        self.languages.deinit(allocator);
    }

    pub fn clear(self: *Registry, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        self.* = init(allocator);
    }

    pub fn registerManifest(
        self: *Registry,
        allocator: std.mem.Allocator,
        extension_id: []const u8,
        extension_root: []const u8,
        manifest: *const manifest_mod.Manifest,
    ) !void {
        for (manifest.themes) |theme| {
            try self.themes.append(allocator, .{
                .id = try allocator.dupe(u8, theme.id),
                .label = try allocator.dupe(u8, theme.label),
                .path = try allocator.dupe(u8, theme.path),
                .extension_id = try allocator.dupe(u8, extension_id),
                .extension_root = try allocator.dupe(u8, extension_root),
            });
        }

        for (manifest.keybindings) |binding| {
            try self.keybindings.append(allocator, .{
                .key = try allocator.dupe(u8, binding.key),
                .command = try allocator.dupe(u8, binding.command),
                .extension_id = try allocator.dupe(u8, extension_id),
            });
        }

        for (manifest.languages) |lang| {
            try self.languages.append(allocator, .{
                .id = try allocator.dupe(u8, lang.id),
                .server = try allocator.dupe(u8, lang.server),
                .args = try allocator.dupe(u8, lang.args),
                .file_pattern = try allocator.dupe(u8, lang.file_pattern),
                .extension_id = try allocator.dupe(u8, extension_id),
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

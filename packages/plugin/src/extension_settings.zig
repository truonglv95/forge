const std = @import("std");
const workspace = @import("forge-workspace");

/// Extension settings support.
///
/// Extensions can declare settings in their forge.toml manifest:
/// ```toml
/// [settings]
/// python_path = "python3"
/// venv_path = ".venv"
/// ```
///
/// Users can override these in their workspace forge.toml:
/// ```toml
/// [extension_settings.forge.lsp.python]
/// python_path = "/usr/bin/python3.11"
/// ```
///
/// The merged settings are passed to the extension at activation time
/// via the ActivationContext.

pub const SettingsError = error{
    OutOfMemory,
    ParseError,
};

pub const Settings = struct {
    allocator: std.mem.Allocator,
    /// Key-value pairs. Keys are owned strings.
    entries: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) Settings {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Settings) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn get(self: *const Settings, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    pub fn set(self: *Settings, key: []const u8, value: []const u8) !void {
        const key_owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_owned);
        const value_owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_owned);

        // Replace existing value if key already present.
        if (self.entries.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.entries.put(key_owned, value_owned);
    }

    /// Parse a `[settings]` section from a TOML fragment.
    /// Only processes lines within a [settings] section.
    pub fn parseSection(self: *Settings, source: []const u8) SettingsError!void {
        var in_settings = false;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "#")) continue;

            if (line[0] == '[') {
                in_settings = std.mem.indexOf(u8, line, "settings") != null;
                continue;
            }

            if (!in_settings) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            // Strip quotes.
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
            }
            self.set(key, value) catch return error.OutOfMemory;
        }
    }

    /// Merge another settings set into this one (other takes priority).
    pub fn merge(self: *Settings, other: *const Settings) !void {
        var it = other.entries.iterator();
        while (it.next()) |entry| {
            try self.set(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

/// Load extension-specific settings from the workspace forge.toml.
/// Reads the `[extension_settings.<extension_id>]` section.
pub fn loadWorkspaceSettings(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    extension_id: []const u8,
) !Settings {
    var settings = Settings.init(allocator);
    errdefer settings.deinit();

    // Read forge.toml from workspace root.
    const forge_toml = workspace.global_store.readAbsoluteFile(
        allocator,
        io,
        "forge.toml",
    ) catch return settings;
    defer allocator.free(forge_toml);

    // Look for [extension_settings.<extension_id>] section.
    const section_header = std.fmt.allocPrint(allocator, "[extension_settings.{s}]", .{extension_id}) catch return settings;
    defer allocator.free(section_header);

    var in_section = false;
    var lines = std.mem.splitScalar(u8, forge_toml, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        if (line[0] == '[') {
            in_section = std.mem.eql(u8, line, section_header);
            continue;
        }

        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        settings.set(key, value) catch {};
    }

    return settings;
}

test "Settings set and get" {
    const allocator = std.testing.allocator;
    var s = Settings.init(allocator);
    defer s.deinit();
    try s.set("python_path", "python3");
    try s.set("venv", ".venv");
    try std.testing.expectEqualStrings("python3", s.get("python_path").?);
    try std.testing.expectEqualStrings(".venv", s.get("venv").?);
    try std.testing.expect(s.get("nonexistent") == null);
}

test "Settings merge" {
    const allocator = std.testing.allocator;
    var base = Settings.init(allocator);
    defer base.deinit();
    try base.set("key1", "base1");
    try base.set("key2", "base2");

    var override = Settings.init(allocator);
    defer override.deinit();
    try override.set("key2", "override2");
    try override.set("key3", "override3");

    try base.merge(&override);
    try std.testing.expectEqualStrings("base1", base.get("key1").?);
    try std.testing.expectEqualStrings("override2", base.get("key2").?);
    try std.testing.expectEqualStrings("override3", base.get("key3").?);
}

test "Settings parseSection" {
    const allocator = std.testing.allocator;
    var s = Settings.init(allocator);
    defer s.deinit();
    try s.parseSection(
        \\[extension]
        \\id = "test"
        \\
        \\[settings]
        \\python_path = "python3"
        \\venv_path = ".venv"
        \\max_lines = 1000
        \\
        \\[other_section]
        \\key = "ignored"
    );
    try std.testing.expectEqualStrings("python3", s.get("python_path").?);
    try std.testing.expectEqualStrings(".venv", s.get("venv_path").?);
    try std.testing.expectEqualStrings("1000", s.get("max_lines").?);
    try std.testing.expect(s.get("key") == null); // from [other_section], should be ignored
}

test "Settings set replaces existing value" {
    const allocator = std.testing.allocator;
    var s = Settings.init(allocator);
    defer s.deinit();
    try s.set("key", "old");
    try s.set("key", "new");
    try std.testing.expectEqualStrings("new", s.get("key").?);
}

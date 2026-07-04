const std = @import("std");
const util = @import("forge-util");
const manifest_mod = @import("manifest.zig");

/// Minimal VS Code `package.json` importer for `contributes.*` only.
pub fn importPackageJson(allocator: std.mem.Allocator, source: []const u8) manifest_mod.ParseError!manifest_mod.Manifest {
    var manifest = manifest_mod.Manifest{
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

    var commands: std.ArrayList(manifest_mod.CommandContribution) = .empty;
    var themes: std.ArrayList(manifest_mod.ThemeContribution) = .empty;
    var keybindings: std.ArrayList(manifest_mod.KeybindingContribution) = .empty;
    errdefer {
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
    }

    var in_contributes = false;
    var in_commands = false;
    var in_themes = false;
    var in_keybindings = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
            raw_line[0..index]
        else
            raw_line;
        const line = util.trimAscii(without_comment);
        if (line.len == 0) continue;

        if (std.mem.indexOf(u8, line, "\"name\"")) |idx| {
            if (parseJsonString(line[idx..])) |value| {
                allocator.free(manifest.name);
                manifest.name = try allocator.dupe(u8, value);
            }
        }
        if (std.mem.indexOf(u8, line, "\"publisher\"")) |idx| {
            if (parseJsonString(line[idx..])) |publisher| {
                if (manifest.name.len > 0) {
                    if (manifest.id.len > 0) allocator.free(manifest.id);
                    manifest.id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ publisher, manifest.name });
                }
            }
        }
        if (std.mem.indexOf(u8, line, "\"version\"")) |idx| {
            if (parseJsonString(line[idx..])) |value| {
                allocator.free(manifest.version);
                manifest.version = try allocator.dupe(u8, value);
            }
        }

        if (std.mem.indexOf(u8, line, "\"contributes\"")) |_| in_contributes = true;
        if (!in_contributes) continue;

        if (std.mem.indexOf(u8, line, "\"commands\"")) |_| {
            in_commands = true;
            in_themes = false;
            in_keybindings = false;
            continue;
        }
        if (std.mem.indexOf(u8, line, "\"themes\"")) |_| {
            in_themes = true;
            in_commands = false;
            in_keybindings = false;
            continue;
        }
        if (std.mem.indexOf(u8, line, "\"keybindings\"")) |_| {
            in_keybindings = true;
            in_commands = false;
            in_themes = false;
            continue;
        }
        if (line.len > 0 and line[0] == '}') {
            in_commands = false;
            in_themes = false;
            in_keybindings = false;
        }

        if (in_commands) {
            if (std.mem.indexOf(u8, line, "\"command\"")) |idx| {
                if (parseJsonString(line[idx..])) |command_id| {
                    const owned = try allocator.dupe(u8, command_id);
                    try commands.append(allocator, .{ .id = owned, .title = try allocator.dupe(u8, owned) });
                }
            }
            if (std.mem.indexOf(u8, line, "\"title\"")) |idx| {
                if (commands.items.len > 0) {
                    if (parseJsonString(line[idx..])) |title| {
                        const last = commands.items.len - 1;
                        allocator.free(commands.items[last].title);
                        commands.items[last].title = try allocator.dupe(u8, title);
                    }
                }
            }
        }

        if (in_themes) {
            if (std.mem.indexOf(u8, line, "\"label\"")) |idx| {
                if (parseJsonString(line[idx..])) |label| {
                    const owned = try allocator.dupe(u8, label);
                    try themes.append(allocator, .{ .id = owned, .label = try allocator.dupe(u8, owned), .path = try allocator.dupe(u8, "") });
                }
            } else if (std.mem.indexOf(u8, line, "\"path\"")) |idx| {
                if (themes.items.len > 0) {
                    if (parseJsonString(line[idx..])) |path| {
                        const last = themes.items.len - 1;
                        allocator.free(themes.items[last].path);
                        themes.items[last].path = try allocator.dupe(u8, path);
                    }
                }
            }
        }

        if (in_keybindings) {
            if (std.mem.indexOf(u8, line, "\"key\"")) |idx| {
                if (parseJsonString(line[idx..])) |key| {
                    const owned = try allocator.dupe(u8, key);
                    try keybindings.append(allocator, .{ .key = owned, .command = try allocator.dupe(u8, "") });
                }
            } else if (std.mem.indexOf(u8, line, "\"command\"")) |idx| {
                if (keybindings.items.len > 0) {
                    if (parseJsonString(line[idx..])) |command| {
                        const last = keybindings.items.len - 1;
                        allocator.free(keybindings.items[last].command);
                        keybindings.items[last].command = try allocator.dupe(u8, command);
                    }
                }
            }
        }
    }

    if (manifest.name.len == 0) return error.MissingExtensionSection;
    if (manifest.id.len == 0) {
        manifest.id = try allocator.dupe(u8, manifest.name);
    }
    manifest.commands = try commands.toOwnedSlice(allocator);
    manifest.themes = try themes.toOwnedSlice(allocator);
    manifest.keybindings = try keybindings.toOwnedSlice(allocator);
    return manifest;
}

fn parseJsonString(line: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var rest = util.trimAscii(line[colon + 1 ..]);
    if (rest.len == 0) return null;
    if (rest[rest.len - 1] == ',') rest = rest[0 .. rest.len - 1];
    rest = util.trimAscii(rest);
    if (rest.len < 2 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

test "vscode shim imports commands from package.json" {
    const allocator = std.testing.allocator;
    var manifest = try importPackageJson(allocator,
        \\{
        \\  "name": "sample-ext",
        \\  "publisher": "forge",
        \\  "version": "1.0.0",
        \\  "contributes": {
        \\    "commands": [
        \\      { "command": "sample.hello", "title": "Sample Hello" }
        \\    ]
        \\  }
        \\}
    );
    defer manifest.deinit(allocator);

    try std.testing.expectEqualStrings("forge.sample-ext", manifest.id);
    try std.testing.expectEqual(@as(usize, 1), manifest.commands.len);
    try std.testing.expectEqualStrings("sample.hello", manifest.commands[0].id);
}

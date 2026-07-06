const std = @import("std");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");
const kernel = @import("forge-kernel");
const util = @import("forge-util");

pub const hooks_file = ".forge/hooks.toml";

pub const HookRule = struct {
    pattern: []const u8,
    command: []const u8,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    save_rules: []HookRule,

    pub fn deinit(self: *Config) void {
        for (self.save_rules) |rule| {
            self.allocator.free(rule.pattern);
            self.allocator.free(rule.command);
        }
        self.allocator.free(self.save_rules);
        self.* = undefined;
    }
};

pub const HooksError = error{
    WorkspaceFailed,
    HookFailed,
    OutOfMemory,
};

/// Parses `.forge/hooks.toml`:
/// ```toml
/// [[save]]
/// pattern = "*.zig"
/// command = "zig fmt"
/// ```
pub fn load(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) HooksError!Config {
    const wp = path_mod.WorkspacePath.parse(hooks_file) catch return emptyConfig(allocator);
    var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch |err| switch (err) {
        error.FileNotFound => return emptyConfig(allocator),
        else => return error.WorkspaceFailed,
    };
    defer snap.deinit();
    return parseSource(allocator, snap.content);
}

pub fn runOnSave(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    saved_path: []const u8,
    workspace_cwd: []const u8,
) HooksError!void {
    var config = try load(allocator, io, root);
    defer config.deinit();

    for (config.save_rules) |rule| {
        if (!matchesPattern(rule.pattern, saved_path)) continue;
        try runHook(allocator, io, rule.command, saved_path, workspace_cwd);
    }
}

fn emptyConfig(allocator: std.mem.Allocator) Config {
    return .{
        .allocator = allocator,
        .save_rules = &.{},
    };
}

fn parseSource(allocator: std.mem.Allocator, source: []const u8) HooksError!Config {
    var rules: std.ArrayList(HookRule) = .empty;
    errdefer {
        for (rules.items) |rule| {
            allocator.free(rule.pattern);
            allocator.free(rule.command);
        }
        rules.deinit(allocator);
    }

    var section: []const u8 = "";
    var current_pattern: ?[]const u8 = null;
    var current_command: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
            raw_line[0..index]
        else
            raw_line;
        const line = util.trimAscii(without_comment);
        if (line.len == 0) continue;

        if (line[0] == '[') {
            try flushRule(allocator, &rules, section, &current_pattern, &current_command);
            if (line.len < 3 or line[line.len - 1] != ']') return error.WorkspaceFailed;
            section = util.trimAscii(line[1 .. line.len - 1]);
            continue;
        }

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = util.trimAscii(line[0..equals]);
        const value = try parseTomlString(util.trimAscii(line[equals + 1 ..]));

        if (std.mem.eql(u8, key, "pattern")) {
            if (current_pattern) |old| allocator.free(old);
            current_pattern = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "command")) {
            if (current_command) |old| allocator.free(old);
            current_command = try allocator.dupe(u8, value);
        }
    }
    try flushRule(allocator, &rules, section, &current_pattern, &current_command);

    return .{
        .allocator = allocator,
        .save_rules = try rules.toOwnedSlice(allocator),
    };
}

fn flushRule(
    allocator: std.mem.Allocator,
    rules: *std.ArrayList(HookRule),
    section: []const u8,
    pattern: *?[]const u8,
    command: *?[]const u8,
) !void {
    if (!std.mem.eql(u8, normalizeSection(section), "save")) return;
    const pat = pattern.* orelse return;
    const cmd = command.* orelse return;
    pattern.* = null;
    command.* = null;
    try rules.append(allocator, .{
        .pattern = pat,
        .command = cmd,
    });
}

fn normalizeSection(section: []const u8) []const u8 {
    var s = util.trimAscii(section);
    while (s.len > 0 and s[0] == '[') s = s[1..];
    while (s.len > 0 and s[s.len - 1] == ']') s = s[0 .. s.len - 1];
    return util.trimAscii(s);
}

fn parseTomlString(value: []const u8) HooksError![]const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn matchesPattern(pattern: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[1..];
        return std.mem.endsWith(u8, path, suffix);
    }
    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, path, prefix);
    }
    return std.mem.eql(u8, pattern, path);
}

fn runHook(allocator: std.mem.Allocator, io: std.Io, command_template: []const u8, saved_path: []const u8, cwd: []const u8) HooksError!void {
    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(allocator);

    var rest = command_template;
    while (rest.len > 0) {
        if (std.mem.indexOf(u8, rest, "{path}")) |idx| {
            try expanded.appendSlice(allocator, rest[0..idx]);
            try expanded.appendSlice(allocator, saved_path);
            rest = rest[idx + "{path}".len ..];
        } else {
            try expanded.appendSlice(allocator, rest);
            break;
        }
    }

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);

    var split = std.mem.tokenizeScalar(u8, expanded.items, ' ');
    while (split.next()) |token| {
        if (token.len == 0) continue;
        try argv_list.append(allocator, token);
    }
    if (argv_list.items.len == 0) return;

    const term = kernel.process.run(allocator, io, .{
        .argv = argv_list.items,
        .cwd = cwd,
    }) catch return error.HookFailed;

    switch (term) {
        .exited => |code| if (code != 0) return error.HookFailed,
        else => return error.HookFailed,
    }
}

test "hooks pattern matching" {
    try std.testing.expect(matchesPattern("*.zig", "src/main.zig"));
    try std.testing.expect(!matchesPattern("*.zig", "readme.md"));
    try std.testing.expect(matchesPattern("FORGE.md", "FORGE.md"));
}

test "hooks parse save rules" {
    const allocator = std.testing.allocator;
    const source =
        \\[[save]]
        \\pattern = "*.zig"
        \\command = "zig fmt {path}"
        \\
        \\[[save]]
        \\pattern = "FORGE.md"
        \\command = "echo ok"
    ;
    var config = try parseSource(allocator, source);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 2), config.save_rules.len);
    try std.testing.expectEqualStrings("*.zig", config.save_rules[0].pattern);
}

test "hooks normalize section" {
    try std.testing.expectEqualStrings("save", normalizeSection("[[save]]"));
}

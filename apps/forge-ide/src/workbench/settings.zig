const std = @import("std");
const workspace = @import("forge-workspace");

pub const Settings = struct {
    tab_width: u8 = 4,
    font_size: f32 = 14,
    word_wrap: bool = false,
    terminal_shell: ?[]const u8 = null,

    pub fn deinit(self: *Settings, allocator: std.mem.Allocator) void {
        if (self.terminal_shell) |shell| allocator.free(shell);
        self.* = undefined;
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !Settings {
    var settings: Settings = .{};
    errdefer settings.deinit(allocator);

    const wp = workspace.WorkspacePath.parse(".forge/settings.toml") catch return settings;
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return settings;
    defer snap.deinit();

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, snap.content, '\n');
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
            }
        } else if (std.mem.eql(u8, section, "terminal")) {
            if (std.mem.eql(u8, key, "shell")) {
                const unquoted = parseQuoted(value) orelse value;
                settings.terminal_shell = try allocator.dupe(u8, unquoted);
            }
        } else if (std.mem.eql(u8, section, "theme")) {
            if (std.mem.eql(u8, key, "font_size")) {
                const parsed = std.fmt.parseFloat(f32, value) catch continue;
                if (parsed >= 8 and parsed <= 48) settings.font_size = parsed;
            }
        }
    }

    return settings;
}

pub fn applyToTheme(settings: Settings, theme: *workspace.Theme) void {
    theme.editor_font_size = settings.font_size;
    theme.tab_width = settings.tab_width;
}

pub fn writeWordWrap(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    enabled: bool,
) !void {
    const wp = try workspace.WorkspacePath.parse(".forge/settings.toml");
    const value = if (enabled) "true" else "false";
    const existing = workspace.FileSnapshot.read(allocator, io, root, wp) catch blk: {
        const content = try std.fmt.allocPrint(allocator, "[editor]\nword_wrap = {s}\n", .{value});
        defer allocator.free(content);
        try workspace.atomic.replaceFile(io, root, wp, content);
        break :blk null;
    };

    if (existing) |*snap| {
        defer snap.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        var in_editor = false;
        var wrote = false;
        var lines = std.mem.splitScalar(u8, snap.content, '\n');
        while (lines.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                const name = std.mem.trim(u8, &std.ascii.whitespace, trimmed[1 .. trimmed.len - 1]);
                if (in_editor and !wrote) {
                    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "word_wrap = {s}\n", .{value}));
                    wrote = true;
                }
                in_editor = std.mem.eql(u8, name, "editor");
                try out.appendSlice(allocator, raw_line);
                try out.append(allocator, '\n');
                continue;
            }
            if (in_editor and std.mem.startsWith(u8, trimmed, "word_wrap")) {
                try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "word_wrap = {s}\n", .{value}));
                wrote = true;
                continue;
            }
            try out.appendSlice(allocator, raw_line);
            try out.append(allocator, '\n');
        }

        if (!wrote) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, "\n[editor]\n");
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "word_wrap = {s}\n", .{value}));
        }

        try workspace.atomic.replaceFile(io, root, wp, out.items);
    }
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

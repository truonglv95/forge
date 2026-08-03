const std = @import("std");

pub const Config = struct {
    show_explorer: bool = false,
    explorer_width: u16 = 30,
    show_editor: bool = false,
    keybinding: []const u8 = "standard",
    theme: []const u8 = "default",

    pub fn init() Config {
        return .{};
    }

    pub fn loadFromToml(self: *Config, content: []const u8, allocator: std.mem.Allocator) void {
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
                raw_line[0..index]
            else
                raw_line;
            const line = std.mem.trim(u8, without_comment, " \t\r");
            if (line.len == 0) continue;

            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') continue;
                section = std.mem.trim(u8, line[1 .. line.len - 1], " \t\r");
                continue;
            }

            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const raw_key = std.mem.trim(u8, line[0..eq_idx], " \t\r");
            const raw_val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r");

            if (std.mem.eql(u8, section, "ui")) {
                if (std.mem.eql(u8, raw_key, "show_explorer")) {
                    self.show_explorer = std.mem.eql(u8, raw_val, "true");
                } else if (std.mem.eql(u8, raw_key, "explorer_width")) {
                    self.explorer_width = std.fmt.parseInt(u16, raw_val, 10) catch 30;
                } else if (std.mem.eql(u8, raw_key, "show_editor")) {
                    self.show_editor = std.mem.eql(u8, raw_val, "true");
                } else if (std.mem.eql(u8, raw_key, "keybinding")) {
                    const clean_val = std.mem.trim(u8, raw_val, "\"");
                    self.keybinding = allocator.dupe(u8, clean_val) catch "standard";
                }
            } else if (std.mem.eql(u8, section, "theme")) {
                if (std.mem.eql(u8, raw_key, "active")) {
                    const clean_val = std.mem.trim(u8, raw_val, "\"");
                    self.theme = allocator.dupe(u8, clean_val) catch "default";
                }
            }
        }
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map, io: std.Io) Config {
    var config = Config.init();

    if (environ_map) |map| {
        if (map.get("HOME")) |home| {
            const path = std.fmt.allocPrint(allocator, "{s}/.forge/config-cli.toml", .{home}) catch return config;
            defer allocator.free(path);

            if (std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{})) |*file| {
                defer file.close(io);
                if (file.stat(io)) |stat| {
                    const size: usize = @intCast(stat.size);
                    if (size > 0 and size < 1024 * 1024) {
                        if (allocator.alloc(u8, size)) |content| {
                            defer allocator.free(content);
                            if (file.readPositionalAll(io, content, 0)) |_| {
                                config.loadFromToml(content, allocator);
                            } else |_| {}
                        } else |_| {}
                    }
                } else |_| {}
            } else |_| {}
        }
    }

    return config;
}

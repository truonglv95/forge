const std = @import("std");
const renderer = @import("forge-renderer");
const plugin = @import("forge-plugin");
const commands_mod = @import("workbench/commands.zig");
const palette_mod = @import("workbench/palette.zig");

const cmd_mask: i32 = 0x08;
const shift_mask: i32 = 0x02;
const alt_mask: i32 = 0x20;
const ctrl_mask: i32 = 0x01;

pub const Binding = struct {
    modifiers: i32,
    keycode: i32,
    palette_id: []const u8,
    extension_command: ?[]const u8 = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    bindings: []Binding,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .bindings = &.{} };
    }

    pub fn deinit(self: *Registry) void {
        for (self.bindings) |binding| {
            self.allocator.free(binding.palette_id);
            if (binding.extension_command) |cmd| self.allocator.free(cmd);
        }
        self.allocator.free(self.bindings);
        self.bindings = &.{};
    }

    pub fn rebuild(self: *Registry, host: *const plugin.Host) !void {
        self.deinit();
        var list: std.ArrayList(Binding) = .empty;
        errdefer {
            for (list.items) |binding| {
                self.allocator.free(binding.palette_id);
                if (binding.extension_command) |cmd| self.allocator.free(cmd);
            }
            list.deinit(self.allocator);
        }

        const builtins = [_]struct { key: []const u8, palette_id: []const u8 }{
            .{ .key = "cmd+shift+p", .palette_id = "palette.open" },
            .{ .key = "cmd+shift+e", .palette_id = "view.explorer" },
            .{ .key = "cmd+shift+f", .palette_id = "view.search" },
            .{ .key = "cmd+shift+g", .palette_id = "view.git" },
            .{ .key = "cmd+shift+d", .palette_id = "view.run" },
            .{ .key = "cmd+shift+x", .palette_id = "view.extensions" },
            .{ .key = "ctrl+`", .palette_id = "view.terminal" },
            .{ .key = "cmd+s", .palette_id = "file.save" },
            .{ .key = "cmd+f", .palette_id = "editor.find" },
            .{ .key = "cmd+alt+f", .palette_id = "editor.replace" },
            .{ .key = "cmd+g", .palette_id = "editor.goto" },
            .{ .key = "cmd+shift+z", .palette_id = "editor.redo" },
            .{ .key = "cmd+z", .palette_id = "editor.undo" },
            .{ .key = "f12", .palette_id = "editor.definition" },
            .{ .key = "shift+f12", .palette_id = "editor.references" },
            .{ .key = "f2", .palette_id = "editor.rename" },
            .{ .key = "cmd+\\", .palette_id = "editor.split" },
            .{ .key = "ctrl+shift+`", .palette_id = "terminal.new" },
            .{ .key = "ctrl+shift+]", .palette_id = "terminal.next" },
            .{ .key = "f5", .palette_id = "debug.continue" },
            .{ .key = "f10", .palette_id = "debug.step_over" },
            .{ .key = "f11", .palette_id = "debug.step_into" },
            .{ .key = "shift+f11", .palette_id = "debug.step_out" },
            .{ .key = "shift+alt+f", .palette_id = "editor.format" },
            .{ .key = "cmd+.", .palette_id = "problem.quick_fix" },
        };

        for (builtins) |builtin| {
            const parsed = parseKey(builtin.key) orelse continue;
            try list.append(self.allocator, .{
                .modifiers = parsed.modifiers,
                .keycode = parsed.keycode,
                .palette_id = try self.allocator.dupe(u8, builtin.palette_id),
            });
        }

        for (host.contributions.keybindings.items) |contrib| {
            const parsed = parseKey(contrib.key) orelse continue;
            try list.append(self.allocator, .{
                .modifiers = parsed.modifiers,
                .keycode = parsed.keycode,
                .palette_id = try self.allocator.dupe(u8, contrib.command),
                .extension_command = try self.allocator.dupe(u8, contrib.command),
            });
        }

        self.bindings = try list.toOwnedSlice(self.allocator);
    }

    pub fn dispatch(self: *const Registry, palette: *palette_mod.Palette, event: renderer.KeyEvent, dispatchFn: *const fn (commands_mod.Command) anyerror!void) bool {
        if (!event.is_down) return false;
        for (self.bindings) |binding| {
            if (binding.keycode != event.keycode) continue;
            if ((event.modifiers & binding.modifiers) != binding.modifiers) continue;

            for (palette.entries) |entry| {
                if (std.mem.eql(u8, entry.id, binding.palette_id)) {
                    dispatchFn(entry.command) catch {};
                    return true;
                }
            }

            if (binding.extension_command) |command_id| {
                var ext_id_buf: [256]u8 = undefined;
                const ext_palette_id = std.fmt.bufPrint(&ext_id_buf, "ext.{s}", .{command_id}) catch command_id;
                for (palette.entries) |entry| {
                    if (std.mem.eql(u8, entry.id, ext_palette_id)) {
                        dispatchFn(entry.command) catch {};
                        return true;
                    }
                }
                const owned = command_id; // caller-owned in binding; dispatch uses slice directly
                dispatchFn(.{ .run_extension_command = owned }) catch {};
                return true;
            }
        }
        return false;
    }
};

const ParsedKey = struct {
    modifiers: i32,
    keycode: i32,
};

fn parseKey(raw: []const u8) ?ParsedKey {
    var modifiers: i32 = 0;
    var key_part: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, raw, '+');
    while (parts.next()) |part| {
        if (eqToken(part, "cmd") or eqToken(part, "meta")) {
            modifiers |= cmd_mask;
        } else if (eqToken(part, "shift")) {
            modifiers |= shift_mask;
        } else if (eqToken(part, "alt") or eqToken(part, "option")) {
            modifiers |= alt_mask;
        } else if (eqToken(part, "ctrl") or eqToken(part, "control")) {
            modifiers |= ctrl_mask;
        } else {
            key_part = part;
        }
    }
    const key = key_part orelse return null;
    if (std.ascii.eqlIgnoreCase(key, "f12")) {
        return .{ .modifiers = modifiers, .keycode = 111 };
    }
    if (std.ascii.eqlIgnoreCase(key, "f2")) {
        return .{ .modifiers = modifiers, .keycode = 120 };
    }
    if (std.ascii.eqlIgnoreCase(key, "f5")) {
        return .{ .modifiers = modifiers, .keycode = 96 };
    }
    if (std.ascii.eqlIgnoreCase(key, "f10")) {
        return .{ .modifiers = modifiers, .keycode = 109 };
    }
    if (std.ascii.eqlIgnoreCase(key, "f11")) {
        return .{ .modifiers = modifiers, .keycode = 103 };
    }
    const keycode = keycodeForChar(key[0]) orelse return null;
    return .{ .modifiers = modifiers, .keycode = keycode };
}

fn eqToken(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

fn keycodeForChar(ch: u8) ?i32 {
    return switch (ch) {
        '`' => 50,
        else => switch (std.ascii.toLower(ch)) {
            'a' => 0,
            's' => 1,
            'd' => 2,
            'f' => 3,
            'h' => 4,
            'g' => 5,
            'z' => 6,
            'x' => 7,
            'c' => 8,
            'v' => 9,
            'b' => 11,
            'q' => 12,
            'w' => 13,
            'e' => 14,
            'r' => 15,
            'y' => 16,
            't' => 17,
            'o' => 31,
            'u' => 32,
            'i' => 34,
            'p' => 35,
            '.' => 47,
            else => null,
        },
    };
}

test "parse cmd+shift+p" {
    const parsed = parseKey("cmd+shift+p").?;
    try std.testing.expectEqual(@as(i32, cmd_mask | shift_mask), parsed.modifiers);
    try std.testing.expectEqual(@as(i32, 35), parsed.keycode);
}

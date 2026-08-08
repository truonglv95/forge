//! Command Palette widget

const std = @import("std");
const FuzzyFinder = @import("fuzzy_finder.zig").FuzzyFinder;

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    callback: *const fn () void,
};

pub const CommandPalette = struct {
    fuzzy: FuzzyFinder,
    commands: std.ArrayList(Command),
    allocator: Allocator,

    pub fn init(allocator: Allocator) CommandPalette {
        return .{
            .fuzzy = FuzzyFinder.init(allocator),
            .commands = std.ArrayList(Command).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandPalette) void {
        self.fuzzy.deinit();
        self.commands.deinit();
    }

    pub fn addCommand(self: *CommandPalette, cmd: Command) !void {
        try self.commands.append(cmd);
        try self.fuzzy.addItem(cmd.name);
    }

    pub fn executeSelected(self: *CommandPalette) ?void {
        if (self.fuzzy.getSelected()) |selected| {
            for (self.commands.items) |cmd| {
                if (std.mem.eql(u8, cmd.name, selected)) {
                    cmd.callback();
                    return;
                }
            }
        }
        return null;
    }
};

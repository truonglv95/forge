const std = @import("std");
const task_output_mod = @import("task_output.zig");
const kernel = @import("forge-kernel");

pub const OutputChannel = struct {
    id: []const u8,
    name: []const u8,
    output: *task_output_mod.TaskOutput,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, id: []const u8, name: []const u8) !*OutputChannel {
        const self = try allocator.create(OutputChannel);
        errdefer allocator.destroy(self);

        const out = try allocator.create(task_output_mod.TaskOutput);
        errdefer allocator.destroy(out);
        out.* = task_output_mod.TaskOutput.init(allocator, io);

        self.* = .{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .output = out,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *OutputChannel) void {
        self.output.deinit();
        self.allocator.destroy(self.output);
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};

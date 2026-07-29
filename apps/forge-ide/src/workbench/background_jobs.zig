const std = @import("std");

pub const SpawnError = error{OutOfMemory};

pub fn spawnDetached(
    comptime name: []const u8,
    comptime Context: type,
    allocator: std.mem.Allocator,
    ctx_value: Context,
    comptime worker: fn (*Context) void,
) SpawnError!void {
    const ctx = allocator.create(Context) catch return error.OutOfMemory;
    ctx.* = ctx_value;
    _ = name;
    const thread = std.Thread.spawn(.{}, worker, .{ctx}) catch {
        allocator.destroy(ctx);
        return error.OutOfMemory;
    };
    thread.detach();
}

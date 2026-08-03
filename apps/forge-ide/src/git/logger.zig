const std = @import("std");

pub var global_log_fn: ?*const fn (ctx: ?*anyopaque, args: []const []const u8) void = null;
pub var global_log_ctx: ?*anyopaque = null;

pub fn log(args: []const []const u8) void {
    if (global_log_fn) |f| {
        f(global_log_ctx, args);
    }
}

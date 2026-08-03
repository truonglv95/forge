const std = @import("std");
const app = @import("agent_tui/app.zig");

pub const run = app.run;
pub const ToolRunPolicy = app.ToolRunPolicy;

test "ToolRunPolicy cycles through all three policies" {
    var p: ToolRunPolicy = .agent_default;
    p = p.next();
    try std.testing.expectEqual(ToolRunPolicy.run_everything, p);
    p = p.next();
    try std.testing.expectEqual(ToolRunPolicy.ask_each_time, p);
    p = p.next();
    try std.testing.expectEqual(ToolRunPolicy.agent_default, p);
}

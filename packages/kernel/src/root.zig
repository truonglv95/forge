//! Forge process lifecycle primitives.

const std = @import("std");
const core = @import("forge-core");

pub const command = @import("command.zig");
pub const event = @import("event.zig");
pub const Dispatcher = command.Dispatcher;
pub const EventBus = event.EventBus;

pub const cancellation = @import("cancellation.zig");
pub const observability = @import("observability.zig");
pub const process = @import("process.zig");
pub const task = @import("task.zig");
pub const registry = @import("registry.zig");

pub const subsystem = core.Subsystem.kernel;

pub const LifecycleState = enum {
    created,
    starting,
    running,
    stopping,
    stopped,
    failed,
};

pub const Lifecycle = struct {
    state: LifecycleState = .created,

    pub fn transition(self: *Lifecycle, next: LifecycleState) error{InvalidTransition}!void {
        const valid = switch (self.state) {
            .created => next == .starting,
            .starting => next == .running or next == .failed,
            .running => next == .stopping or next == .failed,
            .stopping => next == .stopped or next == .failed,
            .stopped, .failed => false,
        };
        if (!valid) return error.InvalidTransition;
        self.state = next;
    }
};

test "lifecycle follows deterministic transitions" {
    var lifecycle = Lifecycle{};
    try lifecycle.transition(.starting);
    try lifecycle.transition(.running);
    try lifecycle.transition(.stopping);
    try lifecycle.transition(.stopped);
    try std.testing.expectError(error.InvalidTransition, lifecycle.transition(.starting));
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const core = @import("forge-core");

/// A synchronous command dispatcher with monotonic IDs.
///
/// Commands express mutation intent. The caller owns the command payload and
/// returned value; the dispatcher does not retain either one.
pub fn Dispatcher(
    comptime Command: type,
    comptime Result: type,
    comptime Context: type,
    comptime DispatchError: type,
    comptime execute: *const fn (*Context, Command) DispatchError!Result,
) type {
    return struct {
        const Self = @This();

        pub const Outcome = struct {
            id: core.CommandId,
            value: Result,
        };

        context: *Context,
        next_id: core.CommandId = .{ .value = 1 },

        pub fn dispatch(self: *Self, command: Command) DispatchError!Outcome {
            const id = self.next_id;
            const value = try execute(self.context, command);
            self.next_id = id.next();
            return .{ .id = id, .value = value };
        }
    };
}

test "dispatcher assigns IDs only to successful commands" {
    const Command = union(enum) { add: i32, reject };
    const Context = struct { value: i32 = 0 };
    const Executor = struct {
        fn execute(context: *Context, command: Command) error{Rejected}!i32 {
            switch (command) {
                .add => |value| context.value += value,
                .reject => return error.Rejected,
            }
            return context.value;
        }
    };

    const TestDispatcher = Dispatcher(Command, i32, Context, error{Rejected}, Executor.execute);
    var context = Context{};
    var dispatcher = TestDispatcher{ .context = &context };

    const first = try dispatcher.dispatch(.{ .add = 3 });
    try std.testing.expectEqual(@as(u64, 1), first.id.value);
    try std.testing.expectError(error.Rejected, dispatcher.dispatch(.reject));
    const second = try dispatcher.dispatch(.{ .add = 2 });
    try std.testing.expectEqual(@as(u64, 2), second.id.value);
    try std.testing.expectEqual(@as(i32, 5), second.value);
}

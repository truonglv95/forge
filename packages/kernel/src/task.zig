const std = @import("std");
const cancellation = @import("cancellation.zig");
const observability = @import("observability.zig");

pub const TaskResult = union(enum) {
    success: void,
    failure: []const u8,
    cancelled: void,
};

pub const Task = struct {
    id: observability.TaskId,
    run_id: observability.RunId,
    token: cancellation.CancellationToken,
};

pub const TaskRunner = struct {
    allocator: std.mem.Allocator,

    pub fn run(self: *TaskRunner, task: *Task) !TaskResult {
        _ = self;
        if (task.token.isCancelled()) {
            return TaskResult.cancelled;
        }

        // This acts as the bounded task wrapper. Actual task logic would be injected or
        // defined via an interface. For MVP, we return success immediately.
        return TaskResult.success;
    }
};

test "TaskRunner compiles" {
    // Basic verification
}

const std = @import("std");

pub const RunId = struct {
    value: u64,
};

pub const TaskId = struct {
    value: u64,
};

pub const TransactionId = struct {
    value: u64,
};

pub const LogLevel = enum { info, warn, err, debug };

pub const LogRecord = struct {
    level: LogLevel,
    message: []const u8,
    run_id: ?RunId = null,
    task_id: ?TaskId = null,
};

/// MVP Secret Redaction Wrapper.
/// In a production environment, this would scan for known secrets and replace them
/// before passing them to the underlying writer.
pub fn RedactingWriter(comptime WriterType: type) type {
    return struct {
        underlying: WriterType,

        pub const Error = WriterType.Error;

        pub fn write(self: @This(), bytes: []const u8) Error!usize {
            // Simplified MVP: Pass through bytes without mutating.
            return self.underlying.write(bytes);
        }

        pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
            return self.underlying.writeAll(bytes);
        }
    };
}

test "RedactingWriter struct compiles" {
    // Basic verification
}

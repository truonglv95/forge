const std = @import("std");

pub const schema_version: u32 = 1;

pub const Surface = enum {
    cli,
    ide,
    agent_window,
};

pub const State = enum {
    planning,
    proposed,
    reviewing,
    applying,
    verifying,
    done,
    cancelled,
    failed,
};

pub const Record = struct {
    run_id: []const u8,
    surface: Surface,
    intent: []const u8,
    state: State,
    proposal_path: ?[]const u8 = null,
    transaction_id: ?u64 = null,
    provider_id: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    timestamp_ms: i64,
};

pub fn formatJson(allocator: std.mem.Allocator, record: Record) ![]u8 {
    const proposal = record.proposal_path orelse "";
    const provider = record.provider_id orelse "";
    const model = record.model_id orelse "";
    const tx_id = record.transaction_id orelse 0;

    return try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":{d},\"run_id\":\"{s}\",\"surface\":\"{s}\",\"intent\":\"{s}\",\"state\":\"{s}\",\"proposal_path\":\"{s}\",\"transaction_id\":{d},\"provider_id\":\"{s}\",\"model_id\":\"{s}\",\"timestamp_ms\":{d}}}\n",
        .{
            schema_version,
            record.run_id,
            @tagName(record.surface),
            record.intent,
            @tagName(record.state),
            proposal,
            tx_id,
            provider,
            model,
            record.timestamp_ms,
        },
    );
}

pub fn formatIndexLine(allocator: std.mem.Allocator, record: Record) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"run_id\":\"{s}\",\"state\":\"{s}\",\"timestamp_ms\":{d}}}\n", .{
        record.run_id,
        @tagName(record.state),
        record.timestamp_ms,
    });
}

pub fn makeRunId(allocator: std.mem.Allocator, timestamp_ms: i64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "run_{d}", .{timestamp_ms});
}

test "run record schema version is stable" {
    try std.testing.expectEqual(@as(u32, 1), schema_version);
}

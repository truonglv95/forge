const std = @import("std");

/// Versioned event contract shared by headless CLI, TUI, and IDE renderers.
/// Events are transport-neutral; the current CLI implementation emits them as
/// newline-delimited JSON via `forge agent run --events ndjson`.
pub const schema_version: u32 = 1;

pub const Type = enum {
    run_started,
    llm_turn,
    tool_call,
    tool_result,
    run_completed,
    @"error",
};

pub const ErrorCode = enum {
    step_limit_reached,
    cancelled,
    provider_failed,
    rate_limit_exceeded,
    authentication_failed,
    context_length_exceeded,
    network_error,
    workspace_failed,
    invalid_proposal,
};

pub fn typeName(value: Type) []const u8 {
    return @tagName(value);
}

pub fn errorCodeName(value: ErrorCode) []const u8 {
    return @tagName(value);
}

test "agent event schema names are stable" {
    try std.testing.expectEqual(@as(u32, 1), schema_version);
    try std.testing.expectEqualStrings("tool_call", typeName(.tool_call));
    try std.testing.expectEqualStrings("rate_limit_exceeded", errorCodeName(.rate_limit_exceeded));
}

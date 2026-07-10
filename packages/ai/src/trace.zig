const std = @import("std");

pub const schema_version: u32 = 1;

pub const Phase = enum {
    session,
    routing,
    context,
    model,
    tool,
    validation,
    output,
};

pub const Event = struct {
    schema_version: u32 = schema_version,
    run_id: []const u8 = "",
    session_id: []const u8 = "",
    phase: Phase,
    name: []const u8,
    detail: []const u8 = "",
    duration_ms: ?u64 = null,
};

pub fn phaseName(phase: Phase) []const u8 {
    return @tagName(phase);
}

pub fn eventJson(allocator: std.mem.Allocator, event: Event) ![]u8 {
    const Json = struct {
        schema_version: u32,
        run_id: []const u8,
        session_id: []const u8,
        phase: []const u8,
        name: []const u8,
        detail: []const u8,
        duration_ms: ?u64,
    };
    return std.json.Stringify.valueAlloc(allocator, Json{
        .schema_version = event.schema_version,
        .run_id = event.run_id,
        .session_id = event.session_id,
        .phase = phaseName(event.phase),
        .name = event.name,
        .detail = event.detail,
        .duration_ms = event.duration_ms,
    }, .{});
}

test "trace event json includes phase name" {
    const json = try eventJson(std.testing.allocator, .{ .phase = .tool, .name = "read_file" });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"phase\":\"tool\"") != null);
}

const std = @import("std");

pub const default_tasks = [_][]const u8{
    "zig build test",
    "property: add fuzz/property tests for changed parsers when applicable",
};

/// Ensures proposals include baseline validation guidance.
pub fn augmentProposalJson(allocator: std.mem.Allocator, proposal_body: []const u8) ![]u8 {
    const JsonRoot = struct {
        schema_version: ?u32 = null,
        summary: ?[]const u8 = null,
        assumptions: ?[]const []const u8 = null,
        validation_tasks: ?[]const []const u8 = null,
        workspace_edit: ?std.json.Value = null,
        files: ?std.json.Value = null,
    };

    var parsed = try std.json.parseFromSlice(JsonRoot, allocator, proposal_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var tasks: std.ArrayList([]const u8) = .empty;
    defer tasks.deinit(allocator);
    if (parsed.value.validation_tasks) |existing| {
        for (existing) |task| try tasks.append(allocator, task);
    }

    for (default_tasks) |task| {
        var found = false;
        for (tasks.items) |existing| {
            if (std.mem.eql(u8, existing, task)) {
                found = true;
                break;
            }
        }
        if (!found) try tasks.append(allocator, task);
    }

    const Out = struct {
        schema_version: ?u32,
        summary: ?[]const u8,
        assumptions: ?[]const []const u8,
        validation_tasks: []const []const u8,
        workspace_edit: ?std.json.Value,
        files: ?std.json.Value,
    };

    return std.json.Stringify.valueAlloc(allocator, Out{
        .schema_version = parsed.value.schema_version,
        .summary = parsed.value.summary,
        .assumptions = parsed.value.assumptions orelse &.{},
        .validation_tasks = tasks.items,
        .workspace_edit = parsed.value.workspace_edit,
        .files = parsed.value.files,
    }, .{});
}

test "augmentProposalJson appends default validation tasks" {
    const allocator = std.testing.allocator;
    const body =
        \\{"schema_version":1,"summary":"x","validation_tasks":["custom check"],"workspace_edit":{"files":[]}}
    ;
    const out = try augmentProposalJson(allocator, body);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "zig build test") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "custom check") != null);
}

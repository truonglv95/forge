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

pub fn parseStateName(name: []const u8) ?State {
    return std.meta.stringToEnum(State, name);
}

pub const OwnedRecord = struct {
    allocator: std.mem.Allocator,
    run_id: []const u8,
    surface: Surface,
    intent: []const u8,
    state: State,
    proposal_path: ?[]const u8 = null,
    transaction_id: ?u64 = null,
    provider_id: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    timestamp_ms: i64,

    pub fn deinit(self: *OwnedRecord) void {
        self.allocator.free(self.run_id);
        self.allocator.free(self.intent);
        if (self.proposal_path) |path| self.allocator.free(path);
        if (self.provider_id) |id| self.allocator.free(id);
        if (self.model_id) |id| self.allocator.free(id);
        self.* = undefined;
    }

    pub fn toRecord(self: *const OwnedRecord) Record {
        return .{
            .run_id = self.run_id,
            .surface = self.surface,
            .intent = self.intent,
            .state = self.state,
            .proposal_path = self.proposal_path,
            .transaction_id = self.transaction_id,
            .provider_id = self.provider_id,
            .model_id = self.model_id,
            .timestamp_ms = self.timestamp_ms,
        };
    }
};

pub fn parseJson(allocator: std.mem.Allocator, source: []const u8) !OwnedRecord {
    const JsonRecord = struct {
        run_id: []const u8,
        surface: []const u8,
        intent: []const u8,
        state: []const u8,
        proposal_path: ?[]const u8 = null,
        transaction_id: ?u64 = null,
        provider_id: ?[]const u8 = null,
        model_id: ?[]const u8 = null,
        timestamp_ms: i64,
    };

    var parsed = try std.json.parseFromSlice(JsonRecord, allocator, source, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const surface = std.meta.stringToEnum(Surface, parsed.value.surface) orelse return error.InvalidRunRecord;
    const state = parseStateName(parsed.value.state) orelse return error.InvalidRunRecord;

    return .{
        .allocator = allocator,
        .run_id = try allocator.dupe(u8, parsed.value.run_id),
        .surface = surface,
        .intent = try allocator.dupe(u8, parsed.value.intent),
        .state = state,
        .proposal_path = if (parsed.value.proposal_path) |path| try allocator.dupe(u8, path) else null,
        .transaction_id = parsed.value.transaction_id,
        .provider_id = if (parsed.value.provider_id) |id| try allocator.dupe(u8, id) else null,
        .model_id = if (parsed.value.model_id) |id| try allocator.dupe(u8, id) else null,
        .timestamp_ms = parsed.value.timestamp_ms,
    };
}

test "run record schema version is stable" {
    try std.testing.expectEqual(@as(u32, 1), schema_version);
}

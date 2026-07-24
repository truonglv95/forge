const std = @import("std");

pub const Query = struct {
    tail: usize = 0,
    type_filter: ?[]const u8 = null,
};

pub fn eventTypeMatches(line: []const u8, want: []const u8) bool {
    var needle_buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"type\":\"{s}\"", .{want}) catch return false;
    return std.mem.indexOf(u8, line, needle) != null;
}

pub fn renderPreviewAlloc(allocator: std.mem.Allocator, ndjson_line: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, ndjson_line, .{}) catch {
        return std.fmt.allocPrint(allocator, "? {s}", .{ndjson_line});
    };
    defer parsed.deinit();
    if (parsed.value != .object) return std.fmt.allocPrint(allocator, "? {s}", .{ndjson_line});
    const obj = parsed.value.object;
    const type_str = jsonStr(obj, "type");

    if (std.mem.eql(u8, type_str, "session_started")) {
        return std.fmt.allocPrint(allocator, "session_started  intent={s}", .{jsonStr(obj, "intent")});
    }
    if (std.mem.eql(u8, type_str, "context_manifest_built")) {
        return std.fmt.allocPrint(allocator, "context_manifest  used_bytes={d} blocks={d}", .{ jsonInt(obj, "used_bytes"), jsonInt(obj, "blocks") });
    }
    if (std.mem.eql(u8, type_str, "context_compacted")) {
        return std.fmt.allocPrint(
            allocator,
            "context_compacted  {s} step={d} attempt={d} {d}kB -> {d}kB saved={d}kB",
            .{
                jsonStr(obj, "reason"),
                jsonInt(obj, "step"),
                jsonInt(obj, "attempt"),
                @divTrunc(jsonInt(obj, "before_bytes"), 1024),
                @divTrunc(jsonInt(obj, "after_bytes"), 1024),
                @divTrunc(jsonInt(obj, "saved_bytes"), 1024),
            },
        );
    }
    if (std.mem.eql(u8, type_str, "telemetry")) {
        const phase = jsonStr(obj, "phase");
        if (std.mem.eql(u8, phase, "prompt")) {
            return std.fmt.allocPrint(allocator, "prompt_size  {d} bytes blocks={d} {s}", .{ jsonInt(obj, "bytes"), jsonInt(obj, "items"), jsonStr(obj, "detail") });
        }
        if (std.mem.eql(u8, phase, "gate") or std.mem.eql(u8, phase, "repair") or std.mem.eql(u8, phase, "checkpoint")) {
            return std.fmt.allocPrint(allocator, "{s}  items={d} bytes={d} {s}", .{ phase, jsonInt(obj, "items"), jsonInt(obj, "bytes"), jsonStr(obj, "detail") });
        }
        return std.fmt.allocPrint(
            allocator,
            "telemetry  {s} {d}ms bytes={d} items={d} {s}",
            .{ phase, jsonInt(obj, "duration_ms"), jsonInt(obj, "bytes"), jsonInt(obj, "items"), jsonStr(obj, "detail") },
        );
    }
    if (std.mem.eql(u8, type_str, "run_started")) {
        return allocator.dupe(u8, "run_started");
    }
    if (std.mem.eql(u8, type_str, "tool_call")) {
        return std.fmt.allocPrint(allocator, "[{d}] tool_call  {s}  ({s})", .{ jsonInt(obj, "step"), jsonStr(obj, "tool"), jsonStr(obj, "reason") });
    }
    if (std.mem.eql(u8, type_str, "tool_result")) {
        const summary = clip(jsonStr(obj, "summary"), 220);
        return std.fmt.allocPrint(allocator, "[{d}] tool_result  {s}  {s}", .{ jsonInt(obj, "step"), jsonStr(obj, "kind"), summary });
    }
    if (std.mem.eql(u8, type_str, "subagent_started")) {
        return std.fmt.allocPrint(allocator, "subagent_started  {s} ({s})", .{ jsonStr(obj, "role"), jsonStr(obj, "label") });
    }
    if (std.mem.eql(u8, type_str, "subagent_result")) {
        const preview = clip(jsonStr(obj, "text_preview"), 160);
        return std.fmt.allocPrint(allocator, "subagent_result  {s} ({s})  {s}", .{ jsonStr(obj, "role"), jsonStr(obj, "label"), preview });
    }
    if (std.mem.eql(u8, type_str, "validation_started")) {
        return std.fmt.allocPrint(allocator, "validation_started  attempt={d}", .{jsonInt(obj, "attempt")});
    }
    if (std.mem.eql(u8, type_str, "validation_result")) {
        const passed = if (obj.get("passed")) |v| (v == .bool and v.bool) else false;
        const failed = jsonInt(obj, "failed_count");
        const total = jsonInt(obj, "task_count");
        var hint_count: i64 = 0;
        if (obj.get("hint_paths")) |v| {
            if (v == .array) hint_count = @intCast(v.array.items.len);
        }
        if (total > 0) {
            if (hint_count > 0) {
                return std.fmt.allocPrint(allocator, "validation_result  attempt={d} passed={} ({d}/{d} failed) hints={d}", .{ jsonInt(obj, "attempt"), passed, failed, total, hint_count });
            }
            return std.fmt.allocPrint(allocator, "validation_result  attempt={d} passed={} ({d}/{d} failed)", .{ jsonInt(obj, "attempt"), passed, failed, total });
        }
        if (hint_count > 0) {
            return std.fmt.allocPrint(allocator, "validation_result  attempt={d} passed={} hints={d}", .{ jsonInt(obj, "attempt"), passed, hint_count });
        }
        return std.fmt.allocPrint(allocator, "validation_result  attempt={d} passed={}", .{ jsonInt(obj, "attempt"), passed });
    }
    if (std.mem.eql(u8, type_str, "proposal_created")) {
        return std.fmt.allocPrint(allocator, "proposal_created  {s}", .{jsonStr(obj, "proposal_path")});
    }
    if (std.mem.eql(u8, type_str, "final_answer")) {
        return allocator.dupe(u8, "final_answer");
    }
    if (std.mem.eql(u8, type_str, "run_completed")) {
        return std.fmt.allocPrint(allocator, "run_completed  steps={d} repairs={d}", .{ jsonInt(obj, "steps"), jsonInt(obj, "repair_attempts") });
    }
    if (std.mem.eql(u8, type_str, "error")) {
        return std.fmt.allocPrint(allocator, "error  {s}", .{jsonStr(obj, "code")});
    }
    if (type_str.len > 0) return allocator.dupe(u8, type_str);
    return std.fmt.allocPrint(allocator, "? {s}", .{ndjson_line});
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return "";
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .integer => v.integer,
            .float => @intFromFloat(v.float),
            else => 0,
        };
    }
    return 0;
}

fn clip(s: []const u8, max: usize) []const u8 {
    return if (s.len > max) s[0..max] else s;
}

test "renderPreviewAlloc renders context compacted event" {
    const allocator = std.testing.allocator;
    const rendered = try renderPreviewAlloc(
        allocator,
        "{\"schema_version\":1,\"type\":\"context_compacted\",\"reason\":\"conversation_budget\",\"step\":9,\"attempt\":1,\"before_bytes\":262144,\"after_bytes\":16384,\"saved_bytes\":245760}",
    );
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "context_compacted") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "256kB -> 16kB") != null);
}

const std = @import("std");
const gemini_provider = @import("providers/gemini/provider.zig");
const workspace = @import("forge-workspace");

/// Strips fences/prose wrappers and returns the best-effort proposal JSON text.
pub fn normalize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const stripped = try gemini_provider.stripMarkdownFence(allocator, text);
    defer allocator.free(stripped);

    const extracted = extractFirstJsonObject(allocator, stripped);
    const candidate = extracted orelse stripped;
    defer if (extracted != null) allocator.free(extracted.?);

    const shaped = try ensureProposalShape(allocator, candidate);
    defer if (shaped.ptr != candidate.ptr) allocator.free(shaped);

    return try allocator.dupe(u8, shaped);
}

fn ensureProposalShape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (looksLikeProposalJson(allocator, text)) return try allocator.dupe(u8, text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{ .ignore_unknown_fields = true }) catch {
        const summary = clipSummary(text);
        return emptyProposalWithSummary(allocator, summary);
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        const summary = clipSummary(text);
        return emptyProposalWithSummary(allocator, summary);
    }

    const obj = parsed.value.object;
    if (obj.get("workspace_edit") != null or obj.get("files") != null) {
        return try allocator.dupe(u8, text);
    }

    const summary = jsonStr(obj, "summary") orelse clipSummary(text);
    return emptyProposalWithSummary(allocator, summary);
}

fn clipSummary(text: []const u8) []const u8 {
    return if (text.len > 240) text[0..240] else text;
}

fn emptyProposalWithSummary(allocator: std.mem.Allocator, summary: []const u8) ![]u8 {
    const Out = struct {
        schema_version: u32,
        summary: []const u8,
        assumptions: []const []const u8 = &.{},
        validation_tasks: []const []const u8 = &.{},
        workspace_edit: struct {
            files: []const struct {
                path: []const u8,
                operation: []const u8,
                edits: []const struct { start: u64, end: u64, replacement: []const u8 },
            } = &.{},
        } = .{},
    };

    return try std.json.Stringify.valueAlloc(allocator, Out{
        .schema_version = 1,
        .summary = summary,
    }, .{});
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| switch (v) {
        .string => |s| return s,
        else => {},
    };
    return null;
}

pub fn looksLikeProposalJson(allocator: std.mem.Allocator, text: []const u8) bool {
    var parsed = workspace.OwnedProposal.parseJson(allocator, text) catch return false;
    parsed.deinit();
    return true;
}

fn extractFirstJsonObject(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    const start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return null;

    var depth: i32 = 0;
    var in_string = false;
    var escape = false;

    for (trimmed[start..], 0..) |byte, offset| {
        if (in_string) {
            if (escape) {
                escape = false;
            } else switch (byte) {
                '\\' => escape = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (byte) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    const slice = trimmed[start .. start + offset + 1];
                    return allocator.dupe(u8, slice) catch null;
                }
            },
            else => {},
        }
    }

    return null;
}

test "normalize extracts JSON object from prose wrapper" {
    const allocator = std.testing.allocator;
    const raw =
        \\Here is the proposal:
        \\{"schema_version":1,"summary":"ok","workspace_edit":{"files":[]}}
        \\Thanks.
    ;
    const out = try normalize(allocator, raw);
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "{"));
    try std.testing.expect(std.mem.endsWith(u8, out, "}"));
    try std.testing.expect(looksLikeProposalJson(allocator, out));
}

test "normalize injects workspace_edit when missing" {
    const allocator = std.testing.allocator;
    const raw = "{\"schema_version\":1,\"summary\":\"assessment only\"}";
    const out = try normalize(allocator, raw);
    defer allocator.free(out);
    try std.testing.expect(looksLikeProposalJson(allocator, out));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"workspace_edit\"") != null);
}

test "normalize wraps prose into empty proposal" {
    const allocator = std.testing.allocator;
    const raw = "This project is a Zig monorepo with packages and apps.";
    const out = try normalize(allocator, raw);
    defer allocator.free(out);
    try std.testing.expect(looksLikeProposalJson(allocator, out));
    try std.testing.expect(std.mem.indexOf(u8, out, "Zig monorepo") != null);
}

test "normalize keeps fenced JSON" {
    const allocator = std.testing.allocator;
    const raw =
        \\```json
        \\{"schema_version":1,"summary":"ok","workspace_edit":{"files":[]}}
        \\```
    ;
    const out = try normalize(allocator, raw);
    defer allocator.free(out);
    try std.testing.expect(looksLikeProposalJson(allocator, out));
}

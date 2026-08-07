const std = @import("std");
const workspace = @import("forge-workspace");
const provider = @import("provider.zig");
const kernel = @import("forge-kernel");

/// MCP capability declaration (RFC-0016).
///
/// MCP tools currently default to `risk=high, approval=every_time`. This
/// module lets MCP servers declare their tools' capabilities (read-only vs
/// mutate) so Forge can apply least-privilege approval policies.
///
/// The declaration lives in the MCP server's tool annotations (MCP spec
/// 2024-11-05: `annotations.readOnly` boolean). When present, Forge uses
/// it to set the tool's risk/approval policy instead of defaulting to high.
pub const McpCapability = enum {
    read_only,
    mutate,
    unknown,

    pub fn label(self: McpCapability) []const u8 {
        return switch (self) {
            .read_only => "read_only",
            .mutate => "mutate",
            .unknown => "unknown",
        };
    }
};

pub const McpToolPolicy = struct {
    capability: McpCapability,
    /// Risk level for approval gating. read_only → low (automatic),
    /// mutate → high (every_time), unknown → high (every_time).
    risk: Risk,
    approval: Approval,
};

pub const Risk = enum { low, medium, high };
pub const Approval = enum { automatic, review, every_time };

/// Infer policy from MCP tool annotations JSON.
/// `annotations_json` is the raw JSON of the tool's `annotations` field.
/// Returns read_only policy when `annotations.readOnly == true`,
/// mutate policy otherwise.
pub fn inferPolicy(annotations_json: ?[]const u8) McpToolPolicy {
    if (annotations_json == null) return .{
        .capability = .unknown,
        .risk = .high,
        .approval = .every_time,
    };

    // Fast path: scan for "readOnly":true without full JSON parse.
    // The annotations object is small (1-3 fields) but called per-tool-call,
    // so avoiding page_allocator here saves a 4KB page allocation each time.
    // We look for the literal "readOnly" key followed by `:true`.
    const ann = annotations_json.?;
    var read_only = false;
    if (std.mem.indexOf(u8, ann, "\"readOnly\"")) |idx| {
        // Scan forward from the key to find the value.
        var i = idx + "\"readOnly\"".len;
        while (i < ann.len and (ann[i] == ' ' or ann[i] == ':' or ann[i] == '\t' or ann[i] == '\n' or ann[i] == '\r')) i += 1;
        if (i + 4 <= ann.len and std.mem.eql(u8, ann[i .. i + 4], "true")) {
            read_only = true;
        }
    }

    if (read_only) {
        return .{
            .capability = .read_only,
            .risk = .low,
            .approval = .automatic,
        };
    }
    return .{
        .capability = .mutate,
        .risk = .high,
        .approval = .every_time,
    };
}

test "inferPolicy returns read_only for readOnly=true" {
    const policy = inferPolicy("{\"readOnly\":true}");
    try std.testing.expectEqual(McpCapability.read_only, policy.capability);
    try std.testing.expectEqual(Risk.low, policy.risk);
    try std.testing.expectEqual(Approval.automatic, policy.approval);
}

test "inferPolicy returns mutate for readOnly=false" {
    const policy = inferPolicy("{\"readOnly\":false}");
    try std.testing.expectEqual(McpCapability.mutate, policy.capability);
    try std.testing.expectEqual(Risk.high, policy.risk);
}

test "inferPolicy returns unknown for missing annotations" {
    const policy = inferPolicy(null);
    try std.testing.expectEqual(McpCapability.unknown, policy.capability);
    try std.testing.expectEqual(Risk.high, policy.risk);
}

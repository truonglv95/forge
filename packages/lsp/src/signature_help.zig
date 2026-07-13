const std = @import("std");

/// Signature help support (textDocument/signatureHelp).
/// Provides function signature information as the user types.
pub const SignatureInfo = struct {
    label: []const u8,
    documentation: ?[]const u8 = null,
    /// Parameter information.
    parameters: []const ParameterInfo = &.{},
    active_parameter: ?u32 = null,
};

pub const ParameterInfo = struct {
    label: []const u8,
    documentation: ?[]const u8 = null,
};

pub const SignatureHelp = struct {
    signatures: []const SignatureInfo = &.{},
    active_signature: ?u32 = null,
    active_parameter: ?u32 = null,

    pub fn deinit(self: *SignatureHelp, allocator: std.mem.Allocator) void {
        for (self.signatures) |sig| {
            allocator.free(sig.label);
            if (sig.documentation) |d| allocator.free(d);
            for (sig.parameters) |param| {
                allocator.free(param.label);
                if (param.documentation) |d| allocator.free(d);
            }
            if (sig.parameters.len > 0) allocator.free(sig.parameters);
        }
        if (self.signatures.len > 0) allocator.free(self.signatures);
        self.* = undefined;
    }
};

pub fn buildSignatureHelpRequest(allocator: std.mem.Allocator, request_id: i32, uri: []const u8, line: u32, character: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/signatureHelp","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}}}
    , .{ request_id, uri, line, character });
}

pub fn parseSignatureHelpResponse(allocator: std.mem.Allocator, response_json: []const u8) !?SignatureHelp {
    const Result = struct {
        signatures: ?[]const struct {
            label: []const u8,
            documentation: ?[]const u8 = null,
            parameters: ?[]const struct {
                label: []const u8,
                documentation: ?[]const u8 = null,
            } = null,
            activeParameter: ?u32 = null,
        } = null,
        activeSignature: ?u32 = null,
        activeParameter: ?u32 = null,
    };
    const Wrapper = struct { result: ?Result = null };
    var parsed = try std.json.parseFromSlice(Wrapper, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const result = parsed.value.result orelse return null;
    const json_sigs = result.signatures orelse return null;
    if (json_sigs.len == 0) return null;

    const sigs = try allocator.alloc(SignatureInfo, json_sigs.len);
    for (json_sigs, 0..) |js, i| {
        const params = if (js.parameters) |jp| blk: {
            const p = try allocator.alloc(ParameterInfo, jp.len);
            for (jp, 0..) |jparam, pi| {
                p[pi] = .{
                    .label = try allocator.dupe(u8, jparam.label),
                    .documentation = if (jparam.documentation) |d| try allocator.dupe(u8, d) else null,
                };
            }
            break :blk p;
        } else &.{};
        sigs[i] = .{
            .label = try allocator.dupe(u8, js.label),
            .documentation = if (js.documentation) |d| try allocator.dupe(u8, d) else null,
            .parameters = params,
            .active_parameter = js.activeParameter,
        };
    }

    return .{
        .signatures = sigs,
        .active_signature = result.activeSignature,
        .active_parameter = result.activeParameter,
    };
}

test "buildSignatureHelpRequest includes method and position" {
    const allocator = std.testing.allocator;
    const msg = try buildSignatureHelpRequest(allocator, 1, "file:///test.zig", 3, 7);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/signatureHelp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"line\":3") != null);
}

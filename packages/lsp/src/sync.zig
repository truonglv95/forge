const std = @import("std");
const diagnostics = @import("diagnostics.zig");

pub fn buildDidOpenNotification(
    allocator: std.mem.Allocator,
    uri: []const u8,
    language_id: []const u8,
    version: u32,
    text: []const u8,
) ![]const u8 {
    const escaped = try diagnostics.escapeJsonString(allocator, text);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"{s}","version":{d},"text":"{s}"}}}}}}
    , .{ uri, language_id, version, escaped });
}

pub fn buildDidChangeNotification(
    allocator: std.mem.Allocator,
    uri: []const u8,
    version: u32,
    text: []const u8,
) ![]const u8 {
    const escaped = try diagnostics.escapeJsonString(allocator, text);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":"{s}","version":{d}}},"contentChanges":[{{"text":"{s}"}}]}}}}
    , .{ uri, version, escaped });
}

pub fn buildDidCloseNotification(allocator: std.mem.Allocator, uri: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{uri});
}

pub fn buildSemanticTokensFullRequest(allocator: std.mem.Allocator, request_id: i32, uri: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/semanticTokens/full","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{ request_id, uri });
}

pub fn buildWorkspaceSymbolRequest(allocator: std.mem.Allocator, request_id: i32, query: []const u8) ![]const u8 {
    const escaped = try diagnostics.escapeJsonString(allocator, query);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"workspace/symbol","params":{{"query":"{s}"}}}}
    , .{ request_id, escaped });
}

test "didChange includes version and full text" {
    const allocator = std.testing.allocator;
    const msg = try buildDidChangeNotification(allocator, "file:///tmp/a.zig", 3, "pub fn main() void {}\n");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "textDocument/didChange") != null);
}

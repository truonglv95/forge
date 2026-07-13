const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const completion = @import("completion.zig");
const hover = @import("hover.zig");
const navigation = @import("navigation.zig");
const references = @import("references.zig");
const rename = @import("rename.zig");
const format = @import("format.zig");
const diagnostics = @import("diagnostics.zig");
const sync = @import("sync.zig");
const registry = @import("registry.zig");

// LSP test suite covering framing, capability parsing, and registry.

test "jsonrpc encodeMessage produces correct framing" {
    const allocator = std.testing.allocator;
    const payload = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const msg = try jsonrpc.encodeMessage(allocator, payload);
    defer allocator.free(msg);
    // Content-Length header is followed by \r\n\r\n then payload.
    try std.testing.expect(std.mem.indexOf(u8, msg, "Content-Length:") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, payload) != null);
}

test "jsonrpc encodeMessage handles empty payload" {
    const allocator = std.testing.allocator;
    const msg = try jsonrpc.encodeMessage(allocator, "");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Content-Length: 0") != null);
}

test "completion buildDidOpenNotification includes languageId" {
    const allocator = std.testing.allocator;
    const msg = try completion.buildDidOpenNotification(allocator, "file:///test.zig", "zig", 1, "pub fn main() void {}");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/didOpen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "file:///test.zig") != null);
}

test "completion buildCompletionRequest includes position" {
    const allocator = std.testing.allocator;
    const msg = try completion.buildCompletionRequest(allocator, 1, "file:///test.zig", 0, 5);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"line\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"character\":5") != null);
}

test "completion parseCompletionResponse extracts items" {
    const allocator = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"items":[{"label":"fn main","detail":"() void"},{"label":"const","detail":"keyword"}]}}
    ;
    var list = try completion.parseCompletionResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("fn main", list.items[0].label);
    try std.testing.expectEqualStrings("() void", list.items[0].detail);
}

test "completion parseCompletionResponse handles empty result" {
    const allocator = std.testing.allocator;
    const response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"items\":[]}}";
    var list = try completion.parseCompletionResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "hover buildHoverRequest includes position" {
    const allocator = std.testing.allocator;
    const msg = try hover.buildHoverRequest(allocator, 1, "file:///test.zig", 3, 7);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/hover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"line\":3") != null);
}

test "hover parseHoverResponse extracts markdown content" {
    const allocator = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"contents":{"kind":"markdown","value":"fn main() void"}}}
    ;
    const text = try hover.parseHoverResponse(allocator, response);
    defer if (text) |t| allocator.free(t);
    try std.testing.expect(text != null);
    try std.testing.expectEqualStrings("fn main() void", text.?);
}

test "hover parseHoverResponse returns null for empty result" {
    const allocator = std.testing.allocator;
    const response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    const text = try hover.parseHoverResponse(allocator, response);
    try std.testing.expect(text == null);
}

test "navigation buildDefinitionRequest includes position" {
    const allocator = std.testing.allocator;
    const msg = try navigation.buildDefinitionRequest(allocator, 1, "file:///test.zig", 5, 10);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/definition\"") != null);
}

test "references buildReferencesRequest includes position" {
    const allocator = std.testing.allocator;
    const msg = try references.buildReferencesRequest(allocator, 1, "file:///test.zig", 2, 3);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/references\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"includeDeclaration\":true") != null);
}

test "rename buildRenameRequest includes newName" {
    const allocator = std.testing.allocator;
    const msg = try rename.buildRenameRequest(allocator, 1, "file:///test.zig", 0, 4, "newName");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"newName\":\"newName\"") != null);
}

test "format buildFormatRequest includes tabSize" {
    const allocator = std.testing.allocator;
    const msg = try format.buildFormatRequest(allocator, 1, "file:///test.zig", 4);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"tabSize\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"insertSpaces\":true") != null);
}

test "diagnostics buildDiagnosticRequest includes uri" {
    const allocator = std.testing.allocator;
    const msg = try diagnostics.buildDiagnosticRequest(allocator, 1, "file:///test.zig");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "file:///test.zig") != null);
}

test "sync buildDidOpenNotification includes languageId" {
    const allocator = std.testing.allocator;
    const msg = try sync.buildDidOpenNotification(allocator, "file:///test.py", "python", 1, "print('hello')");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"languageId\":\"python\"") != null);
}

test "sync buildDidChangeNotification includes version" {
    const allocator = std.testing.allocator;
    const msg = try sync.buildDidChangeNotification(allocator, "file:///test.zig", 3, "new content");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"version\":3") != null);
}

test "sync buildDidCloseNotification is valid JSON-RPC notification" {
    const allocator = std.testing.allocator;
    const msg = try sync.buildDidCloseNotification(allocator, "file:///test.zig");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/didClose\"") != null);
}

test "sync buildWorkspaceSymbolRequest includes query" {
    const allocator = std.testing.allocator;
    const msg = try sync.buildWorkspaceSymbolRequest(allocator, 1, "main");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"workspace/symbol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"query\":\"main\"") != null);
}

test "registry add and findForPath matches file pattern" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry.init(allocator);
    defer reg.deinit(allocator);

    try reg.add(allocator, .{
        .language_id = "zig",
        .server = "zls",
        .args = "",
        .file_pattern = "*.zig",
        .extension_id = "forge.lsp.zig",
    });

    const match = reg.findForPathUnlocked("src/main.zig");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("zls", match.?.server);
}

test "registry findForPath returns null for unmatched pattern" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry.init(allocator);
    defer reg.deinit(allocator);

    try reg.add(allocator, .{
        .language_id = "zig",
        .server = "zls",
        .args = "",
        .file_pattern = "*.zig",
        .extension_id = "forge.lsp.zig",
    });

    const match = reg.findForPathUnlocked("src/main.py");
    try std.testing.expect(match == null);
}

test "registry findByLanguageId matches language" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry.init(allocator);
    defer reg.deinit(allocator);

    try reg.add(allocator, .{
        .language_id = "python",
        .server = "pyright-langserver",
        .args = "--stdio",
        .file_pattern = "*.py",
        .extension_id = "forge.lsp.python",
    });

    const match = reg.findByLanguageId("python");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("pyright-langserver", match.?.server);
}

test "registry supports multiple language servers" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry.init(allocator);
    defer reg.deinit(allocator);

    try reg.add(allocator, .{
        .language_id = "zig",
        .server = "zls",
        .args = "",
        .file_pattern = "*.zig",
        .extension_id = "forge.lsp.zig",
    });
    try reg.add(allocator, .{
        .language_id = "python",
        .server = "pyright-langserver",
        .args = "--stdio",
        .file_pattern = "*.py",
        .extension_id = "forge.lsp.python",
    });

    try std.testing.expect(reg.findForPathUnlocked("main.zig") != null);
    try std.testing.expect(reg.findForPathUnlocked("main.py") != null);
    try std.testing.expect(reg.findForPathUnlocked("main.ts") == null);
}

test "sync buildSemanticTokensFullRequest includes uri" {
    const allocator = std.testing.allocator;
    const msg = try sync.buildSemanticTokensFullRequest(allocator, 1, "file:///test.zig");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"method\":\"textDocument/semanticTokens/full\"") != null);
}

test "diagnostics parseDiagnosticResponse extracts message" {
    const allocator = std.testing.allocator;
    // parseDiagnosticResponse expects publishDiagnostics format with "diagnostics" key.
    const response =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///test.zig","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":1,"message":"Syntax error"}]}}
    ;
    var list = try diagnostics.parseDiagnosticResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expect(list.items[0].message.len > 0);
}

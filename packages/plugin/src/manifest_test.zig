const std = @import("std");
const manifest_mod = @import("manifest.zig");
const wasm_mod = @import("wasm_runtime.zig");

// Comprehensive test suite for the extension manifest parser.
// Covers: basic parse, edge cases, error paths, WASM config, multi-entry.

test "manifest rejects empty source" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingExtensionSection, manifest_mod.parse(allocator, ""));
}

test "manifest rejects missing id" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingExtensionSection, manifest_mod.parse(allocator,
        \\[extension]
        \\name = "No ID"
    ));
}

test "manifest rejects unquoted string value" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, manifest_mod.parse(allocator,
        \\[extension]
        \\id = unquoted
        \\name = "Test"
    ));
}

test "manifest rejects unknown key in extension section" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownKey, manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\unknown_key = "value"
    ));
}

test "manifest rejects unknown section" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownKey, manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\
        \\[unknown_section]
        \\key = "value"
    ));
}

test "manifest parses with comments" {
    const allocator = std.testing.allocator;
    var manifest = try manifest_mod.parse(allocator,
        \\[extension]
        \\# This is a comment
        \\id = "forge.test" # inline comment
        \\name = "Test"
        \\version = "1.0.0"
        \\api_version = 1
    );
    defer manifest.deinit(allocator);
    try std.testing.expectEqualStrings("forge.test", manifest.id);
    try std.testing.expectEqualStrings("1.0.0", manifest.version);
}

test "manifest parses multiple commands" {
    const allocator = std.testing.allocator;
    var manifest = try manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\
        \\[[commands]]
        \\id = "cmd1"
        \\title = "Command 1"
        \\
        \\[[commands]]
        \\id = "cmd2"
        \\title = "Command 2"
        \\
        \\[[commands]]
        \\id = "cmd3"
        \\title = "Command 3"
    );
    defer manifest.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), manifest.commands.len);
    try std.testing.expectEqualStrings("cmd1", manifest.commands[0].id);
    try std.testing.expectEqualStrings("Command 3", manifest.commands[2].title);
}

test "manifest parses wasm runtime config" {
    const allocator = std.testing.allocator;
    var manifest = try manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\runtime = "wasm"
        \\entry = "main.wasm"
        \\wasm_max_memory = 1048576
        \\wasm_max_read_bytes = 4096
        \\wasm_max_string_len = 256
        \\wasm_max_path_len = 512
        \\wasm_max_lsp_request = 8192
        \\wasm_max_lsp_response = 16384
    );
    defer manifest.deinit(allocator);
    try std.testing.expectEqual(wasm_mod.RuntimeKind.wasm, manifest.runtime);
    try std.testing.expectEqualStrings("main.wasm", manifest.entry);
    try std.testing.expectEqual(@as(u32, 1048576), manifest.wasm_max_memory);
    try std.testing.expectEqual(@as(u32, 4096), manifest.wasm_max_read_bytes);
    try std.testing.expectEqual(@as(u32, 256), manifest.wasm_max_string_len);
    try std.testing.expectEqual(@as(u32, 512), manifest.wasm_max_path_len);
    try std.testing.expectEqual(@as(u32, 8192), manifest.wasm_max_lsp_request);
    try std.testing.expectEqual(@as(u32, 16384), manifest.wasm_max_lsp_response);
}

test "manifest defaults to native runtime" {
    const allocator = std.testing.allocator;
    var manifest = try manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
    );
    defer manifest.deinit(allocator);
    try std.testing.expectEqual(wasm_mod.RuntimeKind.native, manifest.runtime);
}

test "manifest rejects invalid api_version" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\api_version = "not_a_number"
    ));
}

test "manifest rejects invalid runtime" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\runtime = "invalid"
    ));
}

test "manifest rejects command title before id" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidSyntax, manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\
        \\[[commands]]
        \\title = "No ID first"
    ));
}

test "manifest handles empty values gracefully" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, manifest_mod.parse(allocator,
        \\[extension]
        \\id = ""
        \\name = "Test"
    ));
}

test "manifest parses language with file_pattern alias" {
    const allocator = std.testing.allocator;
    var manifest = try manifest_mod.parse(allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\
        \\[[languages]]
        \\id = "python"
        \\server = "pyright-langserver"
        \\args = "--stdio"
        \\pattern = "*.py"
        \\resolver = ""
    );
    defer manifest.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest.languages.len);
    try std.testing.expectEqualStrings("*.py", manifest.languages[0].file_pattern);
    try std.testing.expectEqualStrings("--stdio", manifest.languages[0].args);
    try std.testing.expectEqualStrings("", manifest.languages[0].server_resolver);
}

test "manifest deinit frees all allocations" {
    const allocator = std.testing.allocator;
    {
        var manifest = try manifest_mod.parse(allocator,
            \\[extension]
            \\id = "test"
            \\name = "Test"
            \\version = "1.0"
            \\
            \\[[commands]]
            \\id = "cmd"
            \\title = "Cmd"
            \\
            \\[[themes]]
            \\id = "theme"
            \\label = "Theme"
            \\path = "path"
            \\
            \\[[keybindings]]
            \\key = "cmd+k"
            \\command = "cmd"
            \\
            \\[[languages]]
            \\id = "zig"
            \\server = "zls"
            \\file_pattern = "*.zig"
        );
        manifest.deinit(allocator);
    }
    // If deinit didn't free properly, the allocator would leak.
    // std.testing.allocator catches leaks.
}

test "wasm_runtime isSafeWorkspacePath rejects path traversal" {
    try std.testing.expect(!wasm_mod.isSafeWorkspacePath("../etc/passwd", 256));
    try std.testing.expect(!wasm_mod.isSafeWorkspacePath("../../secret", 256));
    try std.testing.expect(!wasm_mod.isSafeWorkspacePath("/etc/passwd", 256));
}

test "wasm_runtime isSafeWorkspacePath accepts safe paths" {
    try std.testing.expect(wasm_mod.isSafeWorkspacePath("src/main.zig", 256));
    try std.testing.expect(wasm_mod.isSafeWorkspacePath("README.md", 256));
}

test "wasm_runtime isSafeWorkspacePath rejects too-long paths" {
    const long_path = "a" ** 300;
    try std.testing.expect(!wasm_mod.isSafeWorkspacePath(long_path, 256));
}

test "wasm_runtime parseRuntime maps strings" {
    try std.testing.expectEqual(wasm_mod.RuntimeKind.wasm, wasm_mod.parseRuntime("wasm").?);
    try std.testing.expectEqual(wasm_mod.RuntimeKind.native, wasm_mod.parseRuntime("native").?);
    try std.testing.expect(wasm_mod.parseRuntime("invalid") == null);
}

test "wasm_runtime limitsFromManifest applies defaults" {
    const manifest_mod2 = @import("manifest.zig");
    var manifest = try manifest_mod2.parse(std.testing.allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\runtime = "wasm"
    );
    defer manifest.deinit(std.testing.allocator);
    const limits = wasm_mod.limitsFromManifest(&manifest);
    try std.testing.expect(limits.max_memory_bytes > 0);
    try std.testing.expect(limits.max_lsp_request_bytes > 0);
}

test "wasm_runtime limitsFromManifest respects manifest values" {
    const manifest_mod2 = @import("manifest.zig");
    var manifest = try manifest_mod2.parse(std.testing.allocator,
        \\[extension]
        \\id = "test"
        \\name = "Test"
        \\runtime = "wasm"
        \\wasm_max_memory = 2097152
        \\wasm_max_lsp_request = 32768
    );
    defer manifest.deinit(std.testing.allocator);
    const limits = wasm_mod.limitsFromManifest(&manifest);
    try std.testing.expectEqual(@as(u32, 2097152), limits.max_memory_bytes);
    try std.testing.expectEqual(@as(u32, 32768), limits.max_lsp_request_bytes);
}

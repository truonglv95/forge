const std = @import("std");
const codebase_index = @import("codebase_index.zig");
const zig_ast = @import("ast_chunker.zig");
const tree_sitter = @import("tree_sitter_chunker.zig");
const structural = @import("structural_chunker.zig");

pub const Backend = enum { zig_ast, tree_sitter, structural, line_window };

pub const Language = struct {
    id: []const u8,
    backend: Backend,
};

pub fn detect(path: []const u8) Language {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .{ .id = "zig", .backend = .zig_ast };
    if (std.mem.eql(u8, ext, ".py")) return .{ .id = "python", .backend = .tree_sitter };
    if (std.mem.eql(u8, ext, ".ts")) return .{ .id = "typescript", .backend = .tree_sitter };
    if (std.mem.eql(u8, ext, ".tsx")) return .{ .id = "typescript", .backend = .tree_sitter };
    const profiles = [_]struct { ext: []const u8, id: []const u8 }{
        .{ .ext = ".js", .id = "javascript" },
        .{ .ext = ".jsx", .id = "javascript" },
        .{ .ext = ".rs", .id = "rust" },
        .{ .ext = ".go", .id = "go" },
        .{ .ext = ".c", .id = "c" },
        .{ .ext = ".h", .id = "c" },
        .{ .ext = ".cc", .id = "cpp" },
        .{ .ext = ".cpp", .id = "cpp" },
        .{ .ext = ".hpp", .id = "cpp" },
        .{ .ext = ".java", .id = "java" },
        .{ .ext = ".cs", .id = "csharp" },
        .{ .ext = ".kt", .id = "kotlin" },
        .{ .ext = ".kts", .id = "kotlin" },
        .{ .ext = ".swift", .id = "swift" },
        .{ .ext = ".rb", .id = "ruby" },
        .{ .ext = ".php", .id = "php" },
    };
    for (profiles) |profile| {
        if (std.mem.eql(u8, ext, profile.ext)) return .{ .id = profile.id, .backend = .structural };
    }
    return .{ .id = if (ext.len > 1) ext[1..] else "text", .backend = .line_window };
}

pub fn chunk(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file_hash: u64,
    content: []const u8,
) !?[]codebase_index.Chunk {
    const language = detect(path);
    return switch (language.backend) {
        .zig_ast => zig_ast.chunk(allocator, io, path, file_hash, content) catch null,
        .tree_sitter => treeSitterChunk(allocator, path, file_hash, content) catch null,
        .structural => structural.chunk(allocator, path, file_hash, content, language.id) catch null,
        .line_window => null,
    };
}

fn treeSitterChunk(
    allocator: std.mem.Allocator,
    path: []const u8,
    file_hash: u64,
    content: []const u8,
) ![]codebase_index.Chunk {
    const ext = std.fs.path.extension(path);
    const language: tree_sitter.Language = if (std.mem.eql(u8, ext, ".py"))
        .python
    else if (std.mem.eql(u8, ext, ".tsx"))
        .tsx
    else if (std.mem.eql(u8, ext, ".ts"))
        .typescript
    else
        return error.UnsupportedLanguage;
    return tree_sitter.chunk(allocator, path, file_hash, content, language);
}

test "registry selects stable language backends" {
    try std.testing.expectEqual(Backend.zig_ast, detect("main.zig").backend);
    try std.testing.expectEqualStrings("typescript", detect("app.tsx").id);
    try std.testing.expectEqual(Backend.tree_sitter, detect("server.py").backend);
    try std.testing.expectEqual(Backend.tree_sitter, detect("app.ts").backend);
    try std.testing.expectEqual(Backend.line_window, detect("README.md").backend);
}

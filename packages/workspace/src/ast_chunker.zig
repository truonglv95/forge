const std = @import("std");
const codebase_index = @import("codebase_index.zig");

/// AST chunking that ships with Forge's Zig compiler. No runtime downloads or
/// dynamically loaded parser code are allowed on the indexing path.
pub fn canParse(extension: []const u8) bool {
    return std.mem.eql(u8, extension, ".zig");
}

pub fn chunk(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file_hash: u64,
    content: []const u8,
) ![]codebase_index.Chunk {
    _ = io;
    if (!canParse(std.fs.path.extension(path))) return error.UnsupportedLanguage;

    const source = try allocator.dupeZ(u8, content);
    defer allocator.free(source);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len > 0) return error.ParseFailed;

    var chunks: std.ArrayList(codebase_index.Chunk) = .empty;
    errdefer {
        for (chunks.items) |item| codebase_index.freeChunk(allocator, item);
        chunks.deinit(allocator);
    }

    const declarations = tree.rootDecls();
    if (declarations.len == 0) return &.{};

    const first_decl_offset = expandStartForDocComments(content, tree.tokenStart(tree.firstToken(declarations[0])));
    if (std.mem.trim(u8, content[0..first_decl_offset], &std.ascii.whitespace).len > 0) {
        try appendRangeChunks(allocator, path, file_hash, content, 0, first_decl_offset, "file_header", "", &chunks);
    }

    for (declarations) |node| {
        const first_token = tree.firstToken(node);
        const last_token = tree.lastToken(node);
        const byte_start = expandStartForDocComments(content, tree.tokenStart(first_token));
        const byte_end: usize = @min(content.len, @as(usize, tree.tokenStart(last_token)) + tree.tokenSlice(last_token).len);
        if (byte_end <= byte_start) continue;

        var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
        const full_fn = tree.fullFnProto(&fn_buffer, node);
        const kind = if (full_fn != null) "function" else @tagName(tree.nodeTag(node));
        const symbol = if (full_fn) |fn_proto|
            if (fn_proto.name_token) |token| tree.tokenSlice(token) else "anonymous"
        else
            "";
        try appendRangeChunks(allocator, path, file_hash, content, byte_start, byte_end, kind, symbol, &chunks);
    }

    return try chunks.toOwnedSlice(allocator);
}

fn expandStartForDocComments(content: []const u8, token_start: usize) usize {
    var start = token_start;
    while (start > 0 and content[start - 1] != '\n') start -= 1;
    while (start > 0) {
        const previous_end = start - 1;
        var previous_start = previous_end;
        while (previous_start > 0 and content[previous_start - 1] != '\n') previous_start -= 1;
        const line = std.mem.trim(u8, content[previous_start..previous_end], " \t\r");
        if (!std.mem.startsWith(u8, line, "///") and !std.mem.startsWith(u8, line, "//!")) break;
        start = previous_start;
    }
    return start;
}

fn appendRangeChunks(
    allocator: std.mem.Allocator,
    path: []const u8,
    file_hash: u64,
    content: []const u8,
    range_start: usize,
    range_end: usize,
    kind: []const u8,
    symbol: []const u8,
    chunks: *std.ArrayList(codebase_index.Chunk),
) !void {
    var cursor = range_start;
    while (cursor < range_end) {
        var end = @min(range_end, cursor + codebase_index.max_chunk_bytes);
        if (end < range_end) {
            if (std.mem.findScalarLast(u8, content[cursor..end], '\n')) |relative| {
                if (relative > 0) end = cursor + relative + 1;
            }
        }
        if (end <= cursor) end = @min(range_end, cursor + codebase_index.max_chunk_bytes);

        const line_start = lineAtOffset(content, cursor);
        const line_end = lineAtOffset(content, if (end > cursor) end - 1 else end);
        var id_buf: [std.fs.max_path_bytes + 96]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{s}:{d}:{d}:{s}", .{ path, line_start, line_end, kind });

        const header = if (symbol.len > 0)
            try std.fmt.allocPrint(allocator, "// File: {s}, Symbol: {s}\n", .{ path, symbol })
        else
            try std.fmt.allocPrint(allocator, "// File: {s}\n", .{path});
        defer allocator.free(header);
        const full_text = try std.mem.concat(allocator, u8, &.{ header, content[cursor..end] });

        try chunks.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .path = try allocator.dupe(u8, path),
            .line_start = line_start,
            .line_end = line_end,
            .file_hash = file_hash,
            .text = full_text,
            .symbol = try allocator.dupe(u8, symbol),
            .kind = try allocator.dupe(u8, kind),
            .language = try allocator.dupe(u8, "zig"),
        });
        cursor = end;
    }
}

fn lineAtOffset(content: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (content[0..@min(offset, content.len)]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

test "Zig AST chunks preserve header and function symbols" {
    const allocator = std.testing.allocator;
    const source =
        \\//! module docs
        \\const std = @import("std");
        \\pub fn authenticateUser() void {}
        \\test "auth" {}
    ;
    const chunks = try chunk(allocator, std.testing.io, "auth.zig", 1, source);
    defer codebase_index.freeChunks(allocator, chunks);
    try std.testing.expect(chunks.len >= 3);
    var found_function = false;
    var found_test = false;
    for (chunks) |item| {
        if (std.mem.eql(u8, item.symbol, "authenticateUser")) found_function = true;
        if (std.mem.indexOf(u8, item.text, "test \"auth\"") != null) found_test = true;
        try std.testing.expect(item.text.len <= codebase_index.max_chunk_bytes);
    }
    try std.testing.expect(found_function);
    try std.testing.expect(found_test);
}

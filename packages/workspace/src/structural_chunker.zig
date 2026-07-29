const std = @import("std");
const codebase_index = @import("codebase_index.zig");

const Declaration = struct {
    byte_start: usize,
    line_start: u32,
    kind: []const u8,
    symbol: []const u8,
};

pub fn chunk(
    allocator: std.mem.Allocator,
    path: []const u8,
    file_hash: u64,
    content: []const u8,
    language: []const u8,
) ![]codebase_index.Chunk {
    var declarations: std.ArrayList(Declaration) = .empty;
    defer declarations.deinit(allocator);

    var offset: usize = 0;
    var line_no: u32 = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (classify(trimmed, language)) |classification| {
            try declarations.append(allocator, .{
                .byte_start = includeLeadingComments(content, offset),
                .line_start = line_no,
                .kind = classification.kind,
                .symbol = classification.symbol,
            });
        }
        offset += line.len + @intFromBool(offset + line.len < content.len);
    }
    if (declarations.items.len == 0) return &.{};

    var chunks: std.ArrayList(codebase_index.Chunk) = .empty;
    errdefer {
        for (chunks.items) |item| codebase_index.freeChunk(allocator, item);
        chunks.deinit(allocator);
    }
    if (declarations.items[0].byte_start > 0) {
        try appendBounded(allocator, path, file_hash, content, 0, declarations.items[0].byte_start, 1, "file_header", "", language, &chunks);
    }
    for (declarations.items, 0..) |declaration, index| {
        const end = if (index + 1 < declarations.items.len) declarations.items[index + 1].byte_start else content.len;
        try appendBounded(allocator, path, file_hash, content, declaration.byte_start, end, declaration.line_start, declaration.kind, declaration.symbol, language, &chunks);
    }
    return try chunks.toOwnedSlice(allocator);
}

const Classification = struct { kind: []const u8, symbol: []const u8 };

fn classify(line: []const u8, language: []const u8) ?Classification {
    if (line.len == 0 or isComment(line)) return null;
    const prefixes = if (std.mem.eql(u8, language, "python"))
        &[_][]const u8{ "def ", "async def ", "class " }
    else if (std.mem.eql(u8, language, "rust"))
        &[_][]const u8{ "fn ", "pub fn ", "struct ", "pub struct ", "enum ", "trait ", "impl " }
    else if (std.mem.eql(u8, language, "go"))
        &[_][]const u8{ "func ", "type " }
    else if (std.mem.eql(u8, language, "ruby"))
        &[_][]const u8{ "def ", "class ", "module " }
    else
        &[_][]const u8{ "function ", "export function ", "async function ", "class ", "export class ", "interface ", "export interface ", "struct ", "enum ", "trait ", "impl ", "record " };

    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            const rest = line[prefix.len..];
            return .{
                .kind = kindForPrefix(prefix),
                .symbol = firstIdentifier(rest),
            };
        }
    }

    // C-family and typed methods: declaration line with parentheses followed
    // by an opening brace, excluding control-flow statements.
    if (std.mem.indexOfScalar(u8, line, '(') != null and std.mem.indexOfScalar(u8, line, ')') != null and
        (std.mem.indexOfScalar(u8, line, '{') != null or std.mem.endsWith(u8, line, ")")) and
        !startsControlFlow(line))
    {
        const open = std.mem.indexOfScalar(u8, line, '(').?;
        var start = open;
        while (start > 0 and (std.ascii.isAlphanumeric(line[start - 1]) or line[start - 1] == '_')) start -= 1;
        if (start < open) return .{ .kind = "function", .symbol = line[start..open] };
    }
    return null;
}

fn kindForPrefix(prefix: []const u8) []const u8 {
    if (std.mem.indexOf(u8, prefix, "class") != null) return "class";
    if (std.mem.indexOf(u8, prefix, "struct") != null) return "struct";
    if (std.mem.indexOf(u8, prefix, "interface") != null) return "interface";
    if (std.mem.indexOf(u8, prefix, "enum") != null) return "enum";
    if (std.mem.indexOf(u8, prefix, "trait") != null) return "trait";
    if (std.mem.indexOf(u8, prefix, "impl") != null) return "impl";
    if (std.mem.indexOf(u8, prefix, "module") != null) return "module";
    if (std.mem.startsWith(u8, prefix, "type")) return "type";
    return "function";
}

fn firstIdentifier(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and !std.ascii.isAlphanumeric(text[start]) and text[start] != '_') start += 1;
    var end = start;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    return text[start..end];
}

fn startsControlFlow(line: []const u8) bool {
    const controls = [_][]const u8{ "if ", "for ", "while ", "switch ", "catch ", "return " };
    for (controls) |prefix| if (std.mem.startsWith(u8, line, prefix)) return true;
    return false;
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "#") or std.mem.startsWith(u8, line, "/*") or std.mem.startsWith(u8, line, "*");
}

fn includeLeadingComments(content: []const u8, offset: usize) usize {
    var start = offset;
    while (start > 0 and content[start - 1] != '\n') start -= 1;
    while (start > 0) {
        const previous_end = start - 1;
        var previous_start = previous_end;
        while (previous_start > 0 and content[previous_start - 1] != '\n') previous_start -= 1;
        const line = std.mem.trim(u8, content[previous_start..previous_end], " \t\r");
        if (!isComment(line) and line.len != 0) break;
        start = previous_start;
    }
    return start;
}

fn appendBounded(
    allocator: std.mem.Allocator,
    path: []const u8,
    file_hash: u64,
    content: []const u8,
    start: usize,
    end: usize,
    line_hint: u32,
    kind: []const u8,
    symbol: []const u8,
    language: []const u8,
    chunks: *std.ArrayList(codebase_index.Chunk),
) !void {
    var cursor = start;
    var line_start = line_hint;
    while (cursor < end) {
        var chunk_end = @min(end, cursor + codebase_index.max_chunk_bytes);
        if (chunk_end < end) {
            if (std.mem.findScalarLast(u8, content[cursor..chunk_end], '\n')) |newline| {
                if (newline > 0) chunk_end = cursor + newline + 1;
            }
        }
        if (chunk_end <= cursor) chunk_end = @min(end, cursor + codebase_index.max_chunk_bytes);
        const line_end = line_start + @as(u32, @intCast(std.mem.count(u8, content[cursor..chunk_end], "\n")));
        var id_buf: [std.fs.max_path_bytes + 96]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{s}:{d}:{d}:{s}", .{ path, line_start, line_end, kind });
        try chunks.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .path = try allocator.dupe(u8, path),
            .line_start = line_start,
            .line_end = line_end,
            .file_hash = file_hash,
            .text = try allocator.dupe(u8, content[cursor..chunk_end]),
            .symbol = try allocator.dupe(u8, symbol),
            .kind = try allocator.dupe(u8, kind),
            .language = try allocator.dupe(u8, language),
        });
        cursor = chunk_end;
        line_start = line_end + 1;
    }
}

test "structural chunker recognizes Python and TypeScript declarations" {
    const allocator = std.testing.allocator;
    const python = "import os\n\n# docs\ndef authenticate_user(value):\n    return value\n\nclass SessionStore:\n    pass\n";
    const chunks = try chunk(allocator, "auth.py", 1, python, "python");
    defer codebase_index.freeChunks(allocator, chunks);
    try std.testing.expect(chunks.len >= 3);
    try std.testing.expectEqualStrings("authenticate_user", chunks[1].symbol);
    try std.testing.expectEqualStrings("python", chunks[1].language);

    const typescript = "export function renderEditor() { return true; }\nexport class Workbench {}\n";
    const ts_chunks = try chunk(allocator, "app.ts", 1, typescript, "typescript");
    defer codebase_index.freeChunks(allocator, ts_chunks);
    try std.testing.expectEqualStrings("renderEditor", ts_chunks[0].symbol);
}

const std = @import("std");
const codebase_index = @import("codebase_index.zig");

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_python() *const c.TSLanguage;
extern fn tree_sitter_typescript() *const c.TSLanguage;
extern fn tree_sitter_tsx() *const c.TSLanguage;

pub const Language = enum {
    python,
    typescript,
    tsx,

    pub fn id(self: Language) []const u8 {
        return switch (self) {
            .python => "python",
            .typescript, .tsx => "typescript",
        };
    }

    fn parser(self: Language) *const c.TSLanguage {
        return switch (self) {
            .python => tree_sitter_python(),
            .typescript => tree_sitter_typescript(),
            .tsx => tree_sitter_tsx(),
        };
    }
};

const Declaration = struct {
    byte_start: usize,
    byte_end: usize,
    kind: []const u8,
    symbol: []const u8,
};

pub fn chunk(
    allocator: std.mem.Allocator,
    path: []const u8,
    file_hash: u64,
    content: []const u8,
    language: Language,
) ![]codebase_index.Chunk {
    current_source = content;
    defer current_source = "";

    const parser = c.ts_parser_new() orelse return error.ParserCreateFailed;
    defer c.ts_parser_delete(parser);

    if (!c.ts_parser_set_language(parser, language.parser())) return error.UnsupportedLanguageVersion;

    const len: u32 = @intCast(content.len);
    const tree = c.ts_parser_parse_string(parser, null, content.ptr, len) orelse return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    const root = c.ts_tree_root_node(tree);
    var declarations: std.ArrayList(Declaration) = .empty;
    defer declarations.deinit(allocator);

    try collectDeclarations(allocator, root, language, &declarations);
    if (declarations.items.len == 0) return &.{};

    std.sort.pdq(Declaration, declarations.items, {}, struct {
        fn less(_: void, a: Declaration, b: Declaration) bool {
            if (a.byte_start != b.byte_start) return a.byte_start < b.byte_start;
            return a.byte_end < b.byte_end;
        }
    }.less);

    var chunks: std.ArrayList(codebase_index.Chunk) = .empty;
    errdefer {
        for (chunks.items) |item| codebase_index.freeChunk(allocator, item);
        chunks.deinit(allocator);
    }

    const first_decl_start = expandStartForLeadingTrivia(content, declarations.items[0].byte_start, language);
    if (first_decl_start > 0) {
        try appendRangeChunks(allocator, path, file_hash, content, 0, first_decl_start, "file_header", "", language.id(), &chunks);
    }

    for (declarations.items) |decl| {
        if (decl.byte_end <= decl.byte_start or decl.byte_start >= content.len) continue;
        const end = @min(decl.byte_end, content.len);
        try appendRangeChunks(
            allocator,
            path,
            file_hash,
            content,
            expandStartForLeadingTrivia(content, decl.byte_start, language),
            end,
            decl.kind,
            decl.symbol,
            language.id(),
            &chunks,
        );
    }

    return try chunks.toOwnedSlice(allocator);
}

fn collectDeclarations(
    allocator: std.mem.Allocator,
    node: c.TSNode,
    language: Language,
    out: *std.ArrayList(Declaration),
) !void {
    if (c.ts_node_is_null(node)) return;

    if (classify(cString(c.ts_node_type(node)), language)) |kind| {
        const name = declarationName(node, kind, language);
        try out.append(allocator, .{
            .byte_start = c.ts_node_start_byte(node),
            .byte_end = c.ts_node_end_byte(node),
            .kind = kind,
            .symbol = name,
        });
        return;
    }

    const count = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try collectDeclarations(allocator, c.ts_node_named_child(node, i), language, out);
    }
}

fn classify(node_type: []const u8, language: Language) ?[]const u8 {
    return switch (language) {
        .python => {
            if (std.mem.eql(u8, node_type, "function_definition")) return "function";
            if (std.mem.eql(u8, node_type, "class_definition")) return "class";
            return null;
        },
        .typescript, .tsx => {
            if (std.mem.eql(u8, node_type, "function_declaration")) return "function";
            if (std.mem.eql(u8, node_type, "generator_function_declaration")) return "function";
            if (std.mem.eql(u8, node_type, "class_declaration")) return "class";
            if (std.mem.eql(u8, node_type, "interface_declaration")) return "interface";
            if (std.mem.eql(u8, node_type, "type_alias_declaration")) return "type";
            if (std.mem.eql(u8, node_type, "enum_declaration")) return "enum";
            if (std.mem.eql(u8, node_type, "lexical_declaration")) return "constant";
            return null;
        },
    };
}

fn declarationName(node: c.TSNode, kind: []const u8, language: Language) []const u8 {
    if (fieldText(node, "name")) |name| {
        if (name.len > 0) return name;
    }
    if (language == .typescript or language == .tsx) {
        if (std.mem.eql(u8, cString(c.ts_node_type(node)), "lexical_declaration")) {
            return lexicalDeclarationName(node) orelse "";
        }
    }
    return fallbackDeclarationName(nodeText(node), kind);
}

fn lexicalDeclarationName(node: c.TSNode) ?[]const u8 {
    const count = c.ts_node_named_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = c.ts_node_named_child(node, i);
        if (!std.mem.eql(u8, cString(c.ts_node_type(child)), "variable_declarator")) continue;
        if (fieldText(child, "name")) |name| return name;
    }
    return null;
}

fn fallbackDeclarationName(text: []const u8, kind: []const u8) []const u8 {
    const keywords = if (std.mem.eql(u8, kind, "function"))
        &[_][]const u8{ "async function", "function", "def" }
    else if (std.mem.eql(u8, kind, "class"))
        &[_][]const u8{"class"}
    else if (std.mem.eql(u8, kind, "interface"))
        &[_][]const u8{"interface"}
    else if (std.mem.eql(u8, kind, "type"))
        &[_][]const u8{"type"}
    else if (std.mem.eql(u8, kind, "enum"))
        &[_][]const u8{"enum"}
    else if (std.mem.eql(u8, kind, "constant"))
        &[_][]const u8{ "const", "let", "var" }
    else
        &[_][]const u8{};

    for (keywords) |keyword| {
        if (std.mem.indexOf(u8, text, keyword)) |pos| {
            const after = text[pos + keyword.len ..];
            return firstIdentifier(after);
        }
    }
    return "";
}

fn firstIdentifier(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and !isIdentStart(text[start])) start += 1;
    var end = start;
    while (end < text.len and isIdentContinue(text[end])) end += 1;
    return text[start..end];
}

fn isIdentStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isIdentContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$';
}

fn fieldText(node: c.TSNode, comptime field: []const u8) ?[]const u8 {
    const child = c.ts_node_child_by_field_name(node, field.ptr, @intCast(field.len));
    if (c.ts_node_is_null(child)) return null;
    return nodeText(child);
}

fn nodeText(node: c.TSNode) []const u8 {
    const start: usize = c.ts_node_start_byte(node);
    const end: usize = c.ts_node_end_byte(node);
    return sourceSlice(start, end);
}

threadlocal var current_source: []const u8 = "";

fn sourceSlice(start: usize, end: usize) []const u8 {
    if (start >= current_source.len or end <= start) return "";
    return current_source[start..@min(end, current_source.len)];
}

fn cString(ptr: [*c]const u8) []const u8 {
    return std.mem.span(ptr);
}

fn expandStartForLeadingTrivia(content: []const u8, byte_start: usize, language: Language) usize {
    var start = byte_start;
    while (start > 0 and content[start - 1] != '\n') start -= 1;
    while (start > 0) {
        const previous_end = start - 1;
        var previous_start = previous_end;
        while (previous_start > 0 and content[previous_start - 1] != '\n') previous_start -= 1;
        const line = std.mem.trim(u8, content[previous_start..previous_end], " \t\r");
        if (!isTriviaLine(line, language)) break;
        start = previous_start;
    }
    return start;
}

fn isTriviaLine(line: []const u8, language: Language) bool {
    if (line.len == 0) return true;
    return switch (language) {
        .python => std.mem.startsWith(u8, line, "#"),
        .typescript, .tsx => std.mem.startsWith(u8, line, "//") or
            std.mem.startsWith(u8, line, "/*") or
            std.mem.startsWith(u8, line, "*"),
    };
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
    language: []const u8,
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
        try chunks.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .path = try allocator.dupe(u8, path),
            .line_start = line_start,
            .line_end = line_end,
            .file_hash = file_hash,
            .text = try allocator.dupe(u8, content[cursor..end]),
            .symbol = try allocator.dupe(u8, symbol),
            .kind = try allocator.dupe(u8, kind),
            .language = try allocator.dupe(u8, language),
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

test "tree-sitter chunks Python declarations" {
    const allocator = std.testing.allocator;
    const source =
        \\import os
        \\
        \\# docs
        \\def authenticate_user(value):
        \\    return value
        \\
        \\class SessionStore:
        \\    pass
    ;
    current_source = source;
    const chunks = try chunk(allocator, "auth.py", 1, source, .python);
    defer codebase_index.freeChunks(allocator, chunks);
    try std.testing.expect(chunks.len >= 3);
    try std.testing.expectEqualStrings("authenticate_user", chunks[1].symbol);
    try std.testing.expectEqualStrings("function", chunks[1].kind);
    try std.testing.expectEqualStrings("python", chunks[1].language);
}

test "tree-sitter chunks TypeScript and TSX declarations" {
    const allocator = std.testing.allocator;
    const ts_source =
        \\export function renderEditor() { return true; }
        \\export interface Workbench { id: string }
        \\const activePane = 1;
    ;
    current_source = ts_source;
    const chunks = try chunk(allocator, "app.ts", 1, ts_source, .typescript);
    defer codebase_index.freeChunks(allocator, chunks);
    try std.testing.expect(chunks.len >= 3);
    try std.testing.expectEqualStrings("renderEditor", chunks[0].symbol);
    try std.testing.expectEqualStrings("function", chunks[0].kind);

    const tsx_source =
        \\export class View extends React.Component {
        \\  render() { return <div />; }
        \\}
    ;
    current_source = tsx_source;
    const tsx_chunks = try chunk(allocator, "view.tsx", 1, tsx_source, .tsx);
    defer codebase_index.freeChunks(allocator, tsx_chunks);
    try std.testing.expectEqualStrings("View", tsx_chunks[0].symbol);
}

const std = @import("std");
const renderer = @import("forge-renderer");
const render_theme = @import("../theme.zig");
const Buffer = @import("forge-editor").Buffer;
const lsp = @import("forge-lsp");

pub fn color(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return render_theme.color(rgba);
}

const Language = enum {
    zig,
    typescript,
    javascript,
    python,
    rust,
    go,
    unknown,
};

fn detectLanguage(path: []const u8) Language {
    if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon")) return .zig;
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return .typescript;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".jsx") or std.mem.endsWith(u8, path, ".mjs") or std.mem.endsWith(u8, path, ".cjs")) return .javascript;
    if (std.mem.endsWith(u8, path, ".py") or std.mem.endsWith(u8, path, ".pyw")) return .python;
    if (std.mem.endsWith(u8, path, ".rs")) return .rust;
    if (std.mem.endsWith(u8, path, ".go")) return .go;
    return .unknown;
}

fn isPunctuation(ch: u8) bool {
    return switch (ch) {
        '(', ')', '{', '}', ';', ',', '[', ']', '.', ':', '?' => true,
        else => false,
    };
}

fn isOperator(ch: u8) bool {
    return switch (ch) {
        '+', '-', '*', '/', '%', '=', '!', '<', '>', '&', '|', '^', '~' => true,
        else => false,
    };
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isDelimiter(ch: u8) bool {
    return std.ascii.isWhitespace(ch) or isPunctuation(ch) or isOperator(ch) or ch == '"' or ch == '\'' or ch == '`';
}

fn hasWord(words: []const []const u8, word: []const u8) bool {
    for (words) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isKeywordFor(language: Language, word: []const u8) bool {
    const zig_keywords = [_][]const u8{
        "addrspace", "align",   "allowzero",   "and",     "anyframe",    "anytype", "asm",      "async",       "await",          "break",  "callconv", "catch",
        "comptime",  "const",   "continue",    "defer",   "else",        "enum",    "errdefer", "error",       "export",         "extern", "fn",       "for",
        "if",        "inline",  "linksection", "noalias", "nosuspend",   "opaque",  "or",       "orelse",      "packed",         "pub",    "resume",   "return",
        "struct",    "suspend", "switch",      "test",    "threadlocal", "try",     "union",    "unreachable", "usingnamespace", "var",    "volatile", "while",
    };
    const ts_js_keywords = [_][]const u8{
        "abstract", "as",        "async",  "await",      "break",  "case",    "catch",     "class",      "const",     "constructor", "continue",  "debugger",
        "declare",  "default",   "delete", "do",         "else",   "enum",    "export",    "extends",    "false",     "finally",     "for",       "from",
        "function", "get",       "if",     "implements", "import", "in",      "infer",     "instanceof", "interface", "is",          "keyof",     "let",
        "module",   "namespace", "new",    "null",       "of",     "private", "protected", "public",     "readonly",  "return",      "satisfies", "set",
        "static",   "super",     "switch", "this",       "throw",  "true",    "try",       "type",       "typeof",    "undefined",   "var",       "void",
        "while",    "with",      "yield",
    };
    const python_keywords = [_][]const u8{
        "False", "None",   "True",    "and", "as",    "assert", "async", "await",  "break", "class", "continue", "def",      "del", "elif",
        "else",  "except", "finally", "for", "from",  "global", "if",    "import", "in",    "is",    "lambda",   "nonlocal", "not", "or",
        "pass",  "raise",  "return",  "try", "while", "with",   "yield",
    };
    const rust_keywords = [_][]const u8{
        "Self",   "as",     "async", "await", "break", "const", "continue", "crate", "dyn",   "else",  "enum", "extern", "false",  "fn",
        "for",    "if",     "impl",  "in",    "let",   "loop",  "match",    "mod",   "move",  "mut",   "pub",  "ref",    "return", "self",
        "static", "struct", "super", "trait", "true",  "type",  "unsafe",   "use",   "where", "while",
    };
    const go_keywords = [_][]const u8{
        "break", "case",   "chan",      "const", "continue", "default", "defer",  "else",   "fallthrough", "for",    "func", "go",  "goto",
        "if",    "import", "interface", "map",   "package",  "range",   "return", "select", "struct",      "switch", "type", "var",
    };

    return switch (language) {
        .zig => hasWord(&zig_keywords, word),
        .typescript, .javascript => hasWord(&ts_js_keywords, word),
        .python => hasWord(&python_keywords, word),
        .rust => hasWord(&rust_keywords, word),
        .go => hasWord(&go_keywords, word),
        .unknown => hasWord(&zig_keywords, word),
    };
}

pub fn isKeyword(word: []const u8) bool {
    return isKeywordFor(.zig, word);
}

fn isLineCommentStart(line: []const u8, index: usize, language: Language) bool {
    if (index >= line.len) return false;
    if (language == .python) return line[index] == '#';
    return line[index] == '/' and index + 1 < line.len and line[index + 1] == '/';
}

fn isBlockCommentStart(line: []const u8, index: usize, language: Language) bool {
    if (language == .python or index + 1 >= line.len) return false;
    return line[index] == '/' and line[index + 1] == '*';
}

fn nextNonSpace(line: []const u8, index: usize) ?u8 {
    var i = index;
    while (i < line.len) : (i += 1) {
        if (!std.ascii.isWhitespace(line[i])) return line[i];
    }
    return null;
}

fn prevNonSpace(line: []const u8, index: usize) ?u8 {
    var i = index;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(line[i])) return line[i];
    }
    return null;
}

pub fn segmentColor(line: []const u8, index: usize, theme: *const @import("forge-workspace").Theme) renderer.Color {
    return segmentColorForLanguage(line, index, .zig, theme);
}

fn segmentColorForLanguage(line: []const u8, index: usize, language: Language, theme: *const @import("forge-workspace").Theme) renderer.Color {
    const ch = line[index];
    if (std.ascii.isWhitespace(ch)) return color(theme.colors.editor_fg);
    if (isLineCommentStart(line, index, language) or isBlockCommentStart(line, index, language)) return color(theme.colors.comment);
    if (ch == '"' or ch == '\'' or ch == '`') return color(theme.colors.string_color);
    if (isPunctuation(ch) or isOperator(ch)) return color(theme.colors.punctuation);

    var end = index;
    while (end < line.len and !isDelimiter(line[end])) : (end += 1) {}
    const word = line[index..end];
    if (word.len > 0 and std.ascii.isDigit(word[0])) return color(theme.colors.number);
    if (isKeywordFor(language, word)) return color(theme.colors.keyword);
    if (nextNonSpace(line, end) == '(' and word.len > 0 and isIdentifierStart(word[0])) return color(theme.colors.function);
    if (prevNonSpace(line, index) == '.') return color(theme.colors.property);
    if (word.len > 0 and std.ascii.isUpper(word[0])) return color(theme.colors.type);
    return color(theme.colors.editor_fg);
}

fn scanString(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (line[i] == quote) {
            i += 1;
            break;
        }
    }
    return i;
}

fn scanBlockComment(line: []const u8, start: usize) usize {
    var i = start + 2;
    while (i + 1 < line.len) : (i += 1) {
        if (line[i] == '*' and line[i + 1] == '/') return i + 2;
    }
    return line.len;
}

fn scanNumber(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.')) break;
    }
    return i;
}

fn scanFallbackToken(line: []const u8, start: usize, language: Language) usize {
    const ch = line[start];
    if (std.ascii.isWhitespace(ch)) {
        var i = start + 1;
        while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
        return i;
    }
    if (isLineCommentStart(line, start, language)) return line.len;
    if (isBlockCommentStart(line, start, language)) return scanBlockComment(line, start);
    if (ch == '"' or ch == '\'' or ch == '`') return scanString(line, start);
    if (std.ascii.isDigit(ch)) return scanNumber(line, start);
    if (isPunctuation(ch) or isOperator(ch)) {
        var i = start + 1;
        while (i < line.len and isOperator(line[i]) and isOperator(ch)) : (i += 1) {}
        return i;
    }
    if (isIdentifierStart(ch)) {
        var i = start + 1;
        while (i < line.len and isIdentifierChar(line[i])) : (i += 1) {}
        return i;
    }
    return start + 1;
}

/// Returns the base color for a semantic token type (ignoring modifiers).
fn baseTokenColor(token_type: u32, theme: *const @import("forge-workspace").Theme) renderer.Color {
    const types = lsp.semantic_tokens.SemanticTokenTypes;
    if (token_type == @intFromEnum(types.namespace)) return color(theme.colors.text_muted);
    if (token_type == @intFromEnum(types.type)) return color(theme.colors.type);
    if (token_type == @intFromEnum(types.class)) return color(theme.colors.type);
    if (token_type == @intFromEnum(types.@"enum")) return color(theme.colors.type);
    if (token_type == @intFromEnum(types.interface)) return color(theme.colors.type);
    if (token_type == @intFromEnum(types.@"struct")) return color(theme.colors.type);
    if (token_type == @intFromEnum(types.typeParameter)) return color(theme.colors.type);
    if (token_type == @intFromEnum(types.parameter)) return color(theme.colors.parameter);
    if (token_type == @intFromEnum(types.variable)) return color(theme.colors.variable);
    if (token_type == @intFromEnum(types.property)) return color(theme.colors.property);
    if (token_type == @intFromEnum(types.enumMember)) return color(theme.colors.property);
    if (token_type == @intFromEnum(types.event)) return color(theme.colors.property);
    if (token_type == @intFromEnum(types.function)) return color(theme.colors.function);
    if (token_type == @intFromEnum(types.method)) return color(theme.colors.function);
    if (token_type == @intFromEnum(types.macro)) return color(theme.colors.function);
    if (token_type == @intFromEnum(types.keyword)) return color(theme.colors.keyword);
    if (token_type == @intFromEnum(types.modifier)) return color(theme.colors.keyword);
    if (token_type == @intFromEnum(types.comment)) return color(theme.colors.comment);
    if (token_type == @intFromEnum(types.string)) return color(theme.colors.string_color);
    if (token_type == @intFromEnum(types.number)) return color(theme.colors.number);
    if (token_type == @intFromEnum(types.regexp)) return color(theme.colors.string_color);
    if (token_type == @intFromEnum(types.operator)) return color(theme.colors.punctuation);
    if (token_type == @intFromEnum(types.decorator)) return color(theme.colors.function);
    return color(theme.colors.editor_fg);
}

/// Adjusts a base color according to LSP semantic-token modifier bits.
///
/// The renderer's TextSpan only carries color (no italic/bold/strikethrough
/// flags), so we convey modifiers via color shifts:
///
/// - `deprecated`        — reduce alpha to 0.45 (faded, signals "going away")
/// - `documentation`     — use comment color (documentation is often a comment)
/// - `defaultLibrary`    — use type color (built-in types like String, Array)
/// - `declaration` / `definition` — boost brightness by 12% (signals importance)
/// - `static`            — slight cool tint (shift toward blue)
/// - `readonly` / `modification` — no color shift (would need italics to convey)
fn applyModifierAdjustments(base: renderer.Color, modifiers: u32, theme: *const @import("forge-workspace").Theme) renderer.Color {
    var c = base;

    if (lsp.semantic_tokens.hasModifier(modifiers, .documentation)) {
        // Documentation tokens are typically comments — use comment color.
        c = color(theme.colors.comment);
    } else if (lsp.semantic_tokens.hasModifier(modifiers, .default_library)) {
        // Built-in / stdlib symbols — use type color.
        c = color(theme.colors.type);
    }

    if (lsp.semantic_tokens.hasModifier(modifiers, .declaration) or
        lsp.semantic_tokens.hasModifier(modifiers, .definition))
    {
        // Declaration/definition is more important than a mere reference —
        // boost brightness by ~12%, clamped to 1.0.
        const boost: f32 = 1.12;
        c.r = @min(1.0, c.r * boost);
        c.g = @min(1.0, c.g * boost);
        c.b = @min(1.0, c.b * boost);
    }

    if (lsp.semantic_tokens.hasModifier(modifiers, .static)) {
        // Static members get a subtle cool tint (shift toward blue).
        c.b = @min(1.0, c.b * 1.15 + 0.05);
    }

    if (lsp.semantic_tokens.hasModifier(modifiers, .deprecated)) {
        // Deprecated — fade to 45% opacity so it visually recedes.
        c.a = 0.45;
    }

    return c;
}

fn tokenColor(token_type: u32, modifiers: u32, theme: *const @import("forge-workspace").Theme) renderer.Color {
    const base = baseTokenColor(token_type, theme);
    return applyModifierAdjustments(base, modifiers, theme);
}

/// Binary search for the first semantic token at or after `line_idx`.
/// Per-call (no caching) — safe across multiple files and split editor.
fn firstSemanticTokenForLine(tokens: []lsp.semantic_tokens.AbsoluteToken, line_idx: usize) usize {
    if (tokens.len == 0) return 0;
    var left: usize = 0;
    var right: usize = tokens.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (tokens[mid].line < line_idx) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    return left;
}

pub fn drawHighlightedLine(
    file_path: []const u8,
    line: []const u8,
    line_idx: usize,
    col_offset: usize,
    x: f32,
    y: f32,
    theme: *const @import("forge-workspace").Theme,
    semantic_tokens: ?[]lsp.semantic_tokens.AbsoluteToken,
) void {
    const font_size = theme.editor_font_size;
    var spans: [96]renderer.TextSpan = undefined;
    var span_count: usize = 0;

    // Use semantic tokens if available
    if (semantic_tokens) |tokens| {
        var i = firstSemanticTokenForLine(tokens, line_idx);
        var last_end: usize = 0;
        while (i < tokens.len and tokens[i].line == line_idx and span_count < spans.len) : (i += 1) {
            const tok = tokens[i];

            // Skip if token is completely before the slice
            if (tok.start + tok.length <= col_offset) continue;
            // Break if token starts after the slice
            if (tok.start >= col_offset + line.len) break;

            const adj_start = if (tok.start > col_offset) tok.start - col_offset else 0;
            const tok_end = tok.start + tok.length;
            const adj_end = @min(line.len, tok_end - col_offset);
            const adj_len = adj_end - adj_start;

            if (adj_start > last_end) {
                // Gap
                const gap_len = adj_start - last_end;
                const c = color(theme.colors.editor_fg);
                spans[span_count] = .{ .offset = last_end, .length = gap_len, .r = c.r, .g = c.g, .b = c.b, .a = c.a };
                span_count += 1;
            }
            if (span_count >= spans.len) break;
            const c = tokenColor(tok.token_type, tok.modifiers, theme);
            spans[span_count] = .{ .offset = adj_start, .length = adj_len, .r = c.r, .g = c.g, .b = c.b, .a = c.a };
            span_count += 1;
            last_end = adj_start + adj_len;
        }
        if (last_end < line.len and span_count < spans.len) {
            const c = color(theme.colors.editor_fg);
            spans[span_count] = .{ .offset = last_end, .length = line.len - last_end, .r = c.r, .g = c.g, .b = c.b, .a = c.a };
            span_count += 1;
        }
        if (span_count > 0) {
            renderer.Renderer.drawStyledText(line, x, y, font_size, spans[0..span_count]);
            return;
        }
    }

    // Fallback to language-aware lexical highlighting. This is intentionally
    // line-local; LSP semantic tokens remain the preferred source when present.
    const language = detectLanguage(file_path);
    var i: usize = 0;
    while (i < line.len and span_count < spans.len) {
        const start = i;
        i = scanFallbackToken(line, start, language);
        const c = segmentColorForLanguage(line, start, language, theme);
        spans[span_count] = .{ .offset = start, .length = i - start, .r = c.r, .g = c.g, .b = c.b, .a = c.a };
        span_count += 1;
    }
    if (span_count == 0) return;
    renderer.Renderer.drawStyledText(line, x, y, font_size, spans[0..span_count]);
}

test "detects editor syntax language from path" {
    try std.testing.expectEqual(Language.zig, detectLanguage("src/main.zig"));
    try std.testing.expectEqual(Language.typescript, detectLanguage("web/App.tsx"));
    try std.testing.expectEqual(Language.javascript, detectLanguage("scripts/build.mjs"));
    try std.testing.expectEqual(Language.python, detectLanguage("tools/index.py"));
    try std.testing.expectEqual(Language.rust, detectLanguage("src/lib.rs"));
    try std.testing.expectEqual(Language.go, detectLanguage("cmd/server.go"));
}

test "language keyword sets are separate" {
    try std.testing.expect(isKeywordFor(.typescript, "interface"));
    try std.testing.expect(!isKeywordFor(.zig, "interface"));
    try std.testing.expect(isKeywordFor(.python, "elif"));
    try std.testing.expect(isKeywordFor(.rust, "impl"));
    try std.testing.expect(isKeywordFor(.go, "defer"));
}

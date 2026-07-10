const std = @import("std");
const renderer = @import("forge-renderer");
const render_theme = @import("../theme.zig");
const Buffer = @import("forge-editor").Buffer;
const lsp = @import("forge-lsp");

pub fn color(rgba: @import("forge-workspace").Rgba) renderer.Color {
    return render_theme.color(rgba);
}

fn isPunctuation(ch: u8) bool {
    return ch == '(' or ch == ')' or ch == '{' or ch == '}' or ch == ';' or ch == ',' or ch == '[' or ch == ']';
}

pub fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "pub", "fn", "const", "var", "struct", "enum", "union", "return", "try", "catch", "if", "else", "switch", "while", "for", "break", "continue", "defer", "errdefer" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

pub fn segmentColor(line: []const u8, index: usize, theme: *const @import("forge-workspace").Theme) renderer.Color {
    const ch = line[index];
    if (ch == ' ' or ch == '\t') return color(theme.colors.editor_fg);
    if (isPunctuation(ch)) return color(theme.colors.punctuation);
    var end = index;
    while (end < line.len and line[end] != ' ' and !isPunctuation(line[end])) : (end += 1) {}
    const word = line[index..end];
    if (word.len > 0 and word[0] >= '0' and word[0] <= '9') return color(theme.colors.number);
    if (isKeyword(word)) return color(theme.colors.keyword);
    return color(theme.colors.editor_fg);
}

fn tokenColor(token_type: u32, theme: *const @import("forge-workspace").Theme) renderer.Color {
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

pub fn drawHighlightedLine(
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
        // Binary search for first token on this line
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
        var i = left;
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
            const c = tokenColor(tok.token_type, theme);
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

    // Fallback to lexical
    var i: usize = 0;
    while (i < line.len and span_count < spans.len) {
        const start = i;
        if (line[i] == ' ') {
            i += 1;
        } else if (isPunctuation(line[i])) {
            i += 1;
        } else {
            while (i < line.len and line[i] != ' ' and !isPunctuation(line[i])) : (i += 1) {}
        }
        const c = segmentColor(line, start, theme);
        spans[span_count] = .{ .offset = start, .length = i - start, .r = c.r, .g = c.g, .b = c.b, .a = c.a };
        span_count += 1;
    }
    if (span_count == 0) return;
    renderer.Renderer.drawStyledText(line, x, y, font_size, spans[0..span_count]);
}

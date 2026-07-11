const std = @import("std");

const stop_words = std.StaticStringMap(void).initComptime(.{
    .{ "the", {} },    .{ "a", {} },       .{ "an", {} },     .{ "and", {} },       .{ "or", {} },
    .{ "if", {} },     .{ "else", {} },    .{ "return", {} }, .{ "fn", {} },        .{ "pub", {} },
    .{ "const", {} },  .{ "var", {} },     .{ "let", {} },    .{ "for", {} },       .{ "while", {} },
    .{ "switch", {} }, .{ "case", {} },    .{ "break", {} },  .{ "continue", {} },  .{ "struct", {} },
    .{ "enum", {} },   .{ "union", {} },   .{ "error", {} },  .{ "try", {} },       .{ "catch", {} },
    .{ "is", {} },     .{ "in", {} },      .{ "to", {} },     .{ "of", {} },        .{ "it", {} },
    .{ "on", {} },     .{ "with", {} },    .{ "by", {} },     .{ "as", {} },        .{ "at", {} },
    .{ "be", {} },     .{ "this", {} },    .{ "that", {} },   .{ "from", {} },      .{ "import", {} },
    .{ "export", {} }, .{ "default", {} }, .{ "class", {} },  .{ "interface", {} }, .{ "extends", {} },
});

pub const dim: usize = 1024;

pub fn embedInto(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    if (out.len < dim) return error.BufferTooSmall;
    var fixed: [dim]f32 = undefined;
    try embed(allocator, text, &fixed);
    @memcpy(out[0..dim], &fixed);
}

pub fn embed(allocator: std.mem.Allocator, text: []const u8, out: *[dim]f32) !void {
    @memset(out, 0);

    var unique = std.AutoHashMap(u64, void).init(allocator);
    defer unique.deinit();

    try tokenizeIntoVector(text, &unique, out);
    normalize(out);
}

pub fn cosine(a: *const [dim]f32, b: *const [dim]f32) f32 {
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (0..dim) |i| {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    const denom = @sqrt(na * nb);
    if (denom == 0) return 0;
    return dot / denom;
}

fn normalize(vec: *[dim]f32) void {
    var sum: f32 = 0;
    for (vec.*) |v| sum += v * v;
    const norm = @sqrt(sum);
    if (norm == 0) return;
    for (0..dim) |i| vec[i] /= norm;
}

fn tokenizeIntoVector(
    text: []const u8,
    unique: *std.AutoHashMap(u64, void),
    out: *[dim]f32,
) !void {
    var start: usize = 0;
    while (start <= text.len) {
        const end = blk: {
            var i = start;
            while (i < text.len and !isBoundary(text[i])) : (i += 1) {}
            break :blk i;
        };
        if (end > start) {
            const raw = text[start..end];
            if (raw.len >= 2) {
                try addLowerToken(unique, out, raw);
                var segment_start: usize = 0;
                for (raw, 0..) |char, index| {
                    if (index > segment_start and std.ascii.isUpper(char) and std.ascii.isLower(raw[index - 1])) {
                        if (index - segment_start >= 2) try addLowerToken(unique, out, raw[segment_start..index]);
                        segment_start = index;
                    }
                }
                if (segment_start > 0 and raw.len - segment_start >= 2) {
                    try addLowerToken(unique, out, raw[segment_start..]);
                }
            }
        }
        if (end >= text.len) break;
        start = end + 1;
        while (start < text.len and isBoundary(text[start])) : (start += 1) {}
    }
}

fn addLowerToken(
    unique: *std.AutoHashMap(u64, void),
    out: *[dim]f32,
    raw: []const u8,
) !void {
    if (raw.len < 2) return;

    var stack_buf: [256]u8 = undefined;
    if (raw.len <= stack_buf.len) {
        const lower = stack_buf[0..raw.len];
        for (raw, 0..) |char, index| lower[index] = std.ascii.toLower(char);
        if (stop_words.has(lower)) return;

        const token_hash = std.hash.Wyhash.hash(0, lower);
        const gop = try unique.getOrPut(token_hash);
        if (gop.found_existing) return;
        addHashedToken(out, token_hash);
        if (lower.len > 6) addHashedToken(out, std.hash.Wyhash.hash(1, lower[0..6]));
        return;
    }

    var hasher = std.hash.Wyhash.init(0);
    var stem_buf: [6]u8 = undefined;
    for (raw, 0..) |char, index| {
        const lower_char = std.ascii.toLower(char);
        var one: [1]u8 = .{lower_char};
        hasher.update(&one);
        if (index < stem_buf.len) stem_buf[index] = lower_char;
    }
    const token_hash = hasher.final();
    const gop = try unique.getOrPut(token_hash);
    if (gop.found_existing) return;
    addHashedToken(out, token_hash);
    if (raw.len > 6) addHashedToken(out, std.hash.Wyhash.hash(1, &stem_buf));
}

fn addHashedToken(out: *[dim]f32, h: u64) void {
    const bucket: usize = @intCast(h % dim);
    const sign: f32 = if ((h >> 32) & 1 == 1) 1.0 else -1.0;
    out[bucket] += sign;
}

fn isBoundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or !std.ascii.isAlphanumeric(c);
}

test "similar texts score higher than unrelated" {
    const allocator = std.testing.allocator;
    var auth: [dim]f32 = undefined;
    var login: [dim]f32 = undefined;
    var unrelated: [dim]f32 = undefined;
    try embed(allocator, "authenticate user session middleware", &auth);
    try embed(allocator, "authentication login handler", &login);
    try embed(allocator, "render sidebar tabs layout", &unrelated);
    try std.testing.expect(cosine(&auth, &login) > cosine(&auth, &unrelated));
}

test "camelCase symbols contribute searchable subtokens" {
    const allocator = std.testing.allocator;
    var symbol: [dim]f32 = undefined;
    var query: [dim]f32 = undefined;
    var unrelated: [dim]f32 = undefined;
    try embed(allocator, "pub fn authenticateUserSession", &symbol);
    try embed(allocator, "user authentication session", &query);
    try embed(allocator, "renderer color layout", &unrelated);
    try std.testing.expect(cosine(&symbol, &query) > cosine(&symbol, &unrelated));
}

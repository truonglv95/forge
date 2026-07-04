const std = @import("std");

pub const dim: usize = 128;

pub fn embedInto(allocator: std.mem.Allocator, text: []const u8, out: []f32) !void {
    if (out.len < dim) return error.BufferTooSmall;
    var fixed: [dim]f32 = undefined;
    try embed(allocator, text, &fixed);
    @memcpy(out[0..dim], &fixed);
}

pub fn embed(allocator: std.mem.Allocator, text: []const u8, out: *[dim]f32) !void {
    @memset(out, 0);
    var tokens: std.ArrayList([]const u8) = .empty;
    defer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit(allocator);
    }
    try tokenize(allocator, text, &tokens);

    for (tokens.items) |token| {
        const h = std.hash.Wyhash.hash(0, token);
        const bucket = h % dim;
        const sign: f32 = if ((h >> 32) & 1 == 1) 1.0 else -1.0;
        out[bucket] += sign;
    }

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

fn tokenize(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
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
                const lower = try allocator.dupe(u8, raw);
                for (lower) |*c| c.* = std.ascii.toLower(c.*);
                try out.append(allocator, lower);
            }
        }
        if (end >= text.len) break;
        start = end + 1;
        while (start < text.len and isBoundary(text[start])) : (start += 1) {}
    }
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

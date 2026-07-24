//! @mention parser for forge chat REPL (RFC-0017).
//!
//! Parses @file, @symbol, @web, @docs, @spec, @recent, @git:diff, @git:status
//! mentions from user input and resolves them to context blocks.

const std = @import("std");

/// A parsed @mention from chat input.
pub const Mention = union(enum) {
    file: struct {
        path: []const u8,
        line_range: ?LineRange = null,
    },
    symbol: []const u8,
    web: []const u8,
    docs: []const u8,
    spec: []const u8,
    recent,
    git_diff,
    git_status,
};

pub const LineRange = struct {
    start: u32,
    end: u32,
};

pub const ParseError = error{
    OutOfMemory,
    InvalidMention,
};

/// Parse all @mentions from input. Returns owned slice of Mention.
/// Mentions are whitespace-delimited tokens starting with @.
pub fn parseMentions(allocator: std.mem.Allocator, input: []const u8) ParseError![]Mention {
    var mentions = std.ArrayList(Mention).empty;
    defer mentions.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, input, " \t\n");
    while (iter.next()) |token| {
        if (!std.mem.startsWith(u8, token, "@")) continue;
        if (token.len < 2) continue; // just "@" alone

        const body = token[1..];

        if (std.mem.startsWith(u8, body, "file:")) {
            const rest = body[5..];
            // Parse path:line-range
            if (rest.len == 0) continue;
            if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
                const path = rest[0..colon];
                const range_str = rest[colon + 1 ..];
                if (path.len == 0) continue;
                const range = parseLineRange(range_str) catch null;
                try mentions.append(allocator, .{ .file = .{
                    .path = path,
                    .line_range = range,
                } });
            } else {
                try mentions.append(allocator, .{ .file = .{
                    .path = rest,
                    .line_range = null,
                } });
            }
        } else if (std.mem.startsWith(u8, body, "symbol:")) {
            const sym = body[7..];
            if (sym.len == 0) continue;
            try mentions.append(allocator, .{ .symbol = sym });
        } else if (std.mem.startsWith(u8, body, "web:")) {
            const q = body[4..];
            if (q.len == 0) continue;
            try mentions.append(allocator, .{ .web = q });
        } else if (std.mem.startsWith(u8, body, "docs:")) {
            const d = body[5..];
            if (d.len == 0) continue;
            try mentions.append(allocator, .{ .docs = d });
        } else if (std.mem.startsWith(u8, body, "spec:")) {
            const s = body[5..];
            if (s.len == 0) continue;
            try mentions.append(allocator, .{ .spec = s });
        } else if (std.mem.eql(u8, body, "recent")) {
            try mentions.append(allocator, .recent);
        } else if (std.mem.eql(u8, body, "git:diff")) {
            try mentions.append(allocator, .git_diff);
        } else if (std.mem.eql(u8, body, "git:status")) {
            try mentions.append(allocator, .git_status);
        }
        // Unknown @mentions are silently ignored (treated as plain text).
    }

    return mentions.toOwnedSlice(allocator);
}

fn parseLineRange(s: []const u8) !LineRange {
    // Formats: "10", "10-20", "10-"
    if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
        const start_str = s[0..dash];
        const end_str = s[dash + 1 ..];
        const start = try std.fmt.parseInt(u32, start_str, 10);
        const end = if (end_str.len == 0) start else try std.fmt.parseInt(u32, end_str, 10);
        return .{ .start = start, .end = end };
    }
    const n = try std.fmt.parseInt(u32, s, 10);
    return .{ .start = n, .end = n };
}

/// Strip @mention tokens from input, returning the remaining text.
/// Useful for showing the user what their intent looks like after mentions
/// are extracted into context.
pub fn stripMentions(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, input, " \t\n");
    var first = true;
    while (iter.next()) |token| {
        if (std.mem.startsWith(u8, token, "@") and token.len > 1) {
            // Check if it's a recognized mention
            const body = token[1..];
            const is_mention = std.mem.startsWith(u8, body, "file:") or
                std.mem.startsWith(u8, body, "symbol:") or
                std.mem.startsWith(u8, body, "web:") or
                std.mem.startsWith(u8, body, "docs:") or
                std.mem.startsWith(u8, body, "spec:") or
                std.mem.eql(u8, body, "recent") or
                std.mem.eql(u8, body, "git:diff") or
                std.mem.eql(u8, body, "git:status");
            if (is_mention) continue;
        }
        if (!first) try buf.append(allocator, ' ');
        first = false;
        try buf.appendSlice(allocator, token);
    }
    return buf.toOwnedSlice(allocator);
}

test "parseMentions extracts @file" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "explain @file:src/main.zig please");
    defer allocator.free(mentions);
    try std.testing.expectEqual(@as(usize, 1), mentions.len);
    try std.testing.expectEqualStrings("src/main.zig", mentions[0].file.path);
    try std.testing.expect(mentions[0].file.line_range == null);
}

test "parseMentions extracts @file with line range" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "@file:src/main.zig:10-20");
    defer allocator.free(mentions);
    try std.testing.expectEqual(@as(usize, 1), mentions.len);
    try std.testing.expectEqualStrings("src/main.zig", mentions[0].file.path);
    try std.testing.expect(mentions[0].file.line_range != null);
    try std.testing.expectEqual(@as(u32, 10), mentions[0].file.line_range.?.start);
    try std.testing.expectEqual(@as(u32, 20), mentions[0].file.line_range.?.end);
}

test "parseMentions extracts @symbol" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "what does @symbol:calculateTotal do");
    defer allocator.free(mentions);
    try std.testing.expectEqual(@as(usize, 1), mentions.len);
    try std.testing.expectEqualStrings("calculateTotal", mentions[0].symbol);
}

test "parseMentions extracts @web" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "search @web:rust-async-patterns please");
    defer allocator.free(mentions);
    try std.testing.expectEqual(@as(usize, 1), mentions.len);
    try std.testing.expectEqualStrings("rust-async-patterns", mentions[0].web);
}

test "parseMentions extracts @recent" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "explain @recent");
    defer allocator.free(mentions);
    try std.testing.expectEqual(@as(usize, 1), mentions.len);
    try std.testing.expectEqual(@as(std.meta.Tag(Mention), .recent), mentions[0]);
}

test "parseMentions extracts @git:diff" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "review @git:diff");
    defer allocator.free(mentions);
    try std.testing.expectEqual(@as(usize, 1), mentions.len);
    try std.testing.expectEqual(@as(std.meta.Tag(Mention), .git_diff), mentions[0]);
}

test "parseMentions extracts multiple mentions" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "@file:a.zig @file:b.zig @symbol:foo @recent");
    defer allocator.free(mentions);
    try std.testing.expectEqual(@as(usize, 4), mentions.len);
}

test "parseMentions ignores plain @ text" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "email me @test@example.com");
    defer allocator.free(mentions);
    // @test@example.com - @test is not a recognized mention prefix
    try std.testing.expectEqual(@as(usize, 0), mentions.len);
}

test "parseMentions ignores lone @" {
    const allocator = std.testing.allocator;
    const mentions = try parseMentions(allocator, "@ alone");
    defer allocator.free(mentions);
    try std.testing.expectEqual(@as(usize, 0), mentions.len);
}

test "parseLineRange single line" {
    const r = try parseLineRange("42");
    try std.testing.expectEqual(@as(u32, 42), r.start);
    try std.testing.expectEqual(@as(u32, 42), r.end);
}

test "parseLineRange range" {
    const r = try parseLineRange("10-20");
    try std.testing.expectEqual(@as(u32, 10), r.start);
    try std.testing.expectEqual(@as(u32, 20), r.end);
}

test "parseLineRange open-ended range" {
    const r = try parseLineRange("10-");
    try std.testing.expectEqual(@as(u32, 10), r.start);
    try std.testing.expectEqual(@as(u32, 10), r.end);
}

test "stripMentions removes recognized mentions" {
    const allocator = std.testing.allocator;
    const result = try stripMentions(allocator, "explain @file:src/main.zig and @symbol:foo");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("explain and", result);
}

test "stripMentions keeps unrecognized @ tokens" {
    const allocator = std.testing.allocator;
    const result = try stripMentions(allocator, "email @user@example.com");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("email @user@example.com", result);
}

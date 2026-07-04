const std = @import("std");
const workspace = @import("forge-workspace");

pub const max_urls: usize = 4;
pub const max_page_bytes: usize = 32 * 1024;
pub const cache_dir = ".forge/cache/web/v1";

pub const FetchOptions = struct {
    max_bytes: usize = max_page_bytes,
    use_cache: bool = true,
};

pub const FetchedPage = struct {
    url: []const u8,
    text: []const u8,
    from_cache: bool,
};

pub const FetchError = error{
    UnsupportedScheme,
    BlockedHost,
    InvalidUrl,
    NetworkError,
    ResponseTooLarge,
    EmptyResponse,
};

pub fn freePage(allocator: std.mem.Allocator, page: FetchedPage) void {
    allocator.free(page.url);
    allocator.free(page.text);
}

pub fn collectTargetUrls(
    allocator: std.mem.Allocator,
    include_web: bool,
    scoped_urls: []const []const u8,
    intent: ?[]const u8,
    limit: usize,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |url| allocator.free(url);
        out.deinit(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var seen = std.StringHashMap(void).init(arena.allocator());

    for (scoped_urls) |url| {
        if (out.items.len >= limit) break;
        if (seen.contains(url)) continue;
        try seen.put(url, {});
        try out.append(allocator, try allocator.dupe(u8, url));
    }

    if (include_web) {
        if (intent) |text| {
            const extracted = try extractUrlsFromText(allocator, text, limit);
            defer freeUrlList(allocator, extracted);
            for (extracted) |url| {
                if (out.items.len >= limit) break;
                if (seen.contains(url)) continue;
                try seen.put(url, {});
                try out.append(allocator, try allocator.dupe(u8, url));
            }
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeUrlList(allocator: std.mem.Allocator, urls: []const []const u8) void {
    for (urls) |url| allocator.free(url);
    allocator.free(urls);
}

pub fn fetchUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: ?workspace.WorkspaceRoot,
    url: []const u8,
    options: FetchOptions,
) FetchError!FetchedPage {
    try validateUrl(url);

    if (options.use_cache) {
        if (root) |ws_root| {
            if (readCache(allocator, io, ws_root, url)) |cached| {
                const url_owned = allocator.dupe(u8, url) catch return error.NetworkError;
                return .{
                    .url = url_owned,
                    .text = cached,
                    .from_cache = true,
                };
            }
        }
    }

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_alloc.writer,
    }) catch return error.NetworkError;

    if (result.status != .ok) return error.NetworkError;

    const body = response_alloc.writer.buffer[0..response_alloc.writer.end];
    if (body.len == 0) return error.EmptyResponse;
    if (body.len > options.max_bytes * 4) return error.ResponseTooLarge;

    const text = htmlToText(allocator, body, options.max_bytes) catch return error.NetworkError;
    if (text.len == 0) return error.EmptyResponse;

    if (options.use_cache) {
        if (root) |ws_root| {
            writeCache(allocator, io, ws_root, url, text) catch {};
        }
    }

    const url_owned = allocator.dupe(u8, url) catch {
        allocator.free(text);
        return error.NetworkError;
    };

    return .{
        .url = url_owned,
        .text = text,
        .from_cache = false,
    };
}

pub fn formatWebBlock(allocator: std.mem.Allocator, pages: []const FetchedPage) !?[]const u8 {
    if (pages.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Web documentation\n\n");

    for (pages) |page| {
        const source = if (page.from_cache) "cached" else "fetched";
        const section = try std.fmt.allocPrint(allocator, "## {s} ({s})\n```\n{s}\n```\n\n", .{
            page.url,
            source,
            page.text,
        });
        defer allocator.free(section);
        try out.appendSlice(allocator, section);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn extractUrlsFromText(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |url| allocator.free(url);
        out.deinit(allocator);
    }

    const prefixes = [_][]const u8{ "https://", "http://" };
    var index: usize = 0;
    while (index < text.len and out.items.len < limit) {
        var found_at: ?usize = null;
        var prefix_len: usize = 0;
        for (prefixes) |prefix| {
            if (std.mem.indexOfPos(u8, text, index, prefix)) |pos| {
                if (found_at == null or pos < found_at.?) {
                    found_at = pos;
                    prefix_len = prefix.len;
                }
            }
        }
        const start = found_at orelse break;
        var end = start + prefix_len;
        while (end < text.len) {
            const c = text[end];
            if (std.ascii.isWhitespace(c) or c == ')' or c == ']' or c == '>' or c == '"') break;
            end += 1;
        }
        const raw = std.mem.trim(u8, text[start..end], ".,;'");
        if (raw.len > prefix_len) {
            const owned = try allocator.dupe(u8, raw);
            validateUrl(owned) catch {
                allocator.free(owned);
                index = end;
                continue;
            };
            try out.append(allocator, owned);
        }
        index = end;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn validateUrl(url: []const u8) FetchError!void {
    var scheme_end: usize = undefined;
    if (std.mem.startsWith(u8, url, "https://")) {
        scheme_end = 8;
    } else if (std.mem.startsWith(u8, url, "http://")) {
        scheme_end = 7;
    } else {
        return error.UnsupportedScheme;
    }

    if (scheme_end >= url.len) return error.InvalidUrl;

    const host_end = std.mem.indexOfPos(u8, url, scheme_end, "/") orelse url.len;
    const host_port = url[scheme_end..host_end];
    if (host_port.len == 0) return error.InvalidUrl;

    const host_only = if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| host_port[0..colon] else host_port;
    if (isBlockedHost(host_only)) return error.BlockedHost;
}

pub fn htmlToText(allocator: std.mem.Allocator, html: []const u8, max_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_tag = false;
    var prev_space = false;
    for (html) |byte| {
        if (out.items.len >= max_bytes) break;
        switch (byte) {
            '<' => in_tag = true,
            '>' => in_tag = false,
            '&' => {},
            else => {
                if (in_tag) continue;
                if (std.ascii.isWhitespace(byte)) {
                    if (!prev_space and out.items.len > 0) try out.append(allocator, ' ');
                    prev_space = true;
                } else {
                    try out.append(allocator, byte);
                    prev_space = false;
                }
            },
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn isBlockedHost(host: []const u8) bool {
    var lower: [256]u8 = undefined;
    if (host.len > lower.len) return true;
    for (host, 0..) |c, i| lower[i] = std.ascii.toLower(c);

    if (std.mem.eql(u8, lower[0..host.len], "localhost")) return true;
    if (host.len >= 4 and std.mem.eql(u8, lower[0..4], "127.")) return true;
    if (host.len >= 2 and std.mem.eql(u8, lower[0..2], "0.")) return true;
    if (host.len >= 3 and std.mem.eql(u8, lower[0..3], "10.")) return true;
    if (host.len >= 8 and std.mem.eql(u8, lower[0..8], "192.168.")) return true;
    if (host.len >= 8 and std.mem.eql(u8, lower[0..8], "169.254.")) return true;
    if (std.mem.startsWith(u8, host, "[::1]")) return true;
    return false;
}

fn cacheKey(url: []const u8) u64 {
    return std.hash.Wyhash.hash(0, url);
}

fn cacheRelPathBuf(url: []const u8, out: *[64]u8) []const u8 {
    return std.fmt.bufPrint(out, "{s}/{x}.txt", .{ cache_dir, cacheKey(url) }) catch cache_dir;
}

fn writeCache(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, url: []const u8, text: []const u8) !void {
    try root.dir.createDirPath(io, ".forge");
    try root.dir.createDirPath(io, ".forge/cache");
    try root.dir.createDirPath(io, cache_dir);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "# URL: ");
    try body.appendSlice(allocator, url);
    try body.append(allocator, '\n');
    try body.appendSlice(allocator, text);

    var path_buf: [64]u8 = undefined;
    const rel = cacheRelPathBuf(url, &path_buf);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse(rel), body.items);
}

fn readCache(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, url: []const u8) ?[]u8 {
    var path_buf: [64]u8 = undefined;
    const rel = cacheRelPathBuf(url, &path_buf);
    const wp = workspace.WorkspacePath.parse(rel) catch return null;
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return null;
    defer snap.deinit();
    if (snap.content.len == 0) return null;

    const marker = "# URL: ";
    if (std.mem.startsWith(u8, snap.content, marker)) {
        if (std.mem.indexOfScalar(u8, snap.content, '\n')) |nl| {
            const body = std.mem.trim(u8, snap.content[nl + 1 ..], " \t\r\n");
            if (body.len == 0) return null;
            return allocator.dupe(u8, body) catch null;
        }
    }
    return allocator.dupe(u8, snap.content) catch null;
}

test "htmlToText strips tags" {
    const text = try htmlToText(std.testing.allocator, "<html><body><h1>Title</h1><p>Hello</p></body></html>", 1024);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<") == null);
}

test "extractUrlsFromText finds https links" {
    const allocator = std.testing.allocator;
    const urls = try extractUrlsFromText(allocator, "See https://ziglang.org/documentation/master/ for details", 4);
    defer freeUrlList(allocator, urls);
    try std.testing.expectEqual(@as(usize, 1), urls.len);
    try std.testing.expectEqualStrings("https://ziglang.org/documentation/master/", urls[0]);
}

test "validateUrl blocks localhost" {
    try std.testing.expectError(error.BlockedHost, validateUrl("http://127.0.0.1/docs"));
    try validateUrl("https://ziglang.org/documentation/");
}

test "formatWebBlock renders pages" {
    const allocator = std.testing.allocator;
    const pages = [_]FetchedPage{
        .{ .url = "https://example.com", .text = "Example docs", .from_cache = false },
    };
    const block = try formatWebBlock(allocator, &pages);
    defer allocator.free(block.?);
    try std.testing.expect(std.mem.indexOf(u8, block.?, "Example docs") != null);
}

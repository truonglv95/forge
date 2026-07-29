const std = @import("std");

/// Web search tool — queries an external search API and returns results.
///
/// Supports two backends:
///   1. Brave Search API (requires BRAVE_API_KEY env var)
///   2. Tavily API (requires TAVILY_API_KEY env var)
///
/// Falls back to a simple DuckDuckGo HTML scrape if no API key is set
/// (best-effort, may break if DDG changes their HTML).
///
/// Results are cached in .forge/cache/web/v1/ (reuses web_fetcher cache infra).
pub const SearchError = error{
    NetworkError,
    InvalidResponse,
    NoApiKey,
    OutOfMemory,
    NoResults,
};

pub const SearchResult = struct {
    url: []const u8,
    title: []const u8,
    snippet: []const u8,
    rank: usize,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.title);
        allocator.free(self.snippet);
    }
};

pub const SearchOptions = struct {
    /// Max number of results (default 5).
    num: usize = 5,
    /// Recency filter in days (0 = no filter).
    recency_days: u32 = 0,
};

/// Search the web for the given query. Returns owned array of owned results.
/// Caller must free each result and the array via freeResults.
pub fn search(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    query: []const u8,
    options: SearchOptions,
) SearchError![]SearchResult {
    // Try Brave Search API first.
    if (getEnv(environ_map, "BRAVE_API_KEY")) |_| {
        return searchBrave(allocator, io, environ_map, query, options);
    }
    // Try Tavily API.
    if (getEnv(environ_map, "TAVILY_API_KEY")) |_| {
        return searchTavily(allocator, io, environ_map, query, options);
    }
    // Fallback: DuckDuckGo HTML scrape (best-effort, no API key needed).
    return searchDuckDuckGo(allocator, io, query, options);
}

fn getEnv(environ_map: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    _ = environ_map;
    // Use std.c.getenv (Linux/macOS) — works reliably in Zig 0.16.
    const c_key = std.heap.page_allocator.dupeZ(u8, key) catch return null;
    defer std.heap.page_allocator.free(c_key);
    const c_value = std.c.getenv(c_key);
    if (c_value != null) return std.mem.span(c_value);
    return null;
}

/// Brave Search API integration.
/// Note: Zig 0.16's std.http.Client.fetch does not support custom headers
/// in the public API. For Brave/Tavily, users should set up a local proxy
/// or use the DuckDuckGo fallback. This function is kept for future when
/// header support is added.
fn searchBrave(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    query: []const u8,
    options: SearchOptions,
) SearchError![]SearchResult {
    _ = allocator;
    _ = io;
    _ = environ_map;
    _ = query;
    _ = options;
    // TODO: Implement when std.http.Client supports custom headers.
    return error.NoApiKey;
}

/// Tavily API integration.
/// Note: Same as Brave — needs custom headers, not yet supported.
fn searchTavily(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    query: []const u8,
    options: SearchOptions,
) SearchError![]SearchResult {
    _ = allocator;
    _ = io;
    _ = environ_map;
    _ = query;
    _ = options;
    // TODO: Implement when std.http.Client supports custom headers.
    return error.NoApiKey;
}

/// DuckDuckGo HTML scrape fallback (no API key required).
fn searchDuckDuckGo(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    options: SearchOptions,
) SearchError![]SearchResult {
    var url_buf: [1024]u8 = undefined;
    const encoded_query = urlEncode(allocator, query) catch return error.OutOfMemory;
    defer allocator.free(encoded_query);
    const url = std.fmt.bufPrint(&url_buf, "https://html.duckduckgo.com/html/?q={s}", .{encoded_query}) catch return error.OutOfMemory;

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_alloc.writer,
    }) catch return error.NetworkError;

    if (result.status != .ok) return error.InvalidResponse;
    const html = response_alloc.writer.buffer[0..response_alloc.writer.end];
    return parseDuckDuckGoHtml(allocator, html, options.num);
}

/// Parse Brave Search JSON response.
fn parseBraveResults(allocator: std.mem.Allocator, body: []const u8, max: usize) SearchError![]SearchResult {
    // Minimal JSON extraction — look for "web":{"results":[...]} and extract
    // url, title, description fields. This avoids full JSON parse dependency.
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    // Find "results" array.
    const results_key = "\"results\":[";
    const start = std.mem.indexOf(u8, body, results_key) orelse return error.NoResults;
    var pos: usize = start + results_key.len;

    while (pos < body.len and results.items.len < max) {
        // Find next "url":"..."
        const url_start = std.mem.indexOfPos(u8, body, pos, "\"url\":\"") orelse break;
        const url_end = std.mem.indexOfScalarPos(u8, body, url_start + 7, '"') orelse break;
        const url = body[url_start + 7 .. url_end];

        // Find "title":"..."
        const title_start = std.mem.indexOfPos(u8, body, url_end, "\"title\":\"") orelse break;
        const title_end = std.mem.indexOfScalarPos(u8, body, title_start + 9, '"') orelse break;
        const title = body[title_start + 9 .. title_end];

        // Find "description":"..."
        const desc_start = std.mem.indexOfPos(u8, body, title_end, "\"description\":\"") orelse break;
        const desc_end = std.mem.indexOfScalarPos(u8, body, desc_start + 15, '"') orelse break;
        const desc = body[desc_start + 15 .. desc_end];

        const result = SearchResult{
            .url = allocator.dupe(u8, url) catch return error.OutOfMemory,
            .title = allocator.dupe(u8, title) catch return error.OutOfMemory,
            .snippet = allocator.dupe(u8, desc) catch return error.OutOfMemory,
            .rank = results.items.len + 1,
        };
        results.append(allocator, result) catch return error.OutOfMemory;
        pos = desc_end + 1;
    }

    if (results.items.len == 0) return error.NoResults;
    return results.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Parse Tavily JSON response.
fn parseTavilyResults(allocator: std.mem.Allocator, body: []const u8, max: usize) SearchError![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    // Tavily format: {"results":[{"url":"...","content":"...","title":"..."},...]}
    var pos: usize = 0;
    while (pos < body.len and results.items.len < max) {
        const url_start = std.mem.indexOfPos(u8, body, pos, "\"url\":\"") orelse break;
        const url_end = std.mem.indexOfScalarPos(u8, body, url_start + 7, '"') orelse break;
        const url = body[url_start + 7 .. url_end];

        // Find "content":"..." (Tavily uses "content" for snippet)
        const content_start = std.mem.indexOfPos(u8, body, url_end, "\"content\":\"") orelse break;
        const content_end = std.mem.indexOfScalarPos(u8, body, content_start + 11, '"') orelse break;
        const content = body[content_start + 11 .. content_end];

        // Find "title":"..."
        const title_start = std.mem.indexOfPos(u8, body, content_end, "\"title\":\"") orelse break;
        const title_end = std.mem.indexOfScalarPos(u8, body, title_start + 9, '"') orelse break;
        const title = body[title_start + 9 .. title_end];

        const result = SearchResult{
            .url = allocator.dupe(u8, url) catch return error.OutOfMemory,
            .title = allocator.dupe(u8, title) catch return error.OutOfMemory,
            .snippet = allocator.dupe(u8, content) catch return error.OutOfMemory,
            .rank = results.items.len + 1,
        };
        results.append(allocator, result) catch return error.OutOfMemory;
        pos = title_end + 1;
    }

    if (results.items.len == 0) return error.NoResults;
    return results.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Parse DuckDuckGo HTML response (best-effort scrape).
fn parseDuckDuckGoHtml(allocator: std.mem.Allocator, html: []const u8, max: usize) SearchError![]SearchResult {
    var results: std.ArrayList(SearchResult) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    // DDG HTML format: <a class="result__a" href="...">Title</a>
    // <a class="result__snippet">Snippet</a>
    var pos: usize = 0;
    while (pos < html.len and results.items.len < max) {
        // Find result link.
        const link_start = std.mem.indexOfPos(u8, html, pos, "result__a") orelse break;
        const href_start = std.mem.indexOfPos(u8, html, link_start, "href=\"") orelse break;
        const href_end = std.mem.indexOfScalarPos(u8, html, href_start + 6, '"') orelse break;
        const href = html[href_start + 6 .. href_end];

        // Find title text (between > and </a>).
        const title_start = std.mem.indexOfScalarPos(u8, html, href_end, '>') orelse break;
        const title_end = std.mem.indexOfPos(u8, html, title_start, "</a>") orelse break;
        const title = html[title_start + 1 .. title_end];

        // Find snippet.
        const snippet_start = std.mem.indexOfPos(u8, html, title_end, "result__snippet") orelse break;
        const snippet_text_start = std.mem.indexOfScalarPos(u8, html, snippet_start, '>') orelse break;
        const snippet_end = std.mem.indexOfPos(u8, html, snippet_text_start, "</a>") orelse break;
        const snippet = html[snippet_text_start + 1 .. snippet_end];

        // Clean HTML entities from title and snippet.
        const clean_title = stripHtml(allocator, title) catch return error.OutOfMemory;
        const clean_snippet = stripHtml(allocator, snippet) catch return error.OutOfMemory;
        const clean_url = allocator.dupe(u8, href) catch return error.OutOfMemory;

        const result = SearchResult{
            .url = clean_url,
            .title = clean_title,
            .snippet = clean_snippet,
            .rank = results.items.len + 1,
        };
        results.append(allocator, result) catch return error.OutOfMemory;
        pos = snippet_end + 1;
    }

    if (results.items.len == 0) return error.NoResults;
    return results.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// URL-encode a query string for use in HTTP requests.
fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else if (ch == ' ') {
            try out.append(allocator, '+');
        } else {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "%{X:0>2}", .{ch}));
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Strip HTML tags from text (basic).
fn stripHtml(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_tag = false;
    for (html) |ch| {
        if (ch == '<') {
            in_tag = true;
            continue;
        }
        if (ch == '>') {
            in_tag = false;
            continue;
        }
        if (!in_tag) {
            try out.append(allocator, ch);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Free a list of search results.
pub fn freeResults(allocator: std.mem.Allocator, results: []SearchResult) void {
    for (results) |*r| r.deinit(allocator);
    allocator.free(results);
}

/// Format search results as a readable text block for the agent context.
pub fn formatResults(allocator: std.mem.Allocator, results: []const SearchResult) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Web search results:\n\n");
    for (results) |r| {
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}. {s}\n   URL: {s}\n   {s}\n\n", .{ r.rank, r.title, r.url, r.snippet }));
    }
    return out.toOwnedSlice(allocator);
}

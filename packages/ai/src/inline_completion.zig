//! Inline code completion — AI-powered multi-line FIM (Fill-In-the-Middle)
//! completion engine with caching, debounce, and codebase-aware context.
//!
//! This is Forge's equivalent of Cursor Tab: proactive multi-line completions
//! that use RAG-retrieved code context for higher accuracy.
const std = @import("std");
const workspace = @import("forge-workspace");
const provider = @import("provider.zig");
const provider_factory = @import("provider_factory.zig");
const context = @import("context.zig");
const kernel = @import("forge-kernel");

pub const CompletionError = error{
    ProviderFailed,
    Cancelled,
    NoCompletion,
    OutOfMemory,
} || provider.ProviderError;

pub const CompletionRequest = struct {
    prefix: []const u8,
    suffix: []const u8,
    file_path: []const u8,
    language: ?[]const u8 = null,
    recent_lines: []const []const u8 = &.{},
    file_header: ?[]const u8 = null,
    /// RAG-retrieved similar code chunks for context-aware completion.
    similar_chunks: []const []const u8 = &.{},
    /// Symbols from LSP document symbols for the current file.
    file_symbols: []const []const u8 = &.{},
    max_tokens: u32 = 256, // Increased from 64 for multi-line
    /// Timeout in milliseconds. Real LLM providers (Gemini, Claude) can
    /// take 5-10 seconds for multi-line completions, so we default to
    /// 10000ms. The fake provider returns instantly so tests are unaffected.
    timeout_ms: u64 = 10000,
    /// Whether this is a proactive (auto-triggered) completion.
    proactive: bool = false,
};

pub const CompletionResult = struct {
    text: []const u8,
    is_multiline: bool,
    confidence: f32 = 0,
    /// Number of lines in the completion.
    line_count: usize = 1,

    pub fn deinit(self: *CompletionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

/// Cache key for completion results — keyed by (file, row, col, buffer_hash).
const CacheKey = struct {
    file_hash: u64,
    row: u32,
    col: u32,
    buffer_revision: u64,

    pub fn hash(self: CacheKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.file_hash));
        h.update(std.mem.asBytes(&self.row));
        h.update(std.mem.asBytes(&self.col));
        h.update(std.mem.asBytes(&self.buffer_revision));
        return h.final();
    }
};

/// Completion cache — avoids redundant LLM calls for the same cursor position.
/// Entries are invalidated when the buffer revision changes.
pub const CompletionCache = struct {
    allocator: std.mem.Allocator,
    entries: [64]?Entry = [_]?Entry{null} ** 64,
    hits: u64 = 0,
    misses: u64 = 0,

    const Entry = struct {
        key_hash: u64,
        text: []const u8,
        is_multiline: bool,
        confidence: f32,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator) CompletionCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CompletionCache) void {
        for (&self.entries) |*e| {
            if (e.*) |entry| {
                self.allocator.free(entry.text);
                e.* = null;
            }
        }
    }

    pub fn get(self: *CompletionCache, key: CacheKey) ?CompletionResult {
        const h = key.hash();
        const slot = h % self.entries.len;
        if (self.entries[slot]) |entry| {
            if (entry.key_hash == h) {
                self.hits += 1;
                const text = self.allocator.dupe(u8, entry.text) catch return null;
                return .{
                    .text = text,
                    .is_multiline = entry.is_multiline,
                    .confidence = entry.confidence,
                };
            }
        }
        self.misses += 1;
        return null;
    }

    pub fn put(self: *CompletionCache, key: CacheKey, result: CompletionResult) void {
        const h = key.hash();
        const slot = h % self.entries.len;
        if (self.entries[slot]) |old| {
            self.allocator.free(old.text);
        }
        const text = self.allocator.dupe(u8, result.text) catch return;
        self.entries[slot] = .{
            .key_hash = h,
            .text = text,
            .is_multiline = result.is_multiline,
            .confidence = result.confidence,
            .timestamp = 0,
        };
    }

    pub fn invalidate(self: *CompletionCache) void {
        for (&self.entries) |*e| {
            if (e.*) |entry| {
                self.allocator.free(entry.text);
                e.* = null;
            }
        }
    }
};

/// Debounce state — prevents excessive LLM calls during rapid typing.
pub const DebounceState = struct {
    last_request_time: f64 = 0,
    last_row: u32 = 0,
    last_col: u32 = 0,
    /// Minimum time between completion requests (in seconds).
    min_delay: f64 = 0.35, // 350ms

    /// Returns true if a new completion request should be sent.
    pub fn shouldRequest(self: *DebounceState, current_time: f64, row: u32, col: u32) bool {
        // If cursor moved to a different line, allow immediately.
        if (row != self.last_row) {
            self.last_request_time = current_time;
            self.last_row = row;
            self.last_col = col;
            return true;
        }
        // If same position, don't re-request.
        if (col == self.last_col) return false;
        // Check debounce timer.
        if (current_time - self.last_request_time < self.min_delay) {
            self.last_col = col;
            return false;
        }
        self.last_request_time = current_time;
        self.last_row = row;
        self.last_col = col;
        return true;
    }

    /// Check if the user has been idle long enough for proactive completion.
    pub fn isIdle(self: *const DebounceState, current_time: f64) bool {
        return current_time - self.last_request_time >= 1.0;
    }
};

pub fn detectLanguage(file_path: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_path);
    if (ext.len == 0) return "text";
    const lower = ext[1..];
    // Comprehensive language detection from file extension.
    // This is NOT hardcoded to specific languages — it maps common extensions
    // to their language names for syntax highlighting. Extensions not listed
    // here return "text" and are still rendered (just without keyword highlighting).
    // Extensions can be added via the extension system (packages/plugin/) for
    // new languages without modifying this function.
    if (std.mem.eql(u8, lower, "zig")) return "zig";
    if (std.mem.eql(u8, lower, "py")) return "python";
    if (std.mem.eql(u8, lower, "ts")) return "typescript";
    if (std.mem.eql(u8, lower, "tsx")) return "typescript";
    if (std.mem.eql(u8, lower, "js") or std.mem.eql(u8, lower, "mjs") or std.mem.eql(u8, lower, "cjs")) return "javascript";
    if (std.mem.eql(u8, lower, "jsx")) return "javascript";
    if (std.mem.eql(u8, lower, "rs")) return "rust";
    if (std.mem.eql(u8, lower, "go")) return "go";
    if (std.mem.eql(u8, lower, "c") or std.mem.eql(u8, lower, "h")) return "c";
    if (std.mem.eql(u8, lower, "cpp") or std.mem.eql(u8, lower, "cc") or std.mem.eql(u8, lower, "hpp") or std.mem.eql(u8, lower, "cxx")) return "cpp";
    if (std.mem.eql(u8, lower, "java")) return "java";
    if (std.mem.eql(u8, lower, "kt") or std.mem.eql(u8, lower, "kts")) return "kotlin";
    if (std.mem.eql(u8, lower, "swift")) return "swift";
    if (std.mem.eql(u8, lower, "rb")) return "ruby";
    if (std.mem.eql(u8, lower, "php")) return "php";
    if (std.mem.eql(u8, lower, "cs")) return "csharp";
    if (std.mem.eql(u8, lower, "scala") or std.mem.eql(u8, lower, "sc")) return "scala";
    if (std.mem.eql(u8, lower, "dart")) return "dart";
    if (std.mem.eql(u8, lower, "lua")) return "lua";
    if (std.mem.eql(u8, lower, "r")) return "r";
    if (std.mem.eql(u8, lower, "jl")) return "julia";
    if (std.mem.eql(u8, lower, "ex") or std.mem.eql(u8, lower, "exs")) return "elixir";
    if (std.mem.eql(u8, lower, "erl")) return "erlang";
    if (std.mem.eql(u8, lower, "hs")) return "haskell";
    if (std.mem.eql(u8, lower, "ml")) return "ocaml";
    if (std.mem.eql(u8, lower, "clj") or std.mem.eql(u8, lower, "cljs") or std.mem.eql(u8, lower, "cljc")) return "clojure";
    if (std.mem.eql(u8, lower, "sql")) return "sql";
    if (std.mem.eql(u8, lower, "sh") or std.mem.eql(u8, lower, "bash") or std.mem.eql(u8, lower, "zsh") or std.mem.eql(u8, lower, "fish")) return "shell";
    if (std.mem.eql(u8, lower, "ps1")) return "powershell";
    if (std.mem.eql(u8, lower, "bat") or std.mem.eql(u8, lower, "cmd")) return "batch";
    if (std.mem.eql(u8, lower, "dockerfile")) return "dockerfile";
    if (std.mem.eql(u8, lower, "md") or std.mem.eql(u8, lower, "markdown")) return "markdown";
    if (std.mem.eql(u8, lower, "rst")) return "rst";
    if (std.mem.eql(u8, lower, "tex")) return "latex";
    if (std.mem.eql(u8, lower, "html") or std.mem.eql(u8, lower, "htm")) return "html";
    if (std.mem.eql(u8, lower, "css")) return "css";
    if (std.mem.eql(u8, lower, "scss") or std.mem.eql(u8, lower, "sass")) return "scss";
    if (std.mem.eql(u8, lower, "xml") or std.mem.eql(u8, lower, "svg")) return "xml";
    if (std.mem.eql(u8, lower, "yml") or std.mem.eql(u8, lower, "yaml")) return "yaml";
    if (std.mem.eql(u8, lower, "json")) return "json";
    if (std.mem.eql(u8, lower, "toml")) return "toml";
    if (std.mem.eql(u8, lower, "ini") or std.mem.eql(u8, lower, "cfg") or std.mem.eql(u8, lower, "conf")) return "ini";
    if (std.mem.eql(u8, lower, "vim")) return "vim";
    if (std.mem.eql(u8, lower, "asm") or std.mem.eql(u8, lower, "s")) return "asm";
    if (std.mem.eql(u8, lower, "v")) return "verilog";
    if (std.mem.eql(u8, lower, "sv")) return "systemverilog";
    if (std.mem.eql(u8, lower, "vhd") or std.mem.eql(u8, lower, "vhdl")) return "vhdl";
    if (std.mem.eql(u8, lower, "proto")) return "protobuf";
    if (std.mem.eql(u8, lower, "gradle")) return "groovy";
    if (std.mem.eql(u8, lower, "groovy")) return "groovy";
    if (std.mem.eql(u8, lower, "nim")) return "nim";
    if (std.mem.eql(u8, lower, "vlang")) return "v";
    if (std.mem.eql(u8, lower, "cr")) return "crystal";
    if (std.mem.eql(u8, lower, "d")) return "d";
    if (std.mem.eql(u8, lower, "pas")) return "pascal";
    if (std.mem.eql(u8, lower, "pl") or std.mem.eql(u8, lower, "pm")) return "perl";
    if (std.mem.eql(u8, lower, "tcl")) return "tcl";
    if (std.mem.eql(u8, lower, "make") or std.mem.eql(u8, lower, "mk") or std.mem.eql(u8, lower, "mak")) return "makefile";
    if (std.mem.eql(u8, lower, "cmake")) return "cmake";
    if (std.mem.eql(u8, lower, "graphql") or std.mem.eql(u8, lower, "gql")) return "graphql";
    // For unknown extensions, return the extension itself as the language
    // name — this allows extension-provided syntax highlighters to handle
    // custom languages without modifying this function.
    return lower;
}

/// Build a FIM (Fill-In-the-Middle) prompt with codebase context.
/// Includes:
/// - File header (imports, type declarations)
/// - Code before cursor (prefix, up to 2048 chars)
/// - Code after cursor (suffix, up to 512 chars)
/// - RAG-retrieved similar code chunks (for codebase-aware completion)
/// - LSP document symbols (for knowing what functions exist in the file)
pub fn buildPrompt(allocator: std.mem.Allocator, request: CompletionRequest) ![]u8 {
    const language = request.language orelse detectLanguage(request.file_path);
    const prefix = if (request.prefix.len > 2048) request.prefix[request.prefix.len - 2048 ..] else request.prefix;
    const suffix = if (request.suffix.len > 512) request.suffix[0..512] else request.suffix;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // System prompt — instruct the model to complete code only.
    try buf.appendSlice(allocator, "You are an advanced code completion engine. ");
    try buf.appendSlice(allocator, "Complete the code at <CURSOR>. ");
    try buf.appendSlice(allocator, "Return ONLY the completion text — no markdown, no explanation. ");
    try buf.appendSlice(allocator, "Complete as many lines as needed. ");
    try buf.appendSlice(allocator, "Match the existing code style and indentation.\n\n");

    {
        const lang_line = std.fmt.allocPrint(allocator, "Language: {s}\n", .{language}) catch return error.OutOfMemory;
        defer allocator.free(lang_line);
        try buf.appendSlice(allocator, lang_line);
    }
    {
        const file_line = std.fmt.allocPrint(allocator, "File: {s}\n", .{request.file_path}) catch return error.OutOfMemory;
        defer allocator.free(file_line);
        try buf.appendSlice(allocator, file_line);
    }

    // File header (imports, declarations)
    if (request.file_header) |header| {
        const header_clipped = if (header.len > 512) header[0..512] else header;
        try buf.appendSlice(allocator, "\n--- file header ---\n");
        try buf.appendSlice(allocator, header_clipped);
        try buf.appendSlice(allocator, "\n--- end header ---\n");
    }

    // File symbols (from LSP — helps the model know what exists)
    if (request.file_symbols.len > 0) {
        try buf.appendSlice(allocator, "\n--- symbols in this file ---\n");
        for (request.file_symbols) |sym| {
            try buf.appendSlice(allocator, sym);
            try buf.append(allocator, '\n');
        }
        try buf.appendSlice(allocator, "--- end symbols ---\n");
    }

    // RAG-retrieved similar code (codebase-aware completion)
    if (request.similar_chunks.len > 0) {
        try buf.appendSlice(allocator, "\n--- similar code from codebase ---\n");
        for (request.similar_chunks) |chunk| {
            const clipped = if (chunk.len > 256) chunk[0..256] else chunk;
            try buf.appendSlice(allocator, clipped);
            try buf.appendSlice(allocator, "\n---\n");
        }
        try buf.appendSlice(allocator, "--- end similar code ---\n");
    }

    // Recent lines (what the user just typed)
    if (request.recent_lines.len > 0) {
        try buf.appendSlice(allocator, "\n--- recent edits ---\n");
        for (request.recent_lines) |line| {
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
        try buf.appendSlice(allocator, "--- end recent ---\n");
    }

    // Main FIM context
    try buf.appendSlice(allocator, "\n--- code before cursor ---\n");
    try buf.appendSlice(allocator, prefix);
    try buf.appendSlice(allocator, "\n<CURSOR>\n");
    try buf.appendSlice(allocator, "--- code after cursor ---\n");
    try buf.appendSlice(allocator, suffix);
    try buf.appendSlice(allocator, "\n--- end ---\n\n");
    try buf.appendSlice(allocator, "Completion (text only):\n");

    return buf.toOwnedSlice(allocator);
}

/// Request a completion from the provider. Supports caching and cancellation.
pub fn complete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    request: CompletionRequest,
    provider_options: provider_factory.Options,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
) CompletionError!CompletionResult {
    var provider_handle = provider_factory.create(allocator, io, environ_map, provider_options) catch return error.ProviderFailed;
    defer provider_handle.deinit(allocator);

    if (cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const prompt = try buildPrompt(allocator, request);
    defer allocator.free(prompt);

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    defer response_writer.deinit();

    var no_cancel_source = kernel.cancellation.CancellationTokenSource.init(allocator) catch return error.OutOfMemory;
    defer no_cancel_source.deinit();
    var no_cancel_token = no_cancel_source.getToken();
    const ask_token = if (cancel_token) |t| t else &no_cancel_token;
    provider_handle.ask(allocator, prompt, &.{}, &response_writer.writer, ask_token) catch return error.ProviderFailed;
    const raw = response_writer.written();

    const cleaned = stripFences(raw);
    if (cleaned.len == 0) return error.NoCompletion;

    const is_multiline = std.mem.indexOfScalar(u8, cleaned, '\n') != null;
    const line_count = countLines(cleaned);
    const text = allocator.dupe(u8, cleaned) catch return error.OutOfMemory;

    // Confidence heuristic: multi-line completions with proper indentation
    // get higher confidence than single-word completions.
    const confidence: f32 = if (is_multiline and line_count > 2)
        0.8
    else if (is_multiline)
        0.6
    else if (text.len > 10)
        0.5
    else
        0.3;

    return .{
        .text = text,
        .is_multiline = is_multiline,
        .confidence = confidence,
        .line_count = line_count,
    };
}

/// Accept the first line of a multi-line completion (partial accept).
/// Returns the accepted line and the remaining completion.
pub fn partialAccept(allocator: std.mem.Allocator, completion: []const u8) !struct {
    accepted: []const u8,
    remaining: []const u8,
} {
    if (std.mem.indexOfScalar(u8, completion, '\n')) |nl| {
        const accepted = try allocator.dupe(u8, completion[0..nl]);
        const remaining = try allocator.dupe(u8, completion[nl + 1 ..]);
        return .{ .accepted = accepted, .remaining = remaining };
    }
    // Single line — accept all
    const accepted = try allocator.dupe(u8, completion);
    const remaining = try allocator.dupe(u8, "");
    return .{ .accepted = accepted, .remaining = remaining };
}

fn countLines(text: []const u8) usize {
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn stripFences(text: []const u8) []const u8 {
    var s = std.mem.trim(u8, text, " \n\r\t");
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| {
            s = s[nl + 1 ..];
        } else {
            s = s[3..];
        }
        s = std.mem.trim(u8, s, " \n\r\t");
    }
    if (std.mem.endsWith(u8, s, "```")) {
        s = s[0 .. s.len - 3];
        s = std.mem.trim(u8, s, " \n\r\t");
    }
    return s;
}

test "detectLanguage maps common extensions" {
    try std.testing.expectEqualStrings("zig", detectLanguage("src/main.zig"));
    try std.testing.expectEqualStrings("python", detectLanguage("app/run.py"));
    try std.testing.expectEqualStrings("typescript", detectLanguage("src/index.ts"));
    try std.testing.expectEqualStrings("rust", detectLanguage("src/lib.rs"));
    try std.testing.expectEqualStrings("text", detectLanguage("README"));
}

test "buildPrompt includes language and cursor marker" {
    const allocator = std.testing.allocator;
    const prompt = try buildPrompt(allocator, .{
        .prefix = "fn main() {",
        .suffix = "}",
        .file_path = "main.zig",
    });
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Language: zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<CURSOR>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "fn main() {") != null);
}

test "buildPrompt includes similar chunks" {
    const allocator = std.testing.allocator;
    const chunks = [_][]const u8{ "fn similar() void {}", "const x = 42;" };
    const prompt = try buildPrompt(allocator, .{
        .prefix = "fn main() {",
        .suffix = "}",
        .file_path = "main.zig",
        .similar_chunks = &chunks,
    });
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "similar code") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "fn similar") != null);
}

test "stripFences removes markdown wrappers" {
    try std.testing.expectEqualStrings("hello", stripFences("```zig\nhello\n```"));
    try std.testing.expectEqualStrings("world", stripFences("  world  "));
}

test "CompletionCache stores and retrieves" {
    const allocator = std.testing.allocator;
    var cache = CompletionCache.init(allocator);
    defer cache.deinit();

    const key = CacheKey{ .file_hash = 123, .row = 5, .col = 10, .buffer_revision = 1 };
    const result = CompletionResult{
        .text = try allocator.dupe(u8, "test completion"),
        .is_multiline = false,
        .confidence = 0.8,
    };
    defer allocator.free(result.text);

    cache.put(key, result);

    const cached = cache.get(key);
    try std.testing.expect(cached != null);
    try std.testing.expectEqualStrings("test completion", cached.?.text);
    defer if (cached) |c| allocator.free(c.text);

    try std.testing.expectEqual(@as(u64, 1), cache.hits);
}

test "CompletionCache returns null for missing key" {
    const allocator = std.testing.allocator;
    var cache = CompletionCache.init(allocator);
    defer cache.deinit();

    const key = CacheKey{ .file_hash = 999, .row = 0, .col = 0, .buffer_revision = 0 };
    try std.testing.expect(cache.get(key) == null);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}

test "DebounceState allows immediate on row change" {
    var ds = DebounceState{};
    try std.testing.expect(ds.shouldRequest(1.0, 0, 5));
    try std.testing.expect(!ds.shouldRequest(1.1, 0, 6)); // Same row, too soon
    try std.testing.expect(ds.shouldRequest(1.2, 1, 0)); // Different row
}

test "partialAccept splits at first newline" {
    const allocator = std.testing.allocator;
    const result = try partialAccept(allocator, "line1\nline2\nline3");
    defer allocator.free(result.accepted);
    defer allocator.free(result.remaining);
    try std.testing.expectEqualStrings("line1", result.accepted);
    try std.testing.expectEqualStrings("line2\nline3", result.remaining);
}

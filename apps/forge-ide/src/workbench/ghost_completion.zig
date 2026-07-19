//! Ghost completion — AI-powered inline (ghost text) completion.
//!
//! Triggered automatically after a short idle period when the cursor is at the
//! end of an identifier. The completed text is displayed in a muted style and
//! accepted with Tab or dismissed with Escape.
//!
//! Provider: configured via [ghost_completion] in .forge/settings.toml.
//! Defaults to Ollama + qwen2.5-coder:7b for low-latency local completions.

const std = @import("std");
const forge_util = @import("forge-util");
const ai = @import("forge-ai");
const kernel = @import("forge-kernel");

/// Debounce delay in milliseconds before a completion request fires.
pub const debounce_ms: f32 = 600.0;

/// Maximum characters of context sent as prefix / suffix to the model.
pub const max_prefix_bytes: usize = 4096;
pub const max_suffix_bytes: usize = 1024;

/// Maximum bytes accepted from the model as a single completion.
pub const max_completion_bytes: usize = 512;

pub const Config = struct {
    /// "ollama" | "gemini" | "ai"
    /// - "ollama": direct HTTP to a local Ollama server (FIM prompt)
    /// - "gemini": direct HTTP to Google Gemini API
    /// - "ai": uses `forge-ai.inline_completion` module which routes through
    ///         the provider factory (supports gemini/openai/openrouter/nvidia/
    ///         ollama/fake, credential lookup, cancellation, etc.)
    provider: []const u8 = "ai",
    /// e.g. "gemini-2.5-flash" or "qwen2.5-coder:7b"
    model: []const u8 = "gemini-2.5-flash",
    /// Ollama base URL
    ollama_url: []const u8 = "http://127.0.0.1:11434",
    /// Gemini API key (read from env GEMINI_API_KEY if empty)
    gemini_api_key: []const u8 = "",
    /// Whether ghost completion is enabled at all
    enabled: bool = true,

    // --- "ai" provider configuration ------------------------------------

    /// Forge-AI provider name when `provider == "ai"`. Defaults to "auto"
    /// which lets the provider factory pick the first available provider
    /// based on environment variables / keychain.
    ai_provider: []const u8 = "auto",
    /// Optional base URL override (e.g. for self-hosted OpenAI-compatible
    /// endpoints). When null, the provider's default URL is used.
    ai_base_url: ?[]const u8 = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,

    /// Process environment map — needed for `forge-ai` provider factory to
    /// look up API keys (e.g. `OPENAI_API_KEY`, `GEMINI_API_KEY`).
    environ_map: ?*const std.process.Environ.Map = null,

    /// Path of the file currently being edited (owned, updated by
    /// `setFilePath`). Used by the `ai` provider to build a proper
    /// inline-completion prompt with language detection.
    file_path: ?[]const u8 = null,

    // Debounce countdown (counts down in milliseconds via frame delta).
    debounce_remaining: f32 = 0,

    // The row/col at which the current ghost text was generated.
    trigger_row: usize = 0,
    trigger_col: usize = 0,

    // Owned ghost text slice, or null when not active.
    ghost_text: ?[]const u8 = null,

    // True while an async request is in flight.
    pending: std.atomic.Value(bool) = .init(false),

    // Generation counter — incremented on each new request so stale responses
    // from concurrent requests are silently discarded.
    generation: u64 = 0,

    mutex: forge_util.sync.Mutex = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    pub fn deinit(self: *Store) void {
        self.clearGhostUnlocked();
        if (self.file_path) |p| self.allocator.free(p);
        self.file_path = null;
    }

    /// Update the path of the file currently being edited. The Store keeps
    /// an owned copy so callers may free `path` immediately. Used by the
    /// `ai` provider for language detection and to give the model context
    /// about which file is being completed.
    pub fn setFilePath(self: *Store, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.file_path) |p| self.allocator.free(p);
        self.file_path = self.allocator.dupe(u8, path) catch null;
    }

    /// Update the environment map reference (does not take ownership).
    pub fn setEnvironMap(self: *Store, environ_map: ?*const std.process.Environ.Map) void {
        self.environ_map = environ_map;
    }

    // -----------------------------------------------------------------------
    // State helpers

    pub fn hasGhost(self: *Store) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.ghost_text != null;
    }

    /// Clear active ghost text and reset debounce.
    pub fn dismiss(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearGhostUnlocked();
        self.debounce_remaining = 0;
    }

    /// Tick the debounce countdown. `delta_ms` is the frame time in milliseconds.
    /// Returns true when the debounce has expired and a request should fire.
    pub fn tick(self: *Store, delta_ms: f32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.debounce_remaining <= 0) return false;
        self.debounce_remaining -= delta_ms;
        if (self.debounce_remaining <= 0) {
            self.debounce_remaining = 0;
            return true;
        }
        return false;
    }

    /// Notify the store that the buffer changed at position (row, col).
    /// Resets debounce and invalidates any existing ghost text.
    pub fn onBufferChanged(self: *Store, row: usize, col: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.config.enabled) return;
        self.clearGhostUnlocked();
        self.trigger_row = row;
        self.trigger_col = col;
        self.debounce_remaining = debounce_ms;
    }

    /// Invalidate ghost text if the cursor has moved away from the trigger position.
    pub fn onCursorMoved(self: *Store, row: usize, col: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ghost_text == null) return;
        if (row != self.trigger_row or col != self.trigger_col) {
            self.clearGhostUnlocked();
        }
    }

    // -----------------------------------------------------------------------
    // Accept

    /// Remove and return the ghost text — caller must free the returned slice.
    pub fn accept(self: *Store) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const text = self.ghost_text orelse return null;
        self.ghost_text = null;
        self.debounce_remaining = 0;
        return text;
    }

    // -----------------------------------------------------------------------
    // Async fetch

    const FetchContext = struct {
        store: *Store,
        prefix: []const u8,
        suffix: []const u8,
        gen: u64,
        row: usize,
        col: usize,
    };

    fn fetchWorker(ctx: *FetchContext) void {
        defer {
            ctx.store.allocator.free(ctx.prefix);
            ctx.store.allocator.free(ctx.suffix);
            ctx.store.allocator.destroy(ctx);
            ctx.store.pending.store(false, .release);
        }

        const result = ctx.store.fetchBlocking(ctx.prefix, ctx.suffix, ctx.gen);

        if (result) |text| {
            ctx.store.mutex.lock();
            defer ctx.store.mutex.unlock();

            if (ctx.store.generation == ctx.gen) {
                ctx.store.clearGhostUnlocked();
                ctx.store.ghost_text = text;
                ctx.store.trigger_row = ctx.row;
                ctx.store.trigger_col = ctx.col;
            } else {
                ctx.store.allocator.free(text);
            }
        }
    }

    /// Kick off a completion request using the configured provider.
    pub fn requestCompletion(
        self: *Store,
        line_content: []const u8,
        prefix: []const u8,
        suffix: []const u8,
        row: usize,
        col: usize,
    ) void {
        if (!self.config.enabled) return;
        if (self.pending.load(.acquire)) return;

        // Only trigger when cursor is after an identifier-like character.
        if (!shouldTrigger(line_content, col)) return;

        self.mutex.lock();
        self.generation +%= 1;
        const gen = self.generation;
        self.mutex.unlock();

        self.pending.store(true, .release);

        const prefix_copy = self.allocator.dupe(u8, prefix[0..@min(prefix.len, max_prefix_bytes)]) catch {
            self.pending.store(false, .release);
            return;
        };
        const suffix_copy = self.allocator.dupe(u8, suffix[0..@min(suffix.len, max_suffix_bytes)]) catch {
            self.allocator.free(prefix_copy);
            self.pending.store(false, .release);
            return;
        };

        const ctx = self.allocator.create(FetchContext) catch {
            self.allocator.free(prefix_copy);
            self.allocator.free(suffix_copy);
            self.pending.store(false, .release);
            return;
        };
        ctx.* = .{
            .store = self,
            .prefix = prefix_copy,
            .suffix = suffix_copy,
            .gen = gen,
            .row = row,
            .col = col,
        };

        const thread = std.Thread.spawn(.{}, fetchWorker, .{ctx}) catch {
            self.allocator.free(prefix_copy);
            self.allocator.free(suffix_copy);
            self.allocator.destroy(ctx);
            self.pending.store(false, .release);
            return;
        };
        thread.detach();
    }

    // -----------------------------------------------------------------------
    // Private

    fn clearGhostUnlocked(self: *Store) void {
        if (self.ghost_text) |t| {
            self.allocator.free(t);
            self.ghost_text = null;
        }
    }

    fn fetchBlocking(self: *Store, prefix: []const u8, suffix: []const u8, gen: u64) ?[]const u8 {
        _ = gen;
        if (std.mem.eql(u8, self.config.provider, "ai")) {
            return self.fetchViaInlineCompletion(prefix, suffix) catch null;
        }
        if (std.mem.eql(u8, self.config.provider, "ollama")) {
            return self.fetchOllama(prefix, suffix) catch null;
        }
        return self.fetchGemini(prefix, suffix) catch null;
    }

    /// Routes the completion request through the `forge-ai.inline_completion`
    /// module, which uses the provider factory to support any configured
    /// provider (Gemini, OpenAI, OpenRouter, NVIDIA, Ollama, Fake) with
    /// proper credential lookup, language detection, prompt construction,
    /// and fence stripping. This is the recommended path for new setups.
    fn fetchViaInlineCompletion(self: *Store, prefix: []const u8, suffix: []const u8) ![]const u8 {
        const path = self.file_path orelse "untitled";

        var result = ai.inline_completion.complete(
            self.allocator,
            self.io,
            self.environ_map,
            .{
                .prefix = prefix,
                .suffix = suffix,
                .file_path = path,
                .max_tokens = 64,
                .timeout_ms = 3000,
            },
            .{
                .provider_name = self.config.ai_provider,
                .model = self.config.model,
                .base_url = self.config.ai_base_url,
            },
            null,
        ) catch return error.ProviderFailed;
        defer result.deinit(self.allocator);

        if (result.text.len == 0) return error.EmptyCompletion;

        // For ghost text we want a single line (multi-line ghost text is
        // supported by the Store but visually confusing for inline completion).
        const single_line = if (std.mem.indexOfScalar(u8, result.text, '\n')) |nl|
            result.text[0..nl]
        else
            result.text;
        const trimmed = std.mem.trimEnd(u8, single_line, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyCompletion;

        return self.allocator.dupe(u8, trimmed[0..@min(trimmed.len, max_completion_bytes)]);
    }

    fn buildFimPrompt(self: *Store, prefix: []const u8, suffix: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "<fim_prefix>{s}<fim_suffix>{s}<fim_middle>",
            .{ prefix, suffix },
        );
    }

    fn fetchOllama(self: *Store, prefix: []const u8, suffix: []const u8) ![]const u8 {
        const prompt = try self.buildFimPrompt(prefix, suffix);
        defer self.allocator.free(prompt);

        const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .model = self.config.model,
            .prompt = prompt,
            .stream = false,
            .options = .{ .num_predict = 128, .temperature = 0.1 },
        }, .{});
        defer self.allocator.free(payload);

        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/generate",
            .{self.config.ollama_url},
        );
        defer self.allocator.free(endpoint);

        var response_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer response_alloc.deinit();

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response_alloc.writer,
        }) catch return error.NetworkError;

        if (result.status != .ok) return error.NetworkError;

        const response_body = response_alloc.writer.buffer[0..response_alloc.writer.end];
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response_body,
            .{},
        ) catch return error.ParseError;
        defer parsed.deinit();

        const response_val = parsed.value.object.get("response") orelse return error.ParseError;
        const text = switch (response_val) {
            .string => |s| s,
            else => return error.ParseError,
        };

        if (text.len == 0) return error.EmptyCompletion;

        // Trim to first newline for single-line ghost text (standard UX).
        const single_line = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text[0..nl] else text;
        const trimmed = std.mem.trimEnd(u8, single_line, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyCompletion;

        return self.allocator.dupe(u8, trimmed[0..@min(trimmed.len, max_completion_bytes)]);
    }

    fn fetchGemini(self: *Store, prefix: []const u8, suffix: []const u8) ![]const u8 {
        const prompt = try self.buildFimPrompt(prefix, suffix);
        defer self.allocator.free(prompt);

        var key_buf: [256]u8 = undefined;
        const api_key = blk: {
            if (self.config.gemini_api_key.len > 0) break :blk self.config.gemini_api_key;
            const env_key_c = std.c.getenv("GEMINI_API_KEY") orelse return error.AuthFailed;
            const env_key = std.mem.span(env_key_c);
            const copied = key_buf[0..@min(env_key.len, key_buf.len)];
            @memcpy(copied, env_key[0..copied.len]);
            break :blk copied;
        };

        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}",
            .{ self.config.model, api_key },
        );
        defer self.allocator.free(endpoint);

        const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .contents = [_]struct {
                role: []const u8,
                parts: [1]struct { text: []const u8 },
            }{.{ .role = "user", .parts = .{.{ .text = prompt }} }},
            .generationConfig = .{ .maxOutputTokens = 128, .temperature = 0.1 },
        }, .{});
        defer self.allocator.free(payload);

        var response_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer response_alloc.deinit();

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response_alloc.writer,
        }) catch return error.NetworkError;

        if (result.status != .ok) return error.NetworkError;

        const response_body = response_alloc.writer.buffer[0..response_alloc.writer.end];
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response_body,
            .{},
        ) catch return error.ParseError;
        defer parsed.deinit();

        const candidates = parsed.value.object.get("candidates") orelse return error.ParseError;
        if (candidates.array.items.len == 0) return error.EmptyCompletion;
        const content = candidates.array.items[0].object.get("content") orelse return error.ParseError;
        const parts = content.object.get("parts") orelse return error.ParseError;
        if (parts.array.items.len == 0) return error.EmptyCompletion;
        const text_val = parts.array.items[0].object.get("text") orelse return error.ParseError;
        const text = switch (text_val) {
            .string => |s| s,
            else => return error.ParseError,
        };

        if (text.len == 0) return error.EmptyCompletion;
        const single_line = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text[0..nl] else text;
        const trimmed = std.mem.trimEnd(u8, single_line, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyCompletion;

        return self.allocator.dupe(u8, trimmed[0..@min(trimmed.len, max_completion_bytes)]);
    }
};

// ---------------------------------------------------------------------------
// Trigger heuristic

fn shouldTrigger(line: []const u8, col: usize) bool {
    if (col == 0) return false;
    const ch = line[col - 1];
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ':';
}

// ---------------------------------------------------------------------------
// Tests

test "ghost store debounce" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator, undefined, .{});
    defer store.deinit();

    store.onBufferChanged(0, 5);
    try std.testing.expect(!store.tick(200.0)); // 200 ms — still waiting
    try std.testing.expect(!store.tick(300.0)); // 500 ms total
    try std.testing.expect(store.tick(150.0)); // 650 ms — fires!
    try std.testing.expect(!store.tick(100.0)); // already fired
}

test "ghost store cursor invalidation" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator, undefined, .{});
    defer store.deinit();

    store.ghost_text = try allocator.dupe(u8, "hello");
    store.trigger_row = 1;
    store.trigger_col = 10;

    store.onCursorMoved(1, 10); // same position — keep
    try std.testing.expect(store.hasGhost());

    store.onCursorMoved(1, 11); // moved — dismiss
    try std.testing.expect(!store.hasGhost());
}

test "shouldTrigger" {
    try std.testing.expect(shouldTrigger("foo", 3));
    try std.testing.expect(shouldTrigger("a.", 2));
    try std.testing.expect(!shouldTrigger("  ", 1));
    try std.testing.expect(!shouldTrigger("x", 0));
}

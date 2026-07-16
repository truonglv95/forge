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
    max_tokens: u32 = 64,
    timeout_ms: u64 = 3000,
};

pub const CompletionResult = struct {
    text: []const u8,
    is_multiline: bool,
    confidence: f32 = 0,

    pub fn deinit(self: *CompletionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn detectLanguage(file_path: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_path);
    if (ext.len == 0) return "text";
    const lower = ext[1..];
    if (std.mem.eql(u8, lower, "zig")) return "zig";
    if (std.mem.eql(u8, lower, "py")) return "python";
    if (std.mem.eql(u8, lower, "ts")) return "typescript";
    if (std.mem.eql(u8, lower, "tsx")) return "typescript";
    if (std.mem.eql(u8, lower, "js")) return "javascript";
    if (std.mem.eql(u8, lower, "jsx")) return "javascript";
    if (std.mem.eql(u8, lower, "rs")) return "rust";
    if (std.mem.eql(u8, lower, "go")) return "go";
    if (std.mem.eql(u8, lower, "c") or std.mem.eql(u8, lower, "h")) return "c";
    if (std.mem.eql(u8, lower, "cpp") or std.mem.eql(u8, lower, "cc") or std.mem.eql(u8, lower, "hpp")) return "cpp";
    if (std.mem.eql(u8, lower, "java")) return "java";
    if (std.mem.eql(u8, lower, "rb")) return "ruby";
    if (std.mem.eql(u8, lower, "swift")) return "swift";
    if (std.mem.eql(u8, lower, "kt")) return "kotlin";
    if (std.mem.eql(u8, lower, "md")) return "markdown";
    if (std.mem.eql(u8, lower, "sh")) return "shell";
    if (std.mem.eql(u8, lower, "yml") or std.mem.eql(u8, lower, "yaml")) return "yaml";
    if (std.mem.eql(u8, lower, "json")) return "json";
    if (std.mem.eql(u8, lower, "toml")) return "toml";
    return "text";
}

pub fn buildPrompt(allocator: std.mem.Allocator, request: CompletionRequest) ![]u8 {
    const language = request.language orelse detectLanguage(request.file_path);
    const prefix = if (request.prefix.len > 2048) request.prefix[request.prefix.len - 2048 ..] else request.prefix;
    const suffix = if (request.suffix.len > 512) request.suffix[0..512] else request.suffix;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "You are an inline code completion engine. ");
    try buf.appendSlice(allocator, "Complete the code at the cursor position marked by <CURSOR>. ");
    try buf.appendSlice(allocator, "Return ONLY the completion text (no markdown fences, no explanation). ");
    try buf.appendSlice(allocator, "The completion should be the text that replaces <CURSOR>.\n\n");
    {
        const lang_line = std.fmt.allocPrint(allocator, "Language: {s}\n", .{language}) catch return error.OutOfMemory;
        defer allocator.free(lang_line);
        try buf.appendSlice(allocator, lang_line);
    }
    {
        const file_line = std.fmt.allocPrint(allocator, "File: {s}\n\n", .{request.file_path}) catch return error.OutOfMemory;
        defer allocator.free(file_line);
        try buf.appendSlice(allocator, file_line);
    }

    if (request.file_header) |header| {
        const header_clipped = if (header.len > 512) header[0..512] else header;
        try buf.appendSlice(allocator, "--- file header ---\n");
        try buf.appendSlice(allocator, header_clipped);
        try buf.appendSlice(allocator, "\n--- end header ---\n\n");
    }

    try buf.appendSlice(allocator, "--- code before cursor ---\n");
    try buf.appendSlice(allocator, prefix);
    try buf.appendSlice(allocator, "\n<CURSOR>\n");
    try buf.appendSlice(allocator, "--- code after cursor ---\n");
    try buf.appendSlice(allocator, suffix);
    try buf.appendSlice(allocator, "\n--- end ---\n\n");
    try buf.appendSlice(allocator, "Completion (text only, no fences):\n");

    return buf.toOwnedSlice(allocator);
}

pub fn complete(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    request: CompletionRequest,
    provider_options: provider_factory.Options,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
) CompletionError!CompletionResult {
    var provider_handle = provider_factory.create(allocator, io, environ_map, .{
        .provider_name = provider_options.provider_name,
        .base_url = provider_options.base_url,
        .model = provider_options.model,
    }) catch return error.ProviderFailed;
    defer provider_handle.deinit(allocator);

    if (cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const prompt = try buildPrompt(allocator, request);
    defer allocator.free(prompt);

    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);
    provider_handle.appendToolUserText(allocator, &conversation, prompt) catch return error.ProviderFailed;

    var completion = provider_handle.completeTurn(
        allocator,
        io,
        null,
        conversation.items,
        "[]",
        cancel_token,
    ) catch return error.ProviderFailed;
    defer completion.deinit(allocator);

    const raw = switch (completion) {
        .text => |t| t,
        .tool_call => return error.NoCompletion,
        .tool_calls => return error.NoCompletion,
    };

    const cleaned = stripFences(raw);
    if (cleaned.len == 0) return error.NoCompletion;

    const is_multiline = std.mem.indexOfScalar(u8, cleaned, '\n') != null;
    const text = allocator.dupe(u8, cleaned) catch return error.OutOfMemory;

    return .{ .text = text, .is_multiline = is_multiline, .confidence = 0.5 };
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

test "stripFences removes markdown wrappers" {
    try std.testing.expectEqualStrings("hello", stripFences("```zig\nhello\n```"));
    try std.testing.expectEqualStrings("world", stripFences("  world  "));
}

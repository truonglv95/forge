const std = @import("std");

pub const EndpointConfig = struct {
    default_base_url: []const u8,
    base_url_env_var: ?[]const u8 = null,
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

const JsonResponseFormat = struct {
    type: []const u8,
};

const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    stream: bool = true,
    response_format: ?JsonResponseFormat = null,
};

pub fn resolveBaseUrl(
    allocator: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    configured_url: ?[]const u8,
    config: EndpointConfig,
) ![]u8 {
    if (configured_url) |url| {
        const trimmed = std.mem.trim(u8, url, &std.ascii.whitespace);
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    if (environ_map) |map| {
        if (config.base_url_env_var) |env_var| {
            if (map.get(env_var)) |url| return allocator.dupe(u8, url);
        }
    }
    return allocator.dupe(u8, config.default_base_url);
}

pub fn buildChatEndpoint(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = trimTrailingSlash(base_url);
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed});
}

pub fn buildChatPayload(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    messages: []const ChatMessage,
    wants_json: bool,
) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, ChatRequest{
        .model = model_name,
        .messages = messages,
        .stream = true,
        .response_format = if (wants_json) .{ .type = "json_object" } else null,
    }, .{});
}

pub fn promptWantsJson(prompt: []const u8) bool {
    return std.mem.startsWith(u8, prompt, "INTENT_CLASSIFIER_MODE") or
        std.mem.indexOf(u8, prompt, "MARKDOWN PLAN MODE") == null;
}

fn trimTrailingSlash(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    return url[0..end];
}

test "buildChatEndpoint trims trailing slash" {
    const endpoint = try buildChatEndpoint(std.testing.allocator, "https://api.example/v1/");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://api.example/v1/chat/completions", endpoint);
}

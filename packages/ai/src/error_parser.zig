//! Provider error parser — parses provider-specific error responses and
//! produces user-friendly error messages with actionable suggestions.
const std = @import("std");

pub const ErrorCategory = enum {
    auth, // Invalid API key, expired token
    rate_limit, // 429 Too Many Requests
    network, // Connection timeout, DNS failure
    context_length, // Input too long for model
    model_not_found, // Invalid model ID
    server_error, // 500 Internal Server Error
    billing, // Quota exceeded, payment required
    unknown,
};

pub const ParsedError = struct {
    category: ErrorCategory,
    message: []const u8, // User-friendly message
    suggestion: []const u8, // Actionable suggestion
    retry_after_ms: ?u64 = null, // For rate limit: when to retry

    pub fn deinit(self: *ParsedError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.suggestion);
    }
};

/// Parse an error from a provider response.
/// `status_code` is the HTTP status code (0 for non-HTTP errors).
/// `body` is the response body (may contain provider-specific JSON).
/// `provider_name` is the provider name (gemini, anthropic, openai, etc.).
pub fn parseError(
    allocator: std.mem.Allocator,
    status_code: u16,
    body: []const u8,
    provider_name: []const u8,
) !ParsedError {
    // Rate limit (429)
    if (status_code == 429) {
        return .{
            .category = .rate_limit,
            .message = try std.fmt.allocPrint(allocator, "{s}: Rate limit exceeded. Too many requests.", .{provider_name}),
            .suggestion = try allocator.dupe(u8, "Wait a moment before sending another prompt. Consider upgrading your API plan for higher limits."),
            .retry_after_ms = 5000,
        };
    }

    // Auth errors (401, 403)
    if (status_code == 401) {
        return .{
            .category = .auth,
            .message = try std.fmt.allocPrint(allocator, "{s}: Invalid API key. Authentication failed.", .{provider_name}),
            .suggestion = try allocator.dupe(u8, "Check your API key in ~/.forge/settings.toml. Ensure the key is valid and has not expired."),
        };
    }
    if (status_code == 403) {
        // Could be billing or permissions
        if (std.mem.indexOf(u8, body, "billing") != null or std.mem.indexOf(u8, body, "quota") != null) {
            return .{
                .category = .billing,
                .message = try std.fmt.allocPrint(allocator, "{s}: Quota exceeded or billing issue.", .{provider_name}),
                .suggestion = try allocator.dupe(u8, "Check your billing dashboard. You may need to add credits or upgrade your plan."),
            };
        }
        return .{
            .category = .auth,
            .message = try std.fmt.allocPrint(allocator, "{s}: Access forbidden. API key lacks required permissions.", .{provider_name}),
            .suggestion = try allocator.dupe(u8, "Ensure your API key has the necessary permissions for this model."),
        };
    }

    // Not found (404) — usually invalid model
    if (status_code == 404) {
        return .{
            .category = .model_not_found,
            .message = try std.fmt.allocPrint(allocator, "{s}: Model not found. Check model ID.", .{provider_name}),
            .suggestion = try allocator.dupe(u8, "Verify the model ID in settings. Run 'forge models list' to see available models."),
        };
    }

    // Request entity too large (413) — context too long
    if (status_code == 413 or (status_code == 400 and (std.mem.indexOf(u8, body, "context") != null or std.mem.indexOf(u8, body, "token") != null))) {
        return .{
            .category = .context_length,
            .message = try std.fmt.allocPrint(allocator, "{s}: Input too long — exceeds model context window.", .{provider_name}),
            .suggestion = try allocator.dupe(u8, "Try reducing the context: close unnecessary files, use @file mentions instead of @folder, or switch to a model with a larger context window."),
        };
    }

    // Server errors (500, 502, 503)
    if (status_code >= 500) {
        return .{
            .category = .server_error,
            .message = try std.fmt.allocPrint(allocator, "{s}: Server error ({d}). The provider is experiencing issues.", .{ provider_name, status_code }),
            .suggestion = try allocator.dupe(u8, "Wait a moment and retry. If the problem persists, try a different provider or model."),
            .retry_after_ms = 3000,
        };
    }

    // Network errors (status_code == 0)
    if (status_code == 0) {
        if (std.mem.indexOf(u8, body, "timeout") != null or std.mem.indexOf(u8, body, "timed out") != null) {
            return .{
                .category = .network,
                .message = try std.fmt.allocPrint(allocator, "{s}: Request timed out.", .{provider_name}),
                .suggestion = try allocator.dupe(u8, "The provider took too long to respond. Try again, or use a smaller/faster model."),
            };
        }
        if (std.mem.indexOf(u8, body, "connect") != null or std.mem.indexOf(u8, body, "resolve") != null) {
            return .{
                .category = .network,
                .message = try std.fmt.allocPrint(allocator, "{s}: Cannot connect to provider.", .{provider_name}),
                .suggestion = try allocator.dupe(u8, "Check your internet connection. If using a proxy, verify the proxy settings."),
            };
        }
        return .{
            .category = .network,
            .message = try std.fmt.allocPrint(allocator, "{s}: Network error.", .{provider_name}),
            .suggestion = try allocator.dupe(u8, "Check your connection and try again."),
        };
    }

    // Generic bad request (400)
    if (status_code == 400) {
        // Try to extract error message from common JSON formats
        const detail = extractJsonError(body) orelse "Bad request";
        return .{
            .category = .unknown,
            .message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ provider_name, detail }),
            .suggestion = try allocator.dupe(u8, "Check the error details above. The request format may be incorrect."),
        };
    }

    // Unknown
    return .{
        .category = .unknown,
        .message = try std.fmt.allocPrint(allocator, "{s}: Error {d}", .{ provider_name, status_code }),
        .suggestion = try allocator.dupe(u8, "An unexpected error occurred. Check the provider documentation."),
    };
}

/// Extract error message from common JSON error formats:
/// {"error": {"message": "..."}}
/// {"error": {"error": {"message": "..."}}}
/// {"detail": "..."}
/// {"message": "..."}
fn extractJsonError(body: []const u8) ?[]const u8 {
    // Simple substring search — avoids full JSON parse for common cases.
    if (std.mem.indexOf(u8, body, "\"message\"")) |pos| {
        const after = body[pos + 10 ..];
        // Find opening quote
        if (std.mem.indexOfScalar(u8, after, '"')) |start| {
            const rest = after[start + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |end| {
                return rest[0..end];
            }
        }
    }
    if (std.mem.indexOf(u8, body, "\"detail\"")) |pos| {
        const after = body[pos + 9 ..];
        if (std.mem.indexOfScalar(u8, after, '"')) |start| {
            const rest = after[start + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |end| {
                return rest[0..end];
            }
        }
    }
    return null;
}

test "parseError detects rate limit" {
    const allocator = std.testing.allocator;
    var err = try parseError(allocator, 429, "", "gemini");
    defer err.deinit(allocator);
    try std.testing.expectEqual(ErrorCategory.rate_limit, err.category);
    try std.testing.expect(err.retry_after_ms != null);
}

test "parseError detects auth failure" {
    const allocator = std.testing.allocator;
    var err = try parseError(allocator, 401, "", "openai");
    defer err.deinit(allocator);
    try std.testing.expectEqual(ErrorCategory.auth, err.category);
}

test "parseError detects model not found" {
    const allocator = std.testing.allocator;
    var err = try parseError(allocator, 404, "", "anthropic");
    defer err.deinit(allocator);
    try std.testing.expectEqual(ErrorCategory.model_not_found, err.category);
}

test "parseError detects context length" {
    const allocator = std.testing.allocator;
    var err = try parseError(allocator, 413, "", "gemini");
    defer err.deinit(allocator);
    try std.testing.expectEqual(ErrorCategory.context_length, err.category);
}

test "parseError detects network timeout" {
    const allocator = std.testing.allocator;
    var err = try parseError(allocator, 0, "connection timeout", "ollama");
    defer err.deinit(allocator);
    try std.testing.expectEqual(ErrorCategory.network, err.category);
}

test "extractJsonError finds message" {
    const body = "{\"error\":{\"message\":\"model overloaded\"}}";
    const msg = extractJsonError(body);
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("model overloaded", msg.?);
}

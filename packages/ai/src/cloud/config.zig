//! Forge Cloud configuration — resolves Supabase project URL + anon key
//! from environment variables or compile-time defaults.

const std = @import("std");

pub const default_url: []const u8 = "https://forge-cloud.supabase.co";
pub const default_anon_key: []const u8 = "";

pub const CloudConfig = struct {
    project_url: []const u8,
    anon_key: []const u8,

    pub fn llmProxyUrl(self: CloudConfig, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/functions/v1/llm-proxy", .{self.project_url});
    }

    pub fn modelsUrl(self: CloudConfig, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/functions/v1/models", .{self.project_url});
    }

    pub fn userConfigUrl(self: CloudConfig, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/functions/v1/user-config", .{self.project_url});
    }

    pub fn usageUrl(self: CloudConfig, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/functions/v1/usage", .{self.project_url});
    }
};

pub fn resolve(allocator: ?std.mem.Allocator) CloudConfig {
    if (std.c.getenv("FORGE_CLOUD_URL")) |env_url| {
        const url = std.mem.span(env_url);
        const anon = if (std.c.getenv("FORGE_CLOUD_ANON_KEY")) |k| std.mem.span(k) else default_anon_key;
        if (allocator) |a| {
            const owned_url = a.dupe(u8, url) catch return .{ .project_url = default_url, .anon_key = default_anon_key };
            const owned_anon = a.dupe(u8, anon) catch return .{ .project_url = default_url, .anon_key = default_anon_key };
            return .{ .project_url = owned_url, .anon_key = owned_anon };
        }
        return .{ .project_url = url, .anon_key = anon };
    }
    return .{ .project_url = default_url, .anon_key = default_anon_key };
}

pub fn isConfigured(config: CloudConfig) bool {
    return config.anon_key.len > 0;
}

test "CloudConfig.llmProxyUrl builds correct endpoint" {
    const cfg = CloudConfig{ .project_url = "https://example.supabase.co", .anon_key = "key" };
    const url = try cfg.llmProxyUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://example.supabase.co/functions/v1/llm-proxy", url);
}

test "CloudConfig.modelsUrl builds correct endpoint" {
    const cfg = CloudConfig{ .project_url = "https://example.supabase.co", .anon_key = "key" };
    const url = try cfg.modelsUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://example.supabase.co/functions/v1/models", url);
}

test "isConfigured returns false for empty anon_key" {
    const cfg = CloudConfig{ .project_url = "https://example.supabase.co", .anon_key = "" };
    try std.testing.expect(!isConfigured(cfg));
}

test "isConfigured returns true for non-empty anon_key" {
    const cfg = CloudConfig{ .project_url = "https://example.supabase.co", .anon_key = "eyJ..." };
    try std.testing.expect(isConfigured(cfg));
}

test "resolve returns defaults when env vars not set" {
    const cfg = resolve(null);
    try std.testing.expectEqualStrings(default_url, cfg.project_url);
}

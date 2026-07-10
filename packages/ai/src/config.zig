const std = @import("std");
const codebase_search = @import("codebase_search.zig");
const provider_factory = @import("provider_factory.zig");

pub const default_context_budget_bytes: usize = 8 * 1024 * 1024;

pub const ProviderConfig = struct {
    name: []const u8 = "auto",
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,

    pub fn options(self: ProviderConfig) provider_factory.Options {
        return .{
            .provider_name = self.name,
            .model = self.model,
            .base_url = self.base_url,
        };
    }
};

pub const EmbeddingConfig = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    url: ?[]const u8 = null,

    pub fn options(self: EmbeddingConfig) codebase_search.EmbeddingOptions {
        return .{
            .provider = codebase_search.EmbeddingProvider.parse(self.provider),
            .model = self.model,
            .url = self.url,
        };
    }
};

pub const RuntimeConfig = struct {
    provider: ProviderConfig = .{},
    embedding: EmbeddingConfig = .{},
    context_budget_bytes: usize = default_context_budget_bytes,
};

pub fn baseUrlForProvider(
    provider_name: ?[]const u8,
    ollama_url: ?[]const u8,
    openrouter_url: ?[]const u8,
) ?[]const u8 {
    const name = provider_name orelse "auto";
    if (std.mem.eql(u8, name, "openrouter")) return openrouter_url;
    if (std.mem.eql(u8, name, "ollama")) return ollama_url;
    return null;
}

pub fn embeddingUrl(embedding_url: ?[]const u8, ollama_url: ?[]const u8) ?[]const u8 {
    return embedding_url orelse ollama_url;
}

test "baseUrlForProvider keeps provider-specific urls separate" {
    try std.testing.expectEqualStrings("https://openrouter.example", baseUrlForProvider("openrouter", "http://ollama", "https://openrouter.example").?);
    try std.testing.expectEqualStrings("http://ollama", baseUrlForProvider("ollama", "http://ollama", "https://openrouter.example").?);
    try std.testing.expect(baseUrlForProvider("gemini", "http://ollama", "https://openrouter.example") == null);
}

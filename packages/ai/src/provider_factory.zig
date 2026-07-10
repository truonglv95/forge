const std = @import("std");
const provider_mod = @import("provider.zig");
const fake_provider = @import("providers/fake/provider.zig");
const gemini_provider = @import("providers/gemini/provider.zig");
const ollama_provider = @import("providers/ollama/provider.zig");
const openrouter_provider = @import("providers/openrouter/provider.zig");
const credentials = @import("credentials.zig");

pub const FactoryError = error{
    MissingCredentials,
    ProviderInternalError,
    NetworkError,
    AuthenticationFailed,
    RateLimitExceeded,
    ContextLengthExceeded,
    MalformedResponse,
    Cancelled,
} || std.mem.Allocator.Error || std.fmt.ParseIntError;

pub const Options = struct {
    provider_name: []const u8 = "auto",
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,

    // Fake config
    fake_response: ?[]const u8 = null,
    fake_plan_response: ?[]const u8 = null,
    fake_tool_loop: bool = false,
    fake_tool_loop_short: bool = false,

    // Callbacks
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,
    thinking_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    thinking_context: ?*anyopaque = null,
};

const CreateFn = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) anyerror!provider_mod.Provider;

const ProviderDef = struct {
    name: []const u8,
    create: CreateFn,
};

fn wrapCreateFake(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map, options: Options) anyerror!provider_mod.Provider {
    return fake_provider.FakeProvider.create(allocator, io, environ_map, options);
}
fn wrapCreateOllama(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map, options: Options) anyerror!provider_mod.Provider {
    return ollama_provider.OllamaProvider.create(allocator, io, environ_map, options);
}
fn wrapCreateGemini(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map, options: Options) anyerror!provider_mod.Provider {
    return gemini_provider.GeminiProvider.create(allocator, io, environ_map, options);
}
fn wrapCreateOpenRouter(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map, options: Options) anyerror!provider_mod.Provider {
    return openrouter_provider.OpenRouterProvider.create(allocator, io, environ_map, options);
}

const registry = [_]ProviderDef{
    .{ .name = "fake", .create = wrapCreateFake },
    .{ .name = "gemini", .create = wrapCreateGemini },
    .{ .name = "ollama", .create = wrapCreateOllama },
    .{ .name = "openrouter", .create = wrapCreateOpenRouter },
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) !provider_mod.Provider {
    var resolved_name = options.provider_name;

    if (std.mem.eql(u8, resolved_name, "auto")) {
        resolved_name = "fake"; // Fallback

        if (ollama_provider.isReachable(allocator, io, ollama_provider.default_host)) {
            resolved_name = "ollama";
        } else {
            // Check if openrouter key exists
            if (credentials.Credentials.load(allocator, io, environ_map, &[_][]const u8{"OPENROUTER_API_KEY"}, "forge-openrouter", "default")) |creds_val| {
                var creds = creds_val;
                creds.deinit();
                resolved_name = "openrouter";
            } else |_| {
                // Check if gemini key exists
                if (credentials.Credentials.load(allocator, io, environ_map, &[_][]const u8{ "GEMINI_API_KEY", "GOOGLE_API_KEY" }, "forge-gemini", "default")) |creds_val2| {
                    var creds2 = creds_val2;
                    creds2.deinit();
                    resolved_name = "gemini";
                } else |_| {}
            }
        }
    }

    for (registry) |def| {
        if (std.mem.eql(u8, def.name, resolved_name)) {
            return def.create(allocator, io, environ_map, options) catch |err| switch (err) {
                error.MissingCredentials => return error.MissingCredentials,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ProviderInternalError,
            };
        }
    }

    // Fallback to fake if unknown
    return fake_provider.FakeProvider.create(allocator, io, environ_map, options) catch return error.ProviderInternalError;
}

test "auto resolves to fake without credentials or ollama" {
    var p = try create(std.testing.allocator, std.testing.io, null, .{
        .provider_name = "auto",
        .fake_response = "{}",
    });
    defer p.deinit(std.testing.allocator);

    const meta = p.metadata();
    try std.testing.expect(meta.provider_name.len > 0);
}

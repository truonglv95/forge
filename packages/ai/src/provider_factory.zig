const std = @import("std");
const provider_mod = @import("provider.zig");
const fake_provider = @import("providers/fake/provider.zig");
const gemini_provider = @import("providers/gemini/provider.zig");
const ollama_provider = @import("providers/ollama/provider.zig");
const openrouter_provider = @import("providers/openrouter/provider.zig");
const nvidia_provider = @import("providers/nvidia/provider.zig");
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

const CredentialAvailability = struct {
    env_vars: []const []const u8,
    keychain_service: []const u8,
    keychain_account: []const u8 = "default",
};

const Availability = union(enum) {
    always,
    ollama_probe,
    credentials: CredentialAvailability,
};

const ProviderDef = struct {
    name: []const u8,
    create: CreateFn,
    availability: Availability,
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

fn wrapCreateNvidia(allocator: std.mem.Allocator, io: std.Io, environ_map: ?*const std.process.Environ.Map, options: Options) anyerror!provider_mod.Provider {
    return nvidia_provider.NvidiaProvider.create(allocator, io, environ_map, options);
}

const registry = [_]ProviderDef{
    .{ .name = "ollama", .create = wrapCreateOllama, .availability = .ollama_probe },
    .{
        .name = "nvidia",
        .create = wrapCreateNvidia,
        .availability = .{ .credentials = .{
            .env_vars = &[_][]const u8{"NVIDIA_API_KEY"},
            .keychain_service = "forge-nvidia",
        } },
    },
    .{
        .name = "openrouter",
        .create = wrapCreateOpenRouter,
        .availability = .{ .credentials = .{
            .env_vars = &[_][]const u8{"OPENROUTER_API_KEY"},
            .keychain_service = "forge-openrouter",
        } },
    },
    .{
        .name = "gemini",
        .create = wrapCreateGemini,
        .availability = .{ .credentials = .{
            .env_vars = &[_][]const u8{ "GEMINI_API_KEY", "GOOGLE_API_KEY" },
            .keychain_service = "forge-gemini",
        } },
    },
    .{ .name = "fake", .create = wrapCreateFake, .availability = .always },
};

fn findProvider(name: []const u8) ?*const ProviderDef {
    for (&registry) |*def| {
        if (std.mem.eql(u8, def.name, name)) return def;
    }
    return null;
}

fn providerAvailable(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
    def: ProviderDef,
) bool {
    return switch (def.availability) {
        .always => true,
        .ollama_probe => blk: {
            const host = ollama_provider.resolveHost(allocator, environ_map, options.base_url) catch break :blk false;
            defer allocator.free(host);
            break :blk ollama_provider.isReachable(allocator, io, host);
        },
        .credentials => |cred| blk: {
            if (credentials.Credentials.load(
                allocator,
                io,
                environ_map,
                cred.env_vars,
                cred.keychain_service,
                cred.keychain_account,
            )) |creds_val| {
                var creds = creds_val;
                creds.deinit();
                break :blk true;
            } else |_| {
                break :blk false;
            }
        },
    };
}

fn resolveProviderName(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) []const u8 {
    if (!std.mem.eql(u8, options.provider_name, "auto")) return options.provider_name;
    for (registry) |def| {
        if (providerAvailable(allocator, io, environ_map, options, def)) return def.name;
    }
    return "fake";
}

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) !provider_mod.Provider {
    const resolved_name = resolveProviderName(allocator, io, environ_map, options);
    if (aiDebugEnabled()) {
        std.debug.print("CALLING API PROVIDER: {s} | MODEL: {s}\n", .{ resolved_name, options.model orelse "unknown" });
    }

    if (findProvider(resolved_name)) |def| {
        return def.create(allocator, io, environ_map, options) catch |err| switch (err) {
            error.MissingCredentials => return error.MissingCredentials,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProviderInternalError,
        };
    }

    // Fallback to fake if unknown
    return fake_provider.FakeProvider.create(allocator, io, environ_map, options) catch return error.ProviderInternalError;
}

fn aiDebugEnabled() bool {
    const value = std.c.getenv("FORGE_AI_DEBUG") orelse return false;
    const text = std.mem.span(value);
    return std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true");
}

test "auto resolves to fake without credentials or ollama" {
    var p = try create(std.testing.allocator, std.testing.io, null, .{
        .provider_name = "auto",
        .model = "test-model",
        .fake_response = "{}",
    });
    defer p.deinit(std.testing.allocator);

    const meta = p.metadata();
    try std.testing.expect(meta.provider_name.len > 0);
}

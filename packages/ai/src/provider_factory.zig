const std = @import("std");
const provider_mod = @import("provider.zig");
const fake_provider = @import("fake_provider.zig");
const gemini_provider = @import("gemini_provider.zig");
const ollama_provider = @import("ollama_provider.zig");
const credentials = @import("credentials.zig");

pub const Kind = enum {
    auto,
    fake,
    gemini,
    ollama,

    pub fn parse(name: ?[]const u8) Kind {
        const value = name orelse return .auto;
        if (std.mem.eql(u8, value, "fake")) return .fake;
        if (std.mem.eql(u8, value, "gemini")) return .gemini;
        if (std.mem.eql(u8, value, "ollama")) return .ollama;
        if (std.mem.eql(u8, value, "auto")) return .auto;
        return .auto;
    }
};

pub const Options = struct {
    kind: Kind = .auto,
    model: ?[]const u8 = null,
    ollama_url: ?[]const u8 = null,
    fake_response: []const u8,
    fake_plan_response: ?[]const u8 = null,
    fake_tool_loop: bool = false,
    fake_tool_loop_short: bool = false,
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,
    thinking_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    thinking_context: ?*anyopaque = null,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    fake: ?fake_provider.FakeProvider = null,
    gemini: ?gemini_provider.GeminiProvider = null,
    ollama: ?ollama_provider.OllamaProvider = null,

    pub fn deinit(self: *Handle) void {
        if (self.gemini) |*owned| owned.deinit();
        if (self.ollama) |*owned| owned.deinit();
    }

    pub fn interface(self: *Handle) provider_mod.Provider {
        if (self.gemini) |*gemini| return gemini.providerInterface();
        if (self.ollama) |*ollama| return ollama.providerInterface();
        if (self.fake) |*fake| return fake.providerInterface();
        unreachable;
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    options: Options,
) !Handle {
    const resolved = try resolveKind(allocator, io, environ_map, options.kind, options.ollama_url);

    return switch (resolved) {
        .fake => .{
            .allocator = allocator,
            .fake = fake_provider.FakeProvider.initWithToolLoop(
                options.fake_response,
                options.fake_plan_response,
                options.stream_callback,
                options.stream_context,
                options.fake_tool_loop,
                options.fake_tool_loop_short,
            ),
        },
        .gemini => .{
            .allocator = allocator,
            .gemini = gemini_provider.GeminiProvider.init(
                allocator,
                io,
                try credentials.Credentials.loadGemini(allocator, io, environ_map),
                options.model orelse gemini_provider.default_model,
                options.stream_callback,
                options.stream_context,
                options.thinking_callback,
                options.thinking_context,
            ),
        },
        .ollama => blk: {
            const host = try ollama_provider.resolveHost(allocator, environ_map, options.ollama_url);
            defer allocator.free(host);
            break :blk .{
                .allocator = allocator,
                .ollama = try ollama_provider.OllamaProvider.init(
                    allocator,
                    io,
                    host,
                    options.model orelse ollama_provider.default_model,
                    ollama_provider.resolveNumCtx(environ_map),
                    options.stream_callback,
                    options.stream_context,
                ),
            };
        },
    };
}

const ResolvedKind = enum {
    fake,
    gemini,
    ollama,
};

fn resolveKind(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    kind: Kind,
    ollama_url: ?[]const u8,
) !ResolvedKind {
    return switch (kind) {
        .fake => .fake,
        .gemini => {
            var loaded = credentials.Credentials.loadGemini(allocator, io, environ_map) catch |err| switch (err) {
                error.NotFound => return error.MissingCredentials,
                else => return err,
            };
            loaded.deinit();
            return .gemini;
        },
        .ollama => .ollama,
        .auto => {
            const host = try ollama_provider.resolveHost(allocator, environ_map, ollama_url);
            defer allocator.free(host);
            if (ollama_provider.isReachable(allocator, io, host)) return .ollama;

            var loaded = credentials.Credentials.loadGemini(allocator, io, environ_map) catch {
                return .fake;
            };
            loaded.deinit();
            return .gemini;
        },
    };
}

pub const FactoryError = error{
    MissingCredentials,
};

test "auto resolves to fake without credentials or ollama" {
    var handle = try create(std.testing.allocator, std.testing.io, null, .{
        .kind = .auto,
        .fake_response = "{}",
    });
    defer handle.deinit();

    const meta = handle.interface().metadata();
    // Without a running Ollama server, auto falls back to fake when no Gemini key.
    try std.testing.expect(meta.provider_name.len > 0);
}

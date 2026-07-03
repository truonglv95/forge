const std = @import("std");
const provider_mod = @import("provider.zig");
const fake_provider = @import("fake_provider.zig");
const gemini_provider = @import("gemini_provider.zig");
const credentials = @import("credentials.zig");

pub const Kind = enum {
    auto,
    fake,
    gemini,

    pub fn parse(name: ?[]const u8) Kind {
        const value = name orelse return .auto;
        if (std.mem.eql(u8, value, "fake")) return .fake;
        if (std.mem.eql(u8, value, "gemini")) return .gemini;
        if (std.mem.eql(u8, value, "auto")) return .auto;
        return .auto;
    }
};

pub const Options = struct {
    kind: Kind = .auto,
    model: ?[]const u8 = null,
    fake_response: []const u8,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    fake: ?fake_provider.FakeProvider = null,
    gemini: ?gemini_provider.GeminiProvider = null,

    pub fn deinit(self: *Handle) void {
        if (self.gemini) |*owned| owned.deinit();
    }

    pub fn interface(self: *Handle) provider_mod.Provider {
        if (self.gemini) |*gemini| return gemini.providerInterface();
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
    const resolved = try resolveKind(allocator, io, environ_map, options.kind);

    return switch (resolved) {
        .fake => .{
            .allocator = allocator,
            .fake = fake_provider.FakeProvider.init(options.fake_response),
        },
        .gemini => .{
            .allocator = allocator,
            .gemini = gemini_provider.GeminiProvider.init(
                allocator,
                io,
                try credentials.Credentials.loadGemini(allocator, io, environ_map),
                options.model orelse gemini_provider.default_model,
            ),
        },
    };
}

const ResolvedKind = enum {
    fake,
    gemini,
};

fn resolveKind(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    kind: Kind,
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
        .auto => {
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

test "auto resolves to fake without credentials" {
    var handle = try create(std.testing.allocator, std.testing.io, null, .{
        .kind = .auto,
        .fake_response = "{}",
    });
    defer handle.deinit();

    const meta = handle.interface().metadata();
    try std.testing.expectEqualStrings("fake", meta.provider_name);
}

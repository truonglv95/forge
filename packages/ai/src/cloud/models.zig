//! Forge Cloud models fetcher — calls GET /functions/v1/models to retrieve
//! the server-managed model catalog from forge-cloud-backend.

const std = @import("std");
const cloud_config = @import("config.zig");

pub const CloudError = error{
    NetworkError,
    AuthenticationFailed,
    NotConfigured,
    MalformedResponse,
    OutOfMemory,
    QuotaExceeded,
};

pub const CloudModel = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    label: []u8,
    provider: []u8,
    context_window: u32,
    max_output_tokens: u32,
    supports_tools: bool,
    supports_vision: bool,
    supports_thinking: bool,
    input_price_per_1m: f64,
    output_price_per_1m: f64,

    pub fn deinit(self: *CloudModel) void {
        self.allocator.free(self.id);
        self.allocator.free(self.label);
        self.allocator.free(self.provider);
        self.* = undefined;
    }
};

pub const CloudModelList = struct {
    allocator: std.mem.Allocator,
    models: []CloudModel,

    pub fn deinit(self: *CloudModelList) void {
        for (self.models) |*m| m.deinit();
        self.allocator.free(self.models);
        self.* = undefined;
    }
};

pub fn fetchModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: cloud_config.CloudConfig,
    access_token: []const u8,
) CloudError!CloudModelList {
    if (!cloud_config.isConfigured(config)) return CloudError.NotConfigured;
    if (access_token.len == 0) return CloudError.AuthenticationFailed;

    const url = try config.modelsUrl(allocator);
    defer allocator.free(url);

    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token}) catch
        return CloudError.OutOfMemory;
    defer allocator.free(auth_header);

    const headers = [_]std.http.Header{
        .{ .name = "apikey", .value = config.anon_key },
        .{ .name = "Authorization", .value = auth_header },
    };

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &headers,
        .response_writer = &response_alloc.writer,
    }) catch return CloudError.NetworkError;

    const body = response_alloc.writer.buffer[0..response_alloc.writer.end];

    return switch (result.status) {
        .ok => parseModelsResponse(allocator, body),
        .unauthorized, .forbidden => CloudError.AuthenticationFailed,
        .too_many_requests => CloudError.QuotaExceeded,
        else => CloudError.NetworkError,
    };
}

fn parseModelsResponse(allocator: std.mem.Allocator, body: []const u8) CloudError!CloudModelList {
    if (body.len == 0) return CloudError.MalformedResponse;

    const Parsed = struct {
        models: []struct {
            id: []const u8,
            label: []const u8,
            provider: []const u8,
            context_window: u32 = 0,
            max_output_tokens: u32 = 8192,
            supports_tools: bool = false,
            supports_vision: bool = false,
            supports_thinking: bool = false,
            input_price_per_1m: f64 = 0,
            output_price_per_1m: f64 = 0,
        },
    };

    var parsed = std.json.parseFromSlice(Parsed, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return CloudError.MalformedResponse;
    defer parsed.deinit();

    const src = parsed.value.models;
    if (src.len == 0) {
        return CloudModelList{ .allocator = allocator, .models = &.{} };
    }

    const out = allocator.alloc(CloudModel, src.len) catch return CloudError.OutOfMemory;
    errdefer allocator.free(out);

    var written: usize = 0;
    errdefer {
        for (out[0..written]) |*m| m.deinit();
    }

    for (src) |m| {
        out[written] = CloudModel{
            .allocator = allocator,
            .id = allocator.dupe(u8, m.id) catch return CloudError.OutOfMemory,
            .label = allocator.dupe(u8, m.label) catch return CloudError.OutOfMemory,
            .provider = allocator.dupe(u8, m.provider) catch return CloudError.OutOfMemory,
            .context_window = m.context_window,
            .max_output_tokens = m.max_output_tokens,
            .supports_tools = m.supports_tools,
            .supports_vision = m.supports_vision,
            .supports_thinking = m.supports_thinking,
            .input_price_per_1m = m.input_price_per_1m,
            .output_price_per_1m = m.output_price_per_1m,
        };
        written += 1;
    }

    return CloudModelList{ .allocator = allocator, .models = out };
}

test "parseModelsResponse parses valid response" {
    const body =
        \\{"models":[
        \\  {"id":"gpt-4o","label":"GPT-4o","provider":"openai","context_window":128000,"max_output_tokens":16384,"supports_tools":true,"supports_vision":true,"supports_thinking":false,"input_price_per_1m":2.50,"output_price_per_1m":10.00},
        \\  {"id":"claude-sonnet-4","label":"Claude Sonnet 4","provider":"openrouter","context_window":200000,"max_output_tokens":8192,"supports_tools":true,"supports_vision":true,"supports_thinking":false,"input_price_per_1m":3.00,"output_price_per_1m":15.00}
        \\]}
    ;
    var list = try parseModelsResponse(std.testing.allocator, body);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 2), list.models.len);
    try std.testing.expectEqualStrings("gpt-4o", list.models[0].id);
    try std.testing.expectEqualStrings("GPT-4o", list.models[0].label);
    try std.testing.expectEqualStrings("openai", list.models[0].provider);
    try std.testing.expectEqual(@as(u32, 128000), list.models[0].context_window);
    try std.testing.expect(list.models[0].supports_tools);
    try std.testing.expect(!list.models[0].supports_thinking);
    try std.testing.expectEqual(@as(f64, 2.50), list.models[0].input_price_per_1m);
}

test "parseModelsResponse handles empty models array" {
    const body = "{\"models\":[]}";
    var list = try parseModelsResponse(std.testing.allocator, body);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 0), list.models.len);
}

test "parseModelsResponse rejects empty body" {
    try std.testing.expectError(CloudError.MalformedResponse, parseModelsResponse(std.testing.allocator, ""));
}

test "parseModelsResponse rejects malformed JSON" {
    try std.testing.expectError(CloudError.MalformedResponse, parseModelsResponse(std.testing.allocator, "not json"));
}

test "parseModelsResponse fills defaults for optional fields" {
    const body = "{\"models\":[{\"id\":\"x\",\"label\":\"X\",\"provider\":\"openai\"}]}";
    var list = try parseModelsResponse(std.testing.allocator, body);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), list.models.len);
    try std.testing.expectEqual(@as(u32, 8192), list.models[0].max_output_tokens);
    try std.testing.expect(!list.models[0].supports_tools);
}

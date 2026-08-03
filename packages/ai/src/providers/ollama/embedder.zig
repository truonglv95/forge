const std = @import("std");

pub const default_model = "nomic-embed-text";

pub const Config = struct {
    base_url: []const u8,
    model: []const u8 = default_model,
};

pub fn embedAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    text: []const u8,
) ![]f32 {
    return embedViaEndpoint(allocator, io, config, text, .api_embed) catch {
        return embedViaEndpoint(allocator, io, config, text, .api_embeddings);
    };
}

pub fn embedInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    text: []const u8,
    out: []f32,
) !void {
    const vec = try embedAlloc(allocator, io, config, text);
    defer allocator.free(vec);
    if (out.len < vec.len) return error.BufferTooSmall;
    @memcpy(out[0..vec.len], vec);
    normalize(out[0..vec.len]);
}

const EndpointKind = enum { api_embed, api_embeddings };

fn embedViaEndpoint(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    text: []const u8,
    endpoint_kind: EndpointKind,
) ![]f32 {
    const endpoint = try buildEndpoint(allocator, config.base_url, endpoint_kind);
    defer allocator.free(endpoint);

    const payload = switch (endpoint_kind) {
        .api_embed => try buildEmbedPayload(allocator, config.model, text),
        .api_embeddings => try buildEmbeddingsPayload(allocator, config.model, text),
    };
    defer allocator.free(payload);

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &response_alloc.writer,
    }) catch return error.NetworkError;

    if (result.status != .ok) return error.ProviderFailed;
    return parseEmbeddingValues(allocator, response_alloc.writer.buffer[0..response_alloc.writer.end]);
}

fn buildEndpoint(allocator: std.mem.Allocator, base_url: []const u8, endpoint_kind: EndpointKind) ![]u8 {
    const trimmed = trimTrailingSlashes(base_url);
    const suffix = switch (endpoint_kind) {
        .api_embed => "/api/embed",
        .api_embeddings => "/api/embeddings",
    };
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, suffix });
}

fn trimTrailingSlashes(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

fn buildEmbedPayload(allocator: std.mem.Allocator, model: []const u8, text: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{
        .model = model,
        .input = text,
    }, .{});
}

fn buildEmbeddingsPayload(allocator: std.mem.Allocator, model: []const u8, text: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{
        .model = model,
        .prompt = text,
    }, .{});
}

fn parseEmbeddingValues(allocator: std.mem.Allocator, response_json: []const u8) ![]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{});
    defer parsed.deinit();

    if (parsed.value.object.get("embeddings")) |embeddings| {
        if (embeddings != .array or embeddings.array.items.len == 0) return error.MalformedResponse;
        const first = embeddings.array.items[0];
        if (first != .array) return error.MalformedResponse;
        return valuesFromArray(allocator, first.array.items);
    }

    if (parsed.value.object.get("embedding")) |embedding| {
        if (embedding != .array) return error.MalformedResponse;
        return valuesFromArray(allocator, embedding.array.items);
    }

    return error.MalformedResponse;
}

fn valuesFromArray(allocator: std.mem.Allocator, items: []const std.json.Value) ![]f32 {
    var out = try allocator.alloc(f32, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |value| @floatCast(value),
            .integer => |value| @floatFromInt(value),
            else => return error.MalformedResponse,
        };
    }
    normalize(out);
    return out;
}

fn normalize(vec: []f32) void {
    var sum: f32 = 0;
    for (vec) |v| sum += v * v;
    const norm = @sqrt(sum);
    if (norm == 0) return;
    for (vec) |*v| v.* /= norm;
}

test "parseEmbeddingValues supports /api/embed response" {
    const allocator = std.testing.allocator;
    const values = try parseEmbeddingValues(allocator, "{\"embeddings\":[[1.0,2.0,3.0]]}");
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 3), values.len);
}

test "parseEmbeddingValues supports /api/embeddings response" {
    const allocator = std.testing.allocator;
    const values = try parseEmbeddingValues(allocator, "{\"embedding\":[1.0,2.0,3.0]}");
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 3), values.len);
}

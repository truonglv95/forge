const std = @import("std");

pub const default_url = "https://openrouter.ai/api/v1";
pub const default_model = "nvidia/llama-nemotron-embed-vl-1b-v2:free";

pub const Config = struct {
    base_url: []const u8,
    model: []const u8 = default_model,
    api_key: []const u8,
};

pub fn embedAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    text: []const u8,
) ![]f32 {
    return embedViaEndpoint(allocator, io, config, text);
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

fn embedViaEndpoint(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    text: []const u8,
) ![]f32 {
    const endpoint = try buildEndpoint(allocator, config.base_url);
    defer allocator.free(endpoint);

    const payload = try buildEmbedPayload(allocator, config.model, text);
    defer allocator.free(payload);

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{config.api_key});
    defer allocator.free(auth_header);

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
        },
        .extra_headers = &[_]std.http.Header{
            .{ .name = "HTTP-Referer", .value = "https://github.com/truonglv95/forge" },
            .{ .name = "X-Title", .value = "Forge IDE" },
        },
        .response_writer = &response_alloc.writer,
    }) catch return error.NetworkError;

    if (result.status != .ok) {
        std.debug.print("OpenRouter Error: status={}, body={s}\n", .{ result.status, response_alloc.writer.buffer[0..response_alloc.writer.end] });
        return error.ProviderFailed;
    }
    return parseEmbeddingValues(allocator, response_alloc.writer.buffer[0..response_alloc.writer.end]);
}

fn buildEndpoint(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = trimTrailingSlashes(base_url);
    return try std.fmt.allocPrint(allocator, "{s}/embeddings", .{trimmed});
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

fn parseEmbeddingValues(allocator: std.mem.Allocator, response_json: []const u8) ![]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{});
    defer parsed.deinit();

    if (parsed.value.object.get("data")) |data| {
        if (data != .array or data.array.items.len == 0) {
            std.debug.print("OpenRouter parse Error: data is not array or empty. json: {s}\n", .{response_json});
            return error.MalformedResponse;
        }
        const first = data.array.items[0];
        if (first != .object) {
            std.debug.print("OpenRouter parse Error: first item not object. json: {s}\n", .{response_json});
            return error.MalformedResponse;
        }
        if (first.object.get("embedding")) |embedding| {
            if (embedding != .array) {
                std.debug.print("OpenRouter parse Error: embedding is not array. json: {s}\n", .{response_json});
                return error.MalformedResponse;
            }
            return valuesFromArray(allocator, embedding.array.items);
        }
    }

    std.debug.print("OpenRouter parse Error: missing data or embedding field. json: {s}\n", .{response_json});
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

test "parseEmbeddingValues supports openai format" {
    const allocator = std.testing.allocator;
    const values = try parseEmbeddingValues(allocator, "{\"data\":[{\"embedding\":[1.0,2.0,3.0]}]}");
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 3), values.len);
}

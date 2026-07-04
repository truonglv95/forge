const std = @import("std");
const credentials = @import("credentials.zig");

pub const default_model = "text-embedding-004";
pub const dim: usize = 768;

const endpoint_base = "https://generativelanguage.googleapis.com/v1beta/models/";

pub fn embedInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    creds: credentials.Credentials,
    text: []const u8,
    out: []f32,
) !void {
    if (out.len < dim) return error.BufferTooSmall;

    const endpoint = try std.fmt.allocPrint(allocator, "{s}{s}:embedContent", .{ endpoint_base, default_model });
    defer allocator.free(endpoint);

    const payload = try buildPayload(allocator, text);
    defer allocator.free(payload);

    const api_headers = [_]std.http.Header{
        .{ .name = "x-goog-api-key", .value = creds.api_key },
    };

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
        .extra_headers = &api_headers,
        .response_writer = &response_alloc.writer,
    }) catch return error.NetworkError;

    if (result.status != .ok) return error.ProviderFailed;

    const values = try parseEmbeddingValues(allocator, response_alloc.writer.buffer[0..response_alloc.writer.end]);
    defer allocator.free(values);

    if (values.len < dim) return error.MalformedResponse;
    @memcpy(out[0..dim], values[0..dim]);
    normalize(out[0..dim]);
}

fn buildPayload(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);
    try escaped.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '\\' => try escaped.appendSlice(allocator, "\\\\"),
            '"' => try escaped.appendSlice(allocator, "\\\""),
            '\n' => try escaped.appendSlice(allocator, "\\n"),
            '\r' => try escaped.appendSlice(allocator, "\\r"),
            '\t' => try escaped.appendSlice(allocator, "\\t"),
            else => try escaped.append(allocator, c),
        }
    }
    try escaped.append(allocator, '"');

    return try std.fmt.allocPrint(allocator,
        \\{{"model":"models/{s}","content":{{"parts":[{{"text":{s}}}]}}}}
    , .{ default_model, escaped.items });
}

fn parseEmbeddingValues(allocator: std.mem.Allocator, response_json: []const u8) ![]f32 {
    const values_key = std.mem.indexOf(u8, response_json, "\"values\"") orelse return error.MalformedResponse;
    const array_start = std.mem.indexOfPos(u8, response_json, values_key, "[") orelse return error.MalformedResponse;
    const array_end = std.mem.indexOfPos(u8, response_json, array_start, "]") orelse return error.MalformedResponse;
    const array_body = response_json[array_start + 1 .. array_end];

    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(allocator);

    var offset: usize = 0;
    while (offset < array_body.len) {
        while (offset < array_body.len and (array_body[offset] == ' ' or array_body[offset] == ',')) : (offset += 1) {}
        if (offset >= array_body.len) break;
        const end = blk: {
            var i = offset;
            while (i < array_body.len and array_body[i] != ',') : (i += 1) {}
            break :blk i;
        };
        const token = std.mem.trim(u8, array_body[offset..end], " ");
        const value = std.fmt.parseFloat(f32, token) catch return error.MalformedResponse;
        try out.append(allocator, value);
        offset = end + 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn normalize(vec: []f32) void {
    var sum: f32 = 0;
    for (vec) |v| sum += v * v;
    const norm = @sqrt(sum);
    if (norm == 0) return;
    for (vec) |*v| v.* /= norm;
}

pub fn cosine(a: []const f32, b: []const f32) f32 {
    const len = @min(a.len, b.len);
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (0..len) |i| {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    const denom = @sqrt(na * nb);
    if (denom == 0) return 0;
    return dot / denom;
}

test "parseEmbeddingValues reads float array" {
    const allocator = std.testing.allocator;
    const json = "{\"embedding\":{\"values\":[0.5,-0.25,1.0]}}";
    const values = try parseEmbeddingValues(allocator, json);
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), values[0], 0.001);
}

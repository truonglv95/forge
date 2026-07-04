const std = @import("std");
const kernel = @import("forge-kernel");
const provider = @import("provider.zig");
const gemini_tools = @import("gemini_tools.zig");
const tool_executor = @import("tool_executor.zig");
const context = @import("context.zig");
const gemini_provider = @import("gemini_provider.zig");

pub const StepCallback = *const fn (?*anyopaque, u32, []const u8, []const u8) void;

pub const ExploreConfig = struct {
    max_tool_steps: u32 = 6,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    step_callback: ?StepCallback = null,
    step_context: ?*anyopaque = null,
};

pub const ExploreError = error{
    Cancelled,
    ProviderFailed,
    StepLimitReached,
} || tool_executor.AgentToolError;

/// LLM-native tool loop (Gemini function calling). Returns when the model stops requesting tools.
pub fn exploreWithGemini(
    allocator: std.mem.Allocator,
    io: std.Io,
    gemini: *gemini_provider.GeminiProvider,
    intent: []const u8,
    ctx_builder: *const context.ContextBuilder,
    tool_ctx: tool_executor.Context,
    config: ExploreConfig,
) ExploreError!void {
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);

    var prompt = std.Io.Writer.Allocating.init(allocator);
    defer prompt.deinit();
    prompt.writer.print(
        "You are a coding agent. Explore the workspace using tools before proposing edits.\nIntent: {s}\n\nContext summary:\n",
        .{intent},
    ) catch return error.ProviderFailed;
    for (ctx_builder.blocks.items) |block| {
        prompt.writer.print("[{s}] {s}\n", .{ @tagName(block.block_type), block.name }) catch return error.ProviderFailed;
    }
    prompt.writer.writeAll("\nCall tools as needed. When you have enough information, respond with brief text only (no tool call).\n") catch return error.ProviderFailed;

    appendUserTurn(allocator, &contents, prompt.writer.buffer[0..prompt.writer.end]) catch return error.ProviderFailed;

    var step_index: u32 = 1;
    var turn: u32 = 0;
    while (turn < config.max_tool_steps) : (turn += 1) {
        if (config.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        const response_body = fetchWithTools(gemini, allocator, io, contents.items) catch return error.ProviderFailed;
        defer allocator.free(response_body);

        var parsed = parseTurn(allocator, response_body) catch return error.ProviderFailed;
        defer parsed.deinit(allocator);

        if (parsed.function_call) |call| {
            defer {
                allocator.free(call.name);
                allocator.free(call.args_json);
            }
            if (!gemini_tools.allowedNativeTool(call.name, tool_ctx.profile)) return error.NotAllowed;

            const summary = try executeTool(allocator, tool_ctx, call);
            defer allocator.free(summary);

            if (config.step_callback) |callback| {
                callback(config.step_context, step_index, call.name, summary);
            }
            step_index += 1;

            appendModelFunctionCall(allocator, &contents, call.name, call.args_json) catch return error.ProviderFailed;
            appendFunctionResponse(allocator, &contents, call.name, summary) catch return error.ProviderFailed;
            continue;
        }

        if (parsed.text) |text| {
            allocator.free(text);
        }
        return;
    }
    return error.StepLimitReached;
}

const ParsedTurn = struct {
    function_call: ?gemini_tools.FunctionCall = null,
    text: ?[]u8 = null,

    fn deinit(self: *ParsedTurn, allocator: std.mem.Allocator) void {
        if (self.function_call) |*call| call.deinit(allocator);
        if (self.text) |text| allocator.free(text);
    }
};

fn appendUserTurn(allocator: std.mem.Allocator, contents: *std.ArrayList(u8), text: []const u8) !void {
    if (contents.items.len > 0) try contents.append(allocator, ',');
    const escaped = try jsonString(allocator, text);
    defer allocator.free(escaped);
    const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"user\",\"parts\":[{{\"text\":{s}}}]}}", .{escaped});
    defer allocator.free(piece);
    try contents.appendSlice(allocator, piece);
}

fn appendModelFunctionCall(allocator: std.mem.Allocator, contents: *std.ArrayList(u8), name: []const u8, args_json: []const u8) !void {
    if (contents.items.len > 0) try contents.append(allocator, ',');
    const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"model\",\"parts\":[{{\"functionCall\":{{\"name\":\"{s}\",\"args\":{s}}}}}]}}", .{ name, args_json });
    defer allocator.free(piece);
    try contents.appendSlice(allocator, piece);
}

fn appendFunctionResponse(allocator: std.mem.Allocator, contents: *std.ArrayList(u8), name: []const u8, result: []const u8) !void {
    if (contents.items.len > 0) try contents.append(allocator, ',');
    const escaped = try jsonString(allocator, result);
    defer allocator.free(escaped);
    const piece = try std.fmt.allocPrint(allocator, "{{\"role\":\"user\",\"parts\":[{{\"functionResponse\":{{\"name\":\"{s}\",\"response\":{{\"output\":{s}}}}}}}]}}", .{ name, escaped });
    defer allocator.free(piece);
    try contents.appendSlice(allocator, piece);
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

fn fetchWithTools(
    gemini: *gemini_provider.GeminiProvider,
    allocator: std.mem.Allocator,
    io: std.Io,
    contents_body: []const u8,
) ![]u8 {
    const endpoint = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent", .{gemini.model_name});
    defer allocator.free(endpoint);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"contents":[{s}],"tools":[{{"functionDeclarations":{s}}}],"generationConfig":{{"temperature":0.2}}}}
    , .{ contents_body, gemini_tools.function_declarations_json });
    defer allocator.free(payload);

    const api_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-goog-api-key", .value = gemini.creds.api_key },
    };

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &api_headers,
        .response_writer = &response_alloc.writer,
    }) catch return error.ProviderFailed;

    if (result.status != .ok) return error.ProviderFailed;
    return allocator.dupe(u8, response_alloc.writer.buffer[0..response_alloc.writer.end]) catch return error.ProviderFailed;
}

fn parseTurn(allocator: std.mem.Allocator, body: []const u8) !ParsedTurn {
    const Root = struct {
        candidates: ?[]struct {
            content: ?struct {
                parts: ?[]struct {
                    text: ?[]const u8 = null,
                    functionCall: ?struct {
                        name: ?[]const u8 = null,
                        args: ?std.json.Value = null,
                    } = null,
                } = null,
            } = null,
        } = null,
    };

    var parsed = try std.json.parseFromSlice(Root, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const candidates = parsed.value.candidates orelse return error.ProviderFailed;
    if (candidates.len == 0) return error.ProviderFailed;
    const content = candidates[0].content orelse return error.ProviderFailed;
    const parts = content.parts orelse return error.ProviderFailed;
    if (parts.len == 0) return error.ProviderFailed;

    for (parts) |part| {
        if (part.functionCall) |fc| {
            const name = fc.name orelse return error.ProviderFailed;
            const args_owned = if (fc.args) |args_val|
                try std.json.Stringify.valueAlloc(allocator, args_val, .{})
            else
                try allocator.dupe(u8, "{}");
            return .{
                .function_call = .{
                    .name = try allocator.dupe(u8, name),
                    .args_json = args_owned,
                },
            };
        }
    }

    for (parts) |part| {
        if (part.text) |text| {
            return .{ .text = try allocator.dupe(u8, text) };
        }
    }
    return error.ProviderFailed;
}

fn executeTool(allocator: std.mem.Allocator, tool_ctx: tool_executor.Context, call: gemini_tools.FunctionCall) ExploreError![]u8 {
    if (std.mem.eql(u8, call.name, "search")) {
        const term = gemini_tools.parseSearchTerm(allocator, call.args_json) catch return error.ProviderFailed;
        defer allocator.free(term);
        const out = tool_executor.search(tool_ctx, term) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        defer if (out.first_match_path) |path| allocator.free(path);
        return allocator.dupe(u8, out.summary) catch return error.ProviderFailed;
    }
    if (std.mem.eql(u8, call.name, "codebase_search")) {
        const query = gemini_tools.parseCodebaseQuery(allocator, call.args_json) catch return error.ProviderFailed;
        defer allocator.free(query);
        const out = tool_executor.codebaseSearch(tool_ctx, query) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        defer if (out.formatted) |formatted| allocator.free(formatted);
        if (out.formatted) |formatted| {
            return allocator.dupe(u8, formatted) catch return error.ProviderFailed;
        }
        return allocator.dupe(u8, out.summary) catch return error.ProviderFailed;
    }
    if (std.mem.eql(u8, call.name, "list_tree")) {
        const out = tool_executor.listTree(tool_ctx) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.ProviderFailed;
    }
    if (std.mem.eql(u8, call.name, "read_file")) {
        const path = gemini_tools.parseReadPath(allocator, call.args_json) catch return error.ProviderFailed;
        defer allocator.free(path);
        const out = tool_executor.readFile(tool_ctx, path) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.ProviderFailed;
    }
    if (std.mem.eql(u8, call.name, "remember")) {
        const args = gemini_tools.parseRememberArgs(allocator, call.args_json) catch return error.ProviderFailed;
        defer gemini_tools.freeRememberArgs(allocator, args);
        const out = tool_executor.remember(tool_ctx, args.content, args.kind, args.tags) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.ProviderFailed;
    }
    if (std.mem.eql(u8, call.name, "fetch_url")) {
        const url = gemini_tools.parseFetchUrl(allocator, call.args_json) catch return error.ProviderFailed;
        defer allocator.free(url);
        const out = tool_executor.fetchUrl(tool_ctx, url) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        defer if (out.content) |content| allocator.free(content);
        if (out.content) |content| {
            return allocator.dupe(u8, content) catch return error.ProviderFailed;
        }
        return allocator.dupe(u8, out.summary) catch return error.ProviderFailed;
    }
    return error.ProviderFailed;
}

fn mapTool(err: tool_executor.AgentToolError) ExploreError {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.NotAllowed => error.NotAllowed,
        else => error.ProviderFailed,
    };
}

test "jsonString escapes quotes" {
    const allocator = std.testing.allocator;
    const s = try jsonString(allocator, "say \"hi\"\n");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\\n\"", s);
}

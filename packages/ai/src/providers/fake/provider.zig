const std = @import("std");
const core_provider = @import("../../provider.zig");
const provider = @import("../../provider.zig");
const kernel = @import("forge-kernel");
const streaming = @import("../../streaming.zig");
const agent_turn = @import("../../agent/turn.zig");
const mcp_registry = @import("../../mcp_registry.zig");
const fake_transport = @import("tool_transport.zig");

pub const FakeProvider = struct {
    response: []const u8,
    plan_response: ?[]const u8 = null,
    simulated_usage: provider.TokenUsage,
    meta: provider.ModelMetadata,
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,
    tool_loop_enabled: bool = false,
    tool_loop_short: bool = false,
    context_failures_remaining: u8 = 0,

    pub fn init(response: []const u8, plan_response: ?[]const u8, tool_loop_enabled: ?bool) FakeProvider {
        return .{
            .response = response,
            .plan_response = plan_response,
            .simulated_usage = .{ .prompt_tokens = 10, .completion_tokens = 20, .total_tokens = 30 },
            .meta = .{
                .provider_name = "fake",
                .model_name = "fake-model-1",
                .context_window = 4096,
            },
            .tool_loop_enabled = tool_loop_enabled orelse false,
        };
    }

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: ?*const std.process.Environ.Map,
        options: anytype,
    ) !provider.Provider {
        _ = io;
        _ = environ_map;

        const ptr = try allocator.create(FakeProvider);
        ptr.* = .{
            .response = if (@hasField(@TypeOf(options), "fake_response")) (if (@typeInfo(@TypeOf(options.fake_response)) == .optional) options.fake_response orelse "{}" else options.fake_response) else "{}",
            .plan_response = if (@hasField(@TypeOf(options), "fake_plan_response")) options.fake_plan_response else null,
            .simulated_usage = .{ .prompt_tokens = 10, .completion_tokens = 20, .total_tokens = 30 },
            .meta = .{
                .provider_name = "fake",
                .model_name = "fake-model-1",
                .context_window = 4096,
            },
            .stream_callback = if (@hasField(@TypeOf(options), "stream_callback")) options.stream_callback else null,
            .stream_context = if (@hasField(@TypeOf(options), "stream_context")) options.stream_context else null,
            .tool_loop_enabled = if (@hasField(@TypeOf(options), "fake_tool_loop")) options.fake_tool_loop else false,
            .tool_loop_short = if (@hasField(@TypeOf(options), "fake_tool_loop_short")) options.fake_tool_loop_short else false,
            .context_failures_remaining = if (@hasField(@TypeOf(options), "fake_context_failures")) options.fake_context_failures else 0,
        };
        return ptr.providerInterface();
    }

    pub fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }

    pub fn providerInterface(self: *FakeProvider) provider.Provider {
        return .{
            .ptr = self,
            .vtable = if (self.tool_loop_enabled) &.{
                .ask = askImpl,
                .metadata = metadataImpl,
                .usage = usageImpl,
                .supports_tool_loop = supportsToolLoopImpl,
                .complete_turn = completeTurnImpl,
                .tool_declarations_json = toolDeclarationsJsonImpl,
                .append_tool_user_text = appendToolUserTextImpl,
                .append_tool_call = appendToolCallImpl,
                .append_tool_result = appendToolResultImpl,
                .deinit = deinit,
            } else &.{
                .ask = askImpl,
                .metadata = metadataImpl,
                .usage = usageImpl,
                .supports_tool_loop = provider.tool_loop_stubs.supports,
                .complete_turn = provider.tool_loop_stubs.completeTurn,
                .tool_declarations_json = provider.tool_loop_stubs.toolDeclarationsJson,
                .append_tool_user_text = provider.tool_loop_stubs.appendToolUserText,
                .append_tool_call = provider.tool_loop_stubs.appendToolCall,
                .append_tool_result = provider.tool_loop_stubs.appendToolResult,
                .deinit = deinit,
            },
        };
    }

    fn toolTransportState(self: *FakeProvider, mcp: ?*mcp_registry.Registry) fake_transport.FakeTransport {
        return .{
            .mcp = mcp,
            .short_script = self.tool_loop_short,
            .stream_callback = self.stream_callback,
            .stream_context = self.stream_context,
        };
    }

    fn askImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        images: []const core_provider.ImagePart,
        writer: *std.Io.Writer,
        cancel_token: *const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!void {
        _ = allocator;
        _ = images;
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));

        if (cancel_token.isCancelled()) return provider.ProviderError.NetworkError;

        const payload = if (std.mem.indexOf(u8, prompt, "MARKDOWN PLAN MODE") != null or std.mem.indexOf(u8, prompt, "REPAIR MODE") != null)
            self.plan_response orelse self.response
        else if (std.mem.indexOf(u8, prompt, "INTENT_CLASSIFIER_MODE") != null)
            self.response
        else
            self.response;

        try streaming.writeChunks(payload, writer, cancel_token, .{
            .on_chunk = self.stream_callback,
            .on_chunk_context = self.stream_context,
        });
    }

    fn metadataImpl(ptr: *const anyopaque) provider.ModelMetadata {
        const self: *const FakeProvider = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn usageImpl(ptr: *const anyopaque) provider.TokenUsage {
        const self: *const FakeProvider = @ptrCast(@alignCast(ptr));
        return self.simulated_usage;
    }

    fn supportsToolLoopImpl(ptr: *const anyopaque) bool {
        const self: *const FakeProvider = @ptrCast(@alignCast(ptr));
        return self.tool_loop_enabled;
    }

    fn completeTurnImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        mcp: ?*mcp_registry.Registry,
        conversation_json: []const u8,
        tool_declarations_json: []const u8,
        cancel_token: ?*const kernel.cancellation.CancellationToken,
    ) provider.ProviderError!agent_turn.Completion {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        if (self.context_failures_remaining > 0) {
            self.context_failures_remaining -= 1;
            return error.ContextLengthExceeded;
        }
        var transport_state = self.toolTransportState(mcp);
        return transport_state.transport().complete(allocator, conversation_json, tool_declarations_json, cancel_token) catch |err| return provider.mapTransportError(err);
    }

    fn toolDeclarationsJsonImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        mcp: ?*mcp_registry.Registry,
    ) provider.ProviderError![]const u8 {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        const transport_state = self.toolTransportState(mcp);
        return transport_state.declarationsJson(allocator) catch return error.ProviderInternalError;
    }

    fn appendToolUserTextImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        text: []const u8,
    ) provider.ProviderError!void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(null);
        return transport_state.transport().appendUserText(allocator, conversation, text) catch |err| return provider.mapTransportError(err);
    }

    fn appendToolCallImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        call: agent_turn.ToolCall,
    ) provider.ProviderError!void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(null);
        return transport_state.transport().appendToolCall(allocator, conversation, call) catch |err| return provider.mapTransportError(err);
    }

    fn appendToolResultImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        conversation: *std.ArrayList(u8),
        tool_name: []const u8,
        result: []const u8,
        images: []const core_provider.ImagePart,
    ) provider.ProviderError!void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        var transport_state = self.toolTransportState(null);
        return transport_state.transport().appendToolResult(allocator, conversation, tool_name, result, images) catch |err| return provider.mapTransportError(err);
    }
};

test "FakeProvider honours cancellation while streaming" {
    var fba_buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
    const allocator = fba.allocator();

    var p = try FakeProvider.create(allocator, std.testing.io, null, .{
        .fake_response = "0123456789012345678901234567890",
    });
    defer p.deinit(allocator);

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    cancel_src.cancel();

    try std.testing.expectError(provider.ProviderError.NetworkError, p.ask(allocator, "hi", &.{}, &w_alloc.writer, &cancel_src.getToken()));
}

test "FakeProvider implements Provider interface correctly" {
    var fba_buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
    const allocator = fba.allocator();

    var p = try FakeProvider.create(allocator, std.testing.io, null, .{
        .fake_response = "Hello, world!",
    });
    defer p.deinit(allocator);

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    const token = cancel_src.getToken();

    try p.ask(allocator, "Say hi", &.{}, &w_alloc.writer, &token);

    const out_items = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expectEqualStrings("Hello, world!", out_items);

    const meta = p.metadata();
    try std.testing.expectEqualStrings("fake", meta.provider_name);
    try std.testing.expect(!p.supportsToolLoop());
}

test "FakeProvider tool loop returns search then text" {
    const allocator = std.testing.allocator;
    var p = try FakeProvider.create(allocator, std.testing.io, null, .{
        .fake_response = "{}",
        .fake_tool_loop = true,
    });
    defer p.deinit(allocator);
    try std.testing.expect(p.supportsToolLoop());

    var binding = p.toolLoopBinding(std.testing.io, null, null);

    const declarations = try p.toolDeclarationsJson(allocator, null);
    defer allocator.free(declarations);
    try std.testing.expect(std.mem.indexOf(u8, declarations, "\"name\":\"search\"") != null);

    var first = try binding.transport().complete(allocator, "", declarations, null);
    defer first.deinit(allocator);
    try std.testing.expect(first == .tool_call);
    try std.testing.expectEqualStrings("search", first.tool_call.name);

    const call_copy = agent_turn.ToolCall{
        .name = try allocator.dupe(u8, first.tool_call.name),
        .args_json = try allocator.dupe(u8, first.tool_call.args_json),
    };
    defer {
        allocator.free(call_copy.name);
        allocator.free(call_copy.args_json);
    }

    var conversation: std.ArrayList(u8) = .empty;
    defer conversation.deinit(allocator);
    try binding.transport().appendUserText(allocator, &conversation, "explore");
    try binding.transport().appendToolCall(allocator, &conversation, call_copy);
    try binding.transport().appendToolResult(allocator, &conversation, call_copy.name, "found sample.txt", &.{});

    var second = try binding.transport().complete(allocator, conversation.items, declarations, null);
    defer second.deinit(allocator);
    try std.testing.expect(second == .tool_call);
    try std.testing.expectEqualStrings("list_tree", second.tool_call.name);

    const tree_copy = agent_turn.ToolCall{
        .name = try allocator.dupe(u8, second.tool_call.name),
        .args_json = try allocator.dupe(u8, second.tool_call.args_json),
    };
    defer {
        allocator.free(tree_copy.name);
        allocator.free(tree_copy.args_json);
    }
    try binding.transport().appendToolCall(allocator, &conversation, tree_copy);
    try binding.transport().appendToolResult(allocator, &conversation, tree_copy.name, "tree listed", &.{});

    var third = try binding.transport().complete(allocator, conversation.items, declarations, null);
    defer third.deinit(allocator);
    try std.testing.expect(third == .text);
    try std.testing.expectEqualStrings("Exploration complete.", third.text);
}

test "FakeProvider tool loop honours cancellation" {
    const allocator = std.testing.allocator;
    var p = try FakeProvider.create(allocator, std.testing.io, null, .{
        .fake_response = "{}",
        .fake_tool_loop = true,
    });
    defer p.deinit(allocator);

    var binding = p.toolLoopBinding(std.testing.io, null, null);

    const declarations = try p.toolDeclarationsJson(allocator, null);
    defer allocator.free(declarations);

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    cancel_src.cancel();

    try std.testing.expectError(agent_turn.TransportError.Cancelled, binding.transport().complete(allocator, "", declarations, &cancel_src.getToken()));
}

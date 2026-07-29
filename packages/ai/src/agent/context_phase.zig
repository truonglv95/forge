const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const context = @import("../context.zig");
const context_loader = @import("../context_loader.zig");
const context_budget = @import("../context_budget.zig");
const provider = @import("../provider.zig");
const route_resolver = @import("../route_resolver.zig");
const routing = @import("../routing.zig");

pub const Input = struct {
    route: routing.RouteInput,
    load: context_loader.LoadOptions,
    provider: ?provider.Provider = null,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    resolver: route_resolver.Options = .{},
    budget_tier: context_budget.BudgetTier = .full,
    task_ledger_json: []const u8 = "",
};

pub const ResolvedContext = struct {
    route: route_resolver.Result,
    builder: context.ContextBuilder,
    routing_ms: i64 = 0,
    retrieval_ms: i64 = 0,

    pub fn deinit(self: *ResolvedContext) void {
        self.builder.deinit();
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    input: Input,
) !ResolvedContext {
    const routing_start = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const resolved = route_resolver.resolve(
        allocator,
        input.route,
        input.load,
        input.provider,
        input.cancel_token,
        input.resolver,
    );
    const routing_end = std.Io.Timestamp.now(io, .real).toMilliseconds();

    var load_options = context_budget.applyLedger(
        allocator,
        resolved.context_plan.options,
        input.budget_tier,
        resolved.intent,
        input.task_ledger_json,
    );

    var hyde_ctx = if (input.provider) |prov| HydeContext{
        .provider = prov,
        .io = io,
        .cancel_token = input.cancel_token,
    } else null;

    if (hyde_ctx) |*hc| {
        load_options.hyde_text_generator = hydeTextGenerator;
        load_options.hyde_text_generator_ctx = hc;
    }

    const retrieval_start = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var builder = try context_loader.build(allocator, io, root, load_options);
    const retrieval_end = std.Io.Timestamp.now(io, .real).toMilliseconds();
    errdefer builder.deinit();

    var routing_buf: [160]u8 = undefined;
    const summary = route_resolver.formatSummary(&routing_buf, input.route, resolved);
    try builder.addBlock(.intent, "routing", summary);

    return .{
        .route = resolved,
        .builder = builder,
        .routing_ms = millisDelta(routing_start, routing_end),
        .retrieval_ms = millisDelta(retrieval_start, retrieval_end),
    };
}

fn millisDelta(start_ms: i64, end_ms: i64) i64 {
    return if (end_ms >= start_ms) end_ms - start_ms else 0;
}

const HydeContext = struct {
    provider: provider.Provider,
    io: std.Io,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
};

fn hydeTextGenerator(allocator: std.mem.Allocator, ctx_opaque: ?*anyopaque, prompt: []const u8) anyerror![]u8 {
    const ctx = @as(*HydeContext, @ptrCast(@alignCast(ctx_opaque.?)));

    const Message = struct { role: []const u8, content: []const u8 };
    const messages = [_]Message{.{ .role = "user", .content = prompt }};
    const conversation = try std.json.Stringify.valueAlloc(allocator, messages, .{});
    defer allocator.free(conversation);

    var completion = try ctx.provider.completeTurn(
        allocator,
        ctx.io,
        null,
        conversation,
        "[]",
        ctx.cancel_token,
    );
    defer completion.deinit(allocator);

    switch (completion) {
        .text => |text| return allocator.dupe(u8, text),
        else => return error.UnexpectedToolCall,
    }
}

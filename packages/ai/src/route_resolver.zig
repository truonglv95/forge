const std = @import("std");
const kernel = @import("forge-kernel");
const context_loader = @import("context_loader.zig");
const context_plan = @import("context_plan.zig");
const intent_classifier = @import("intent_classifier.zig");
const provider = @import("provider.zig");
const routing = @import("routing.zig");

pub const Options = struct {
    use_llm: bool = true,
    classifier: intent_classifier.Options = .{},
};

pub const Result = struct {
    route: routing.RoutePlan,
    context_plan: context_plan.ContextPlan,
    intent: routing.TaskIntent,
    used_llm: bool,
};

pub fn resolve(
    allocator: std.mem.Allocator,
    input: routing.RouteInput,
    base: context_loader.LoadOptions,
    llm: ?provider.Provider,
    cancel_token: ?*const kernel.cancellation.CancellationToken,
    options: Options,
) Result {
    const resolved = if (options.use_llm) blk: {
        if (llm) |model| {
            break :blk intent_classifier.resolveIntent(
                allocator,
                input,
                model,
                cancel_token,
                options.classifier,
            );
        }
        break :blk intent_classifier.ResolveResult{ .intent = routing.classify(input), .used_llm = false };
    } else intent_classifier.ResolveResult{ .intent = routing.classify(input), .used_llm = false };

    const route = routing.planWithIntent(resolved.intent, input, base);
    return .{
        .route = route,
        .context_plan = context_plan.fromRoute(route, resolved.used_llm),
        .intent = resolved.intent,
        .used_llm = resolved.used_llm,
    };
}

pub fn resolveHeuristic(input: routing.RouteInput, base: context_loader.LoadOptions) Result {
    const intent = routing.classify(input);
    const route = routing.planWithIntent(intent, input, base);
    return .{
        .route = route,
        .context_plan = context_plan.fromRoute(route, false),
        .intent = intent,
        .used_llm = false,
    };
}

pub fn formatSummary(buf: []u8, input: routing.RouteInput, result: Result) []const u8 {
    return std.fmt.bufPrint(buf, "mode={s} task={s} profile={s}{s}", .{
        @tagName(input.mode),
        routing.intentLabel(result.route.intent),
        @tagName(result.route.capability_profile),
        if (result.used_llm) " classifier=llm" else "",
    }) catch "mode=unknown task=unknown profile=unknown";
}

test "resolveHeuristic mirrors routing plan" {
    const result = resolveHeuristic(.{ .mode = .agent, .intent = "tensor.py lam gi" }, .{});
    try std.testing.expectEqual(routing.TaskIntent.explore_codebase, result.intent);
    try std.testing.expectEqual(routing.TaskIntent.explore_codebase, result.route.intent);
}

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
    const resolved = route_resolver.resolve(
        allocator,
        input.route,
        input.load,
        input.provider,
        input.cancel_token,
        input.resolver,
    );

    const load_options = context_budget.applyLedger(
        allocator,
        resolved.context_plan.options,
        input.budget_tier,
        resolved.intent,
        input.task_ledger_json,
    );
    var builder = try context_loader.build(allocator, io, root, load_options);
    errdefer builder.deinit();

    var routing_buf: [160]u8 = undefined;
    const summary = route_resolver.formatSummary(&routing_buf, input.route, resolved);
    try builder.addBlock(.intent, "routing", summary);

    return .{
        .route = resolved,
        .builder = builder,
    };
}

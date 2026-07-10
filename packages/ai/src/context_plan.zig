const context_loader = @import("context_loader.zig");
const routing = @import("routing.zig");
const tools = @import("tools.zig");

pub const ContextPlan = struct {
    intent: routing.TaskIntent,
    capability_profile: tools.CapabilityProfile,
    options: context_loader.LoadOptions,
    classifier_used_llm: bool = false,
};

pub fn fromRoute(route: routing.RoutePlan, used_llm: bool) ContextPlan {
    return .{
        .intent = route.intent,
        .capability_profile = route.capability_profile,
        .options = route.context,
        .classifier_used_llm = used_llm,
    };
}

pub fn toolProfile(plan: ContextPlan) tools.CapabilityProfile {
    return plan.capability_profile;
}

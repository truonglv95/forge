//! AI proposal contracts. Providers and context construction begin in M4.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.ai;

pub const provider = @import("provider.zig");
pub const fake_provider = @import("fake_provider.zig");
pub const gemini_provider = @import("gemini_provider.zig");
pub const credentials = @import("credentials.zig");
pub const provider_factory = @import("provider_factory.zig");
pub const retry = @import("retry.zig");
pub const secret_scanner = @import("secret_scanner.zig");
pub const context = @import("context.zig");
pub const context_loader = @import("context_loader.zig");
pub const planner = @import("planner.zig");
pub const run_record = @import("run_record.zig");

pub const ProposalStatus = enum {
    draft,
    ready_for_review,
    approved,
    rejected,
    applied,
    stale,
};

pub fn mayApply(status: ProposalStatus) bool {
    return status == .approved;
}

test "only approved proposals may be applied" {
    try std.testing.expect(mayApply(.approved));
    try std.testing.expect(!mayApply(.draft));
    try std.testing.expect(!mayApply(.stale));
}

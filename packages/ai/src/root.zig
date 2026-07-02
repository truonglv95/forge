//! AI proposal contracts. Providers and context construction begin in M4.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.ai;

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

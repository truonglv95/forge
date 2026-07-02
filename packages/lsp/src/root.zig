//! Language server lifecycle contracts. JSON-RPC transport begins in M3.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.lsp;

pub const ServerState = enum {
    stopped,
    starting,
    ready,
    stopping,
    crashed,
};

pub fn acceptsRequests(state: ServerState) bool {
    return state == .ready;
}

test "only a ready language server accepts requests" {
    try std.testing.expect(acceptsRequests(.ready));
    try std.testing.expect(!acceptsRequests(.starting));
    try std.testing.expect(!acceptsRequests(.crashed));
}

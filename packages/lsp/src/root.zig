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
    configured,
};

pub const registry = @import("registry.zig");
pub const Registry = registry.Registry;
pub const ServerConfig = registry.ServerConfig;
pub const jsonrpc = @import("jsonrpc.zig");
pub const session = @import("session.zig");
pub const Session = session.Session;
pub const proxy = @import("proxy.zig");
pub const Proxy = proxy.Proxy;
pub const diagnostics = @import("diagnostics.zig");
pub const completion = @import("completion.zig");
pub const navigation = @import("navigation.zig");
pub const hover = @import("hover.zig");
pub const references = @import("references.zig");
pub const rename = @import("rename.zig");
pub const format = @import("format.zig");
pub const code_action = @import("code_action.zig");
pub const sync = @import("sync.zig");

pub fn acceptsRequests(state: ServerState) bool {
    return state == .ready;
}

test "only a ready language server accepts requests" {
    try std.testing.expect(acceptsRequests(.ready));
    try std.testing.expect(!acceptsRequests(.starting));
    try std.testing.expect(!acceptsRequests(.crashed));
}

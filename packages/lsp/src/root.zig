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
pub const workspace_symbol = @import("workspace_symbol.zig");
pub const semantic_tokens = @import("semantic_tokens.zig");
pub const dap_client = @import("dap_client.zig");
pub const DapClient = dap_client.DapClient;
pub const signature_help = @import("signature_help.zig");
pub const SignatureHelp = signature_help.SignatureHelp;
pub const document_highlight = @import("document_highlight.zig");
pub const folding_range = @import("folding_range.zig");
pub const inlay_hints = @import("inlay_hints.zig");
pub const cancel_request = @import("cancel_request.zig");
pub const snippet = @import("snippet.zig");

pub fn acceptsRequests(state: ServerState) bool {
    return state == .ready;
}

test "only a ready language server accepts requests" {
    try std.testing.expect(acceptsRequests(.ready));
    try std.testing.expect(!acceptsRequests(.starting));
    try std.testing.expect(!acceptsRequests(.crashed));
}

test {
    _ = @import("lsp_test.zig");
}

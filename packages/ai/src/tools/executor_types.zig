const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const tools = @import("../tools.zig");
const tool_cache_mod = @import("../tool_cache.zig");

pub const ToolCache = tool_cache_mod.Cache;

pub const AgentToolError = error{
    Cancelled,
    NotAllowed,
    WorkspaceFailed,
    TaskFailed,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    cwd: []const u8,
    profile: tools.CapabilityProfile,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    environ_map: ?*const std.process.Environ.Map = null,
    edit_callback: ?*const fn (?*anyopaque, edit: workspace.edit.WorkspaceEdit) void = null,
    edit_context: ?*anyopaque = null,
    direct_apply_edits: bool = false,
    lsp_request_callback: ?*const fn (?*anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ?[]const u8 = null,
    lsp_context: ?*anyopaque = null,
    editor_context_callback: ?*const fn (?*anyopaque, std.mem.Allocator) ?[]const u8 = null,
    editor_context: ?*anyopaque = null,
    cache: ?*tool_cache_mod.Cache = null,
    extra_allowed_commands: []const []const u8 = &.{},
    stream_callback: ?*const fn (?*anyopaque, []const u8) void = null,
    stream_context: ?*anyopaque = null,
    wasm_run_callback: ?*const fn (?*anyopaque, allocator: std.mem.Allocator, wasm_file: []const u8, args: [][]const u8) AgentToolError![]const u8 = null,
    wasm_run_context: ?*anyopaque = null,
    enable_hyde: bool = false,
};

pub const Outcome = struct {
    summary: []const u8,
};

pub const SearchOutcome = struct {
    summary: []const u8,
    first_match_path: ?[]const u8,
    observation: []const u8,
};

pub const CodebaseSearchOutcome = struct {
    summary: []const u8,
    formatted: ?[]const u8,
};

pub fn checkCancel(ctx: Context) AgentToolError!void {
    if (ctx.cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }
}

pub fn requireTool(ctx: Context, tool: tools.ToolId) AgentToolError!void {
    if (!tools.isAllowed(ctx.profile, tool)) return error.NotAllowed;
}

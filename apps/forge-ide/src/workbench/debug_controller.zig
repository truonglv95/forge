const std = @import("std");
const breakpoints_mod = @import("breakpoints.zig");
const debug_console_mod = @import("debug_console.zig");
const debug_lldb_session_mod = @import("debug_lldb_session.zig");
const debug_dap_session_mod = @import("debug_dap_session.zig");
const debug_variables_mod = @import("debug_variables.zig");
const debug_callstack_mod = @import("debug_callstack.zig");
const watch_expressions_mod = @import("watch_expressions.zig");
const workspace = @import("forge-workspace");
const debug_recovery_mod = @import("debug_recovery.zig");

pub const DebugController = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: workspace.WorkspaceRoot,

    breakpoints: breakpoints_mod.Store,
    watch_expressions: watch_expressions_mod.Store,
    console: debug_console_mod.DebugConsole,
    lldb: debug_lldb_session_mod.Session,
    dap: debug_dap_session_mod.Session,
    variables: debug_variables_mod.Store,
    callstack: debug_callstack_mod.Store,

    stop_path: ?[]const u8 = null,
    stop_line: ?usize = null,

    lldb_initialized: bool = false,
    dap_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_root: workspace.WorkspaceRoot) !DebugController {
        var self = DebugController{
            .allocator = allocator,
            .io = io,
            .workspace_root = workspace_root,
            .breakpoints = breakpoints_mod.Store.init(allocator),
            .watch_expressions = watch_expressions_mod.Store.init(allocator),
            .console = debug_console_mod.DebugConsole.init(allocator, io),
            .variables = debug_variables_mod.Store.init(allocator),
            .callstack = debug_callstack_mod.Store.init(allocator),
            .lldb = undefined,
            .dap = undefined,
        };
        errdefer self.deinit();

        _ = debug_recovery_mod.recoverDebugState(allocator, io, workspace_root, &self.breakpoints, &self.watch_expressions) catch false;

        return self;
    }

    pub fn deinit(self: *DebugController) void {
        debug_recovery_mod.snapshotDebugState(self.allocator, self.io, self.workspace_root, &self.breakpoints, &self.watch_expressions) catch {};

        if (self.stop_path) |path| self.allocator.free(path);
        self.variables.deinit();
        self.callstack.deinit();
        self.breakpoints.deinit();
        self.watch_expressions.deinit();
        self.console.deinit();
        if (self.lldb_initialized) self.lldb.deinit();
        if (self.dap_initialized) self.dap.deinit();
    }
};

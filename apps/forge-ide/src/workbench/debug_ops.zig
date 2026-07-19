const std = @import("std");
const tasks_mod = @import("tasks.zig");
const debug_variables_mod = @import("debug_variables.zig");
const debug_callstack_mod = @import("debug_callstack.zig");
const debug_stop_mod = @import("debug_stop.zig");
const Workbench = @import("../workbench.zig").Workbench;

pub fn toggleBreakpointAtCursor(wb: anytype) !void {
    const doc = wb.editor.tabs.activeDoc() orelse return;
    const row = doc.buffer.cursor.row;
    const added = try wb.debug.breakpoints.toggle(doc.path, row);
    var buf: [128]u8 = undefined;
    const msg = if (added)
        try std.fmt.bufPrint(&buf, "Breakpoint set at {s}:{d}", .{ doc.path, row + 1 })
    else
        try std.fmt.bufPrint(&buf, "Breakpoint removed at {s}:{d}", .{ doc.path, row + 1 });
    try wb.debug.console.log(msg);
    try wb.setStatus(msg);
    try wb.persistSessionState();
}

pub fn runLaunchConfig(wb: anytype, index: usize) !void {
    const panel = @import("../ui/sidebar/debug_panel.zig");
    if (index >= panel.default_launches.len) return;
    const launch = panel.default_launches[index];

    if (std.mem.eql(u8, launch.task, "debug_current")) {
        const path = wb.activeFilePath() orelse {
            try wb.setStatus("No file open for debug");
            return;
        };
        const task_out = wb.getOutputChannel("tasks").?.output;
        if (task_out.isRunning()) {
            return;
        }

        task_out.clear();
        task_out.setRunning(true);
        wb.debug.console.clear();
        clearDebugStop(wb);
        clearDebugInspect(wb);
        try wb.debug.console.log("Starting DAP debug session (lldb-dap)…");
        try wb.debug.dap.start(
            wb.allocator,
            wb.workspace_path,
            path,
            &wb.debug.breakpoints,
            onDebugLine,
            onDebugLldbFinished,
            wb,
        );
        wb.bottom_panel_mode = .debug_console;
        wb.focused_panel = .run;
        try wb.setStatus("Debug session started");
        return;
    }

    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Launch: {s}", .{launch.label});
    try wb.debug.console.log(msg);
    const task_out = wb.getOutputChannel("tasks").?.output;
    if (task_out.isRunning()) {
        return;
    }

    task_out.clear();
    task_out.setRunning(true);
    try tasks_mod.spawn(
        wb.allocator,
        wb.io,
        launch.task,
        wb.workspace_path,
        @TypeOf(wb.*).onTaskLine,
        @TypeOf(wb.*).onTaskFinished,
        wb,
    );
    wb.bottom_panel_mode = .debug_console;
    wb.focused_panel = .run;
}

pub fn onDebugLine(context: ?*anyopaque, line: []const u8) void {
    const wb: *Workbench = @ptrCast(@alignCast(context));
    wb.debug.console.log(line) catch {};
    if (debug_variables_mod.parseVariableLine(line)) |parsed| {
        wb.debug.variables.addParsed(parsed) catch {};
        wb.bottom_panel_mode = .debug_variables;
    }
    if (debug_callstack_mod.parseFrameLine(line)) |parsed| {
        wb.debug.callstack.addFrame(parsed) catch {};
        wb.bottom_panel_mode = .debug_callstack;
    }
    if (debug_stop_mod.parseStopLine(line)) |loc| {
        applyDebugStop(wb, loc.path, loc.line);
    }
}

pub fn clearDebugStop(wb: anytype) void {
    if (wb.debug.stop_path) |path| wb.allocator.free(path);
    wb.debug.stop_path = null;
    wb.debug.stop_line = null;
}

pub fn applyDebugStop(wb: anytype, parsed_path: []const u8, line: usize) void {
    for (wb.editor.tabs.tabs.items) |doc| {
        if (!debug_stop_mod.pathsMatch(doc.path, parsed_path)) continue;
        if (wb.debug.stop_path) |old| {
            if (std.mem.eql(u8, old, doc.path) and wb.debug.stop_line == line) return;
            wb.allocator.free(old);
        }
        wb.debug.stop_path = wb.allocator.dupe(u8, doc.path) catch return;
        wb.debug.stop_line = line;
        if (wb.debug.dap.isActive()) {
            wb.debug.dap.refreshBacktrace() catch {};
        } else if (wb.debug.lldb.isActive()) {
            wb.debug.lldb.refreshBacktrace() catch {};
        }
        if (wb.activeFilePath()) |active| {
            if (std.mem.eql(u8, active, doc.path)) scrollEditorToLine(wb, line);
        }
        return;
    }
}

pub fn scrollEditorToLine(wb: anytype, line: usize) void {
    if (wb.activeBuffer()) |buf| {
        buf.cursor.row = @intCast(@min(line, buf.lineCount() - 1));
        buf.cursor.col = 0;
    }
    @import("../workbench/editor_ops.zig").scrollEditorToCursor(wb);
}

pub fn clearDebugInspect(wb: anytype) void {
    wb.debug.variables.clear();
    wb.debug.callstack.clear();
}

pub fn onDebugLldbFinished(context: ?*anyopaque, exit_code: i32) void {
    const wb: *Workbench = @ptrCast(@alignCast(context));
    clearDebugStop(wb);
    clearDebugInspect(wb);
    wb.getOutputChannel("tasks").?.output.setRunning(false);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Debug session ended (exit {d})", .{exit_code}) catch "Debug session ended";
    wb.debug.console.log(msg) catch {};
    wb.setStatus(if (exit_code == 0) "Debug session ended" else "Debug failed") catch {};
}

pub fn onDebugFinished(context: ?*anyopaque, exit_code: i32) void {
    onDebugLldbFinished(context, exit_code);
}

pub fn debugContinue(wb: anytype) !void {
    if (!debugSessionActive(wb)) {
        try wb.setStatus("No active debug session");
        return;
    }
    clearDebugInspect(wb);
    if (wb.debug.dap.isActive()) {
        try wb.debug.dap.continueExecution();
    } else {
        try wb.debug.lldb.continueExecution();
    }
    try wb.setStatus("Debug: continue");
}

pub fn debugStepOver(wb: anytype) !void {
    if (!debugSessionActive(wb)) {
        try wb.setStatus("No active debug session");
        return;
    }
    clearDebugInspect(wb);
    if (wb.debug.dap.isActive()) {
        try wb.debug.dap.stepOver();
    } else {
        try wb.debug.lldb.stepOver();
    }
    try wb.setStatus("Debug: step over");
}

pub fn debugStepInto(wb: anytype) !void {
    if (!debugSessionActive(wb)) {
        try wb.setStatus("No active debug session");
        return;
    }
    clearDebugInspect(wb);
    if (wb.debug.dap.isActive()) {
        try wb.debug.dap.stepInto();
    } else {
        try wb.debug.lldb.stepInto();
    }
    try wb.setStatus("Debug: step into");
}

pub fn debugStepOut(wb: anytype) !void {
    if (!debugSessionActive(wb)) {
        try wb.setStatus("No active debug session");
        return;
    }
    clearDebugInspect(wb);
    if (wb.debug.dap.isActive()) {
        try wb.debug.dap.stepOut();
    } else {
        try wb.debug.lldb.stepOut();
    }
    try wb.setStatus("Debug: step out");
}

pub fn debugStop(wb: anytype) void {
    if (wb.debug.dap.isActive()) {
        wb.debug.dap.stop();
    } else if (wb.debug.lldb.isActive()) {
        wb.debug.lldb.stop();
    } else return;
    clearDebugStop(wb);
    clearDebugInspect(wb);
    wb.getOutputChannel("tasks").?.output.setRunning(false);
    wb.debug.console.log("Debug session stopped") catch {};
}

pub fn handleDebugClick(wb: anytype, hit: @import("../ui/sidebar/debug_panel.zig").Hit) !void {
    switch (hit) {
        .run_launch => |index| try wb.dispatch(.{ .debug_run_launch = index }),
        .toggle_breakpoint => try wb.dispatch(.debug_toggle_breakpoint),
        .clear_breakpoints => try wb.dispatch(.debug_clear_breakpoints),
        .debug_control => |control| switch (control) {
            .continue_exec => try wb.dispatch(.debug_continue),
            .step_over => try wb.dispatch(.debug_step_over),
            .step_into => try wb.dispatch(.debug_step_into),
            .step_out => try wb.dispatch(.debug_step_out),
            .stop => wb.dispatch(.debug_stop) catch {},
        },
    }
}

/// Returns true if either the DAP session or the legacy LLDB session is
/// currently active. The DAP session is preferred when both are running
/// (which shouldn't happen in practice, but defensive code is good).
pub fn debugSessionActive(wb: anytype) bool {
    return wb.debug.dap.isActive() or wb.debug.lldb.isActive();
}

pub fn copyDebugVariable(wb: anytype, index: usize) !void {
    if (index >= wb.debug.variables.items.items.len) return;
    const entry = wb.debug.variables.items.items[index];
    @import("forge-renderer").Renderer.setClipboardText(entry.value);
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Copied {s}", .{entry.name}) catch "Copied value";
    try wb.setStatus(msg);
}

pub fn gotoDebugStackFrame(wb: anytype, index: usize) !void {
    if (index >= wb.debug.callstack.items.items.len) return;
    const frame = wb.debug.callstack.items.items[index];
    for (wb.editor.tabs.tabs.items) |doc| {
        if (!debug_stop_mod.pathsMatch(doc.path, frame.path)) continue;
        for (wb.editor.tabs.tabs.items, 0..) |_, tab_index| {
            if (std.mem.eql(u8, wb.editor.tabs.tabs.items[tab_index].path, doc.path)) {
                try wb.activateTab(tab_index);
                break;
            }
        }
        applyDebugStop(wb, doc.path, frame.line);
        try wb.setStatus("Jumped to stack frame");
        return;
    }
    try wb.setStatus("Stack frame file not open");
}

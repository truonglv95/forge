const std = @import("std");
const workspace = @import("forge-workspace");
const ai = @import("forge-ai");
const ai_config_io = @import("ai_config_io.zig");

pub fn resolveWorkbenchHome(environ_map: ?*const std.process.Environ.Map) ?[]const u8 {
    if (environ_map) |map| return map.get("HOME");
    return null;
}

pub fn refreshAiMcpStatus(wb: anytype) !void {
    if (wb.ai_mcp_status) |old| wb.allocator.free(old);
    wb.ai_mcp_status = null;

    if (!wb.agent_ui.mcp_enabled) {
        wb.ai_mcp_status = try wb.allocator.dupe(u8, "MCP disabled in forge.toml ([ai] mcp = false)");
        return;
    }

    const registry = ai.mcp_registry.Registry.load(
        wb.allocator,
        wb.io,
        wb.workspace_root,
        wb.workspace_path,
        true,
        resolveWorkbenchHome(wb.environ_map),
        wb.environ_map,
    ) catch |err| {
        const msg = try std.fmt.allocPrint(wb.allocator, "MCP load failed: {}", .{err});
        wb.ai_mcp_status = msg;
        return;
    };
    if (wb.ai_mcp_registry) |*reg| reg.deinit();
    wb.ai_mcp_registry = registry;
    wb.ai_mcp_status = try wb.allocator.dupe(u8, registry.status_lines);
}

pub fn toggleAiMcp(wb: anytype) !void {
    const next = !wb.agent_ui.mcp_enabled;
    try ai_config_io.writeAiMcp(wb.allocator, wb.io, wb.workspace_root, next);
    wb.agent_ui.mcp_enabled = next;
    try refreshAiMcpStatus(wb);
    try wb.setStatus(if (next) "MCP tools enabled" else "MCP tools disabled");
}

pub fn openMcpConfig(wb: anytype) !void {
    try ensureMcpConfigFile(wb);
    const candidates = [_][]const u8{ ".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json" };
    for (candidates) |rel| {
        const wp = workspace.WorkspacePath.parse(rel) catch continue;
        var snap = workspace.FileSnapshot.read(wb.allocator, wb.io, wb.workspace_root, wp) catch continue;
        snap.deinit();
        try wb.openFile(rel);
        return;
    }
    try wb.openFile(".mcp.json");
}

pub fn ensureMcpConfigFile(wb: anytype) !void {
    const target = try workspace.WorkspacePath.parse(".mcp.json");
    if (workspace.FileSnapshot.read(wb.allocator, wb.io, wb.workspace_root, target)) |snap| {
        var owned = snap;
        owned.deinit();
        return;
    } else |_| {}

    const example = try workspace.WorkspacePath.parse(".mcp.json.example");
    var example_snap = try workspace.FileSnapshot.read(wb.allocator, wb.io, wb.workspace_root, example);
    defer example_snap.deinit();
    try workspace.atomic.replaceFile(wb.io, wb.workspace_root, target, example_snap.content);
}

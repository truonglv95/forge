const std = @import("std");
const plugin = @import("forge-plugin");
const state = @import("../ui/core/state.zig");

pub fn hostCallbacks() plugin.wasm_runtime.HostCallbacks {
    return .{
        .log = wasmLog,
        .set_status = wasmSetStatus,
        .lsp_language_for_file = lspLanguageForFile,
        .lsp_request = lspRequest,
    };
}

fn wasmLog(message: []const u8) void {
    std.debug.print("[wasm ext] {s}\n", .{message});
}

fn wasmSetStatus(message: []const u8) void {
    state.StatusBridge.setStatus(message);
}

fn lspLanguageForFile(path: []const u8, out: []u8) ?usize {
    const wb = state.wb orelse return null;
    wb.lsp.registry.mutex.lock();
    defer wb.lsp.registry.mutex.unlock();
    const server = wb.lsp.registry.findForPathUnlocked(path) orelse return null;
    if (server.language_id.len > out.len) return null;
    @memcpy(out[0..server.language_id.len], server.language_id);
    return server.language_id.len;
}

fn lspRequest(
    language_id: []const u8,
    request_json: []const u8,
    response_out: []u8,
    limits: plugin.WasmLimits,
) ?usize {
    const wb = state.wb orelse return null;
    return wb.lsp.proxy.request(
        language_id,
        request_json,
        response_out,
        limits.max_lsp_request_bytes,
    ) catch null;
}

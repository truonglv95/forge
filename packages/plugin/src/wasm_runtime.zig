const std = @import("std");
const zware = @import("zware");
const workspace = @import("forge-workspace");

pub const RuntimeKind = enum {
    native,
    builtin,
    wasm,
};

pub const Limits = struct {
    max_memory_bytes: u32 = 1048576,
    max_string_len: u32 = 4096,
    max_read_bytes: u32 = 16384,
    max_path_len: u32 = 512,
    max_lsp_request_bytes: u32 = 8192,
    max_lsp_response_bytes: u32 = 16384,
};

const manifest_mod = @import("manifest.zig");

pub const HostCallbacks = struct {
    log: *const fn (message: []const u8) void,
    set_status: *const fn (message: []const u8) void,
    lsp_language_for_file: ?*const fn (path: []const u8, out: []u8) ?usize = null,
    lsp_request: ?*const fn (language_id: []const u8, request_json: []const u8, response_out: []u8, limits: Limits) ?usize = null,
};

pub const RuntimeEnv = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: workspace.WorkspaceRoot,
    extension_root: []const u8,
    limits: Limits,
    callbacks: HostCallbacks,
};

pub const WasmInstance = struct {
    store: zware.Store,
    instance: zware.Instance,
    wasm_bytes: []u8,
    memory_idx: usize,
    env: RuntimeEnv,

    pub fn deinit(self: *WasmInstance, allocator: std.mem.Allocator) void {
        self.instance.deinit();
        self.instance.module.deinit();
        self.store.deinit();
        allocator.free(self.wasm_bytes);
        allocator.free(self.env.extension_root);
        allocator.destroy(self);
    }
};

pub const WasmRuntime = struct {
    pub const Error = error{
        WasmModuleMissing,
        WasmLoadFailed,
        WasmInstantiateFailed,
        WasmExportMissing,
        WasmInvokeFailed,
        WasmMemoryMissing,
        WasmMemoryLimitExceeded,
        OutOfMemory,
    };

    pub fn loadAndActivate(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: workspace.WorkspaceRoot,
        extension_root: []const u8,
        entry_rel: []const u8,
        callbacks: HostCallbacks,
        limits: Limits,
    ) Error!*WasmInstance {
        const wasm_rel = if (entry_rel.len > 0) entry_rel else "main.wasm";
        const wasm_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extension_root, wasm_rel });
        defer allocator.free(wasm_path);

        const wp = workspace.WorkspacePath.parse(wasm_path) catch return error.WasmModuleMissing;
        var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return error.WasmModuleMissing;
        defer snap.deinit();

        const wasm_bytes = try allocator.dupe(u8, snap.content);
        const ext_root_owned = try allocator.dupe(u8, extension_root);

        const guest = try allocator.create(WasmInstance);
        guest.* = .{
            .store = zware.Store.init(allocator),
            .instance = undefined,
            .wasm_bytes = wasm_bytes,
            .memory_idx = 0,
            .env = .{
                .allocator = allocator,
                .io = io,
                .workspace_root = root,
                .extension_root = ext_root_owned,
                .limits = limits,
                .callbacks = callbacks,
            },
        };

        var instance_ready = false;
        errdefer {
            if (instance_ready) {
                guest.instance.deinit();
                guest.instance.module.deinit();
            }
            guest.store.deinit();
            allocator.free(guest.wasm_bytes);
            allocator.free(guest.env.extension_root);
            allocator.destroy(guest);
        }

        try linkForgeHost(guest);

        var module = zware.Module.init(allocator, guest.wasm_bytes);
        module.decode() catch {
            module.deinit();
            return error.WasmLoadFailed;
        };
        validateModuleMemory(&module, limits) catch |err| {
            module.deinit();
            return err;
        };
        guest.instance = zware.Instance.init(allocator, &guest.store, module);
        guest.instance.instantiate() catch return error.WasmInstantiateFailed;
        instance_ready = true;

        guest.memory_idx = guest.instance.module.getExport(.Mem, "memory") catch return error.WasmMemoryMissing;

        guest.instance.invoke("forge_activate", &[_]u64{}, &[_]u64{}, .{}) catch return error.WasmInvokeFailed;
        return guest;
    }

    pub fn deactivate(guest: *WasmInstance) void {
        guest.instance.invoke("forge_deactivate", &[_]u64{}, &[_]u64{}, .{}) catch {};
    }

    pub fn executeCommand(guest: *WasmInstance, command_id: []const u8) Error!void {
        if (command_id.len > guest.env.limits.max_string_len) return error.WasmInvokeFailed;
        const ptr = try writeGuestString(guest, command_id);

        var in = [_]u64{ ptr, @as(u64, command_id.len) };
        guest.instance.invoke("forge_execute_command", &in, &[_]u64{}, .{}) catch return error.WasmInvokeFailed;
    }

    fn validateModuleMemory(module: *const zware.Module, limits: Limits) Error!void {
        if (module.memories.list.items.len == 0) return;
        const memdef = module.memories.list.items[0];
        const min_bytes = @as(u64, memdef.limits.min) * 65536;
        if (min_bytes > limits.max_memory_bytes) return error.WasmMemoryLimitExceeded;
        if (memdef.limits.max) |max_pages| {
            const max_bytes = @as(u64, max_pages) * 65536;
            if (max_bytes > limits.max_memory_bytes) return error.WasmMemoryLimitExceeded;
        }
    }

    fn linkForgeHost(guest: *WasmInstance) Error!void {
        const context = @intFromPtr(guest);
        const i32_pair = [_]zware.ValType{ .I32, .I32 };
        const i32_quad = [_]zware.ValType{ .I32, .I32, .I32, .I32 };
        const no_results = [_]zware.ValType{};
        const i32_result = [_]zware.ValType{.I32};

        try guest.store.exposeHostFunction("forge_host", "forge_host_log", hostLog, context, &i32_pair, &no_results);
        try guest.store.exposeHostFunction("forge_host", "forge_host_set_status", hostSetStatus, context, &i32_pair, &no_results);
        try guest.store.exposeHostFunction("forge_host", "forge_host_read_file", hostReadFile, context, &i32_quad, &i32_result);
        try guest.store.exposeHostFunction("forge_host", "forge_host_lsp_for_file", hostLspForFile, context, &i32_quad, &i32_result);
        try guest.store.exposeHostFunction("forge_host", "forge_host_lsp_request", hostLspRequest, context, &[_]zware.ValType{ .I32, .I32, .I32, .I32, .I32, .I32 }, &i32_result);
    }

    fn hostLog(vm: *zware.VirtualMachine, context: usize) zware.WasmError!void {
        const guest: *WasmInstance = @ptrFromInt(context);
        const len: u32 = @truncate(vm.popOperand(u64));
        const ptr: u32 = @truncate(vm.popOperand(u64));
        if (readGuestString(guest, ptr, len)) |message| {
            guest.env.callbacks.log(message);
        }
    }

    fn hostSetStatus(vm: *zware.VirtualMachine, context: usize) zware.WasmError!void {
        const guest: *WasmInstance = @ptrFromInt(context);
        const len: u32 = @truncate(vm.popOperand(u64));
        const ptr: u32 = @truncate(vm.popOperand(u64));
        if (readGuestString(guest, ptr, len)) |message| {
            guest.env.callbacks.set_status(message);
        }
    }

    fn hostReadFile(vm: *zware.VirtualMachine, context: usize) zware.WasmError!void {
        const guest: *WasmInstance = @ptrFromInt(context);
        const buf_cap: u32 = @truncate(vm.popOperand(u64));
        const buf_ptr: u32 = @truncate(vm.popOperand(u64));
        const path_len: u32 = @truncate(vm.popOperand(u64));
        const path_ptr: u32 = @truncate(vm.popOperand(u64));

        const result: i32 = blk: {
            const path = readGuestString(guest, path_ptr, path_len) orelse break :blk -1;
            if (!isSafeWorkspacePath(path, guest.env.limits.max_path_len)) break :blk -1;

            const file_wp = workspace.WorkspacePath.parse(path) catch break :blk -1;
            var snap = workspace.FileSnapshot.read(guest.env.allocator, guest.env.io, guest.env.workspace_root, file_wp) catch break :blk -1;
            defer snap.deinit();
            if (snap.content.len > guest.env.limits.max_read_bytes) break :blk -1;

            break :blk writeGuestBytes(guest, buf_ptr, buf_cap, snap.content) orelse -1;
        };

        try vm.pushOperand(u64, @bitCast(@as(i64, @intCast(result))));
    }

    fn hostLspForFile(vm: *zware.VirtualMachine, context: usize) zware.WasmError!void {
        const guest: *WasmInstance = @ptrFromInt(context);
        const buf_cap: u32 = @truncate(vm.popOperand(u64));
        const buf_ptr: u32 = @truncate(vm.popOperand(u64));
        const path_len: u32 = @truncate(vm.popOperand(u64));
        const path_ptr: u32 = @truncate(vm.popOperand(u64));

        const result: i32 = blk: {
            const lookup = guest.env.callbacks.lsp_language_for_file orelse break :blk -1;
            const path = readGuestString(guest, path_ptr, path_len) orelse break :blk -1;
            if (!isSafeWorkspacePath(path, guest.env.limits.max_path_len)) break :blk -1;

            const mem = guest.instance.getMemory(guest.memory_idx) catch break :blk -1;
            const out_end = @as(usize, buf_ptr) + @as(usize, buf_cap);
            if (out_end > mem.data.items.len) break :blk -1;
            const out = mem.data.items[buf_ptr..out_end];
            const written = lookup(path, out) orelse break :blk -1;
            break :blk @intCast(written);
        };

        try vm.pushOperand(u64, @bitCast(@as(i64, @intCast(result))));
    }

    fn hostLspRequest(vm: *zware.VirtualMachine, context: usize) zware.WasmError!void {
        const guest: *WasmInstance = @ptrFromInt(context);
        const resp_cap: u32 = @truncate(vm.popOperand(u64));
        const resp_ptr: u32 = @truncate(vm.popOperand(u64));
        const req_len: u32 = @truncate(vm.popOperand(u64));
        const req_ptr: u32 = @truncate(vm.popOperand(u64));
        const lang_len: u32 = @truncate(vm.popOperand(u64));
        const lang_ptr: u32 = @truncate(vm.popOperand(u64));

        const result: i32 = blk: {
            const send = guest.env.callbacks.lsp_request orelse break :blk -1;
            const language = readGuestString(guest, lang_ptr, lang_len) orelse break :blk -1;
            const request = readGuestString(guest, req_ptr, req_len) orelse break :blk -1;
            if (request.len > guest.env.limits.max_lsp_request_bytes) break :blk -1;

            const mem = guest.instance.getMemory(guest.memory_idx) catch break :blk -1;
            const out_end = @as(usize, resp_ptr) + @as(usize, resp_cap);
            if (out_end > mem.data.items.len) break :blk -1;
            if (resp_cap > guest.env.limits.max_lsp_response_bytes) break :blk -1;
            const out = mem.data.items[resp_ptr..out_end];
            const written = send(language, request, out, guest.env.limits) orelse break :blk -1;
            break :blk @intCast(written);
        };

        try vm.pushOperand(u64, @bitCast(@as(i64, @intCast(result))));
    }

    pub fn isSafeWorkspacePath(path: []const u8, max_len: u32) bool {
        if (path.len == 0 or path.len > max_len) return false;
        if (std.mem.startsWith(u8, path, "/")) return false;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |component| {
            if (component.len == 0) return false;
            if (std.mem.eql(u8, component, "..")) return false;
        }
        return true;
    }

    fn readGuestString(guest: *WasmInstance, ptr: u32, len: u32) ?[]const u8 {
        if (len > guest.env.limits.max_string_len) return null;
        const mem = guest.instance.getMemory(guest.memory_idx) catch return null;
        const start: usize = ptr;
        const end = start + @as(usize, len);
        if (end > mem.data.items.len) return null;
        return mem.data.items[start..end];
    }

    fn writeGuestBytes(guest: *WasmInstance, ptr: u32, cap: u32, data: []const u8) ?i32 {
        if (data.len > cap) return null;
        if (data.len > guest.env.limits.max_read_bytes) return null;
        const mem = guest.instance.getMemory(guest.memory_idx) catch return null;
        const end = @as(usize, ptr) + data.len;
        if (end > mem.data.items.len) return null;
        @memcpy(mem.data.items[ptr..end], data);
        return @intCast(data.len);
    }

    fn writeGuestString(guest: *WasmInstance, value: []const u8) Error!u64 {
        const mem = guest.instance.getMemory(guest.memory_idx) catch return error.WasmInvokeFailed;
        const ptr: u32 = 4096;
        const end = @as(usize, ptr) + value.len;
        if (end > mem.data.items.len) return error.WasmInvokeFailed;
        @memcpy(mem.data.items[ptr..end], value);
        return ptr;
    }
};

pub fn parseRuntime(value: []const u8) ?RuntimeKind {
    if (std.mem.eql(u8, value, "native")) return .native;
    if (std.mem.eql(u8, value, "builtin")) return .builtin;
    if (std.mem.eql(u8, value, "wasm")) return .wasm;
    return null;
}

pub fn limitsFromManifest(manifest: *const manifest_mod.Manifest) Limits {
    var limits = Limits{};
    if (manifest.wasm_max_memory > 0) limits.max_memory_bytes = manifest.wasm_max_memory;
    if (manifest.wasm_max_read_bytes > 0) limits.max_read_bytes = manifest.wasm_max_read_bytes;
    if (manifest.wasm_max_string_len > 0) limits.max_string_len = manifest.wasm_max_string_len;
    if (manifest.wasm_max_path_len > 0) limits.max_path_len = manifest.wasm_max_path_len;
    if (manifest.wasm_max_lsp_request > 0) limits.max_lsp_request_bytes = manifest.wasm_max_lsp_request;
    if (manifest.wasm_max_lsp_response > 0) limits.max_lsp_response_bytes = manifest.wasm_max_lsp_response;
    return limits;
}

test "limitsFromManifest applies wasm overrides" {
    const manifest = manifest_mod.Manifest{
        .id = "x",
        .name = "x",
        .version = "0",
        .api_version = .{ .major = 1, .minor = 0 },
        .wasm_max_memory = 2097152,
        .commands = &.{},
        .themes = &.{},
        .keybindings = &.{},
        .languages = &.{},
    };
    const limits = limitsFromManifest(&manifest);
    try std.testing.expectEqual(@as(u32, 2097152), limits.max_memory_bytes);
}

test "wasm runtime loads sample module" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const TestState = struct {
        var logged: bool = false;
    };

    const callbacks = HostCallbacks{
        .log = struct {
            fn cb(msg: []const u8) void {
                _ = msg;
                TestState.logged = true;
            }
        }.cb,
        .set_status = struct {
            fn cb(_: []const u8) void {}
        }.cb,
    };

    var root = try workspace.WorkspaceRoot.open(io, ".");
    defer root.close(io);

    var guest = try WasmRuntime.loadAndActivate(
        allocator,
        io,
        root,
        "extensions/samples/wasm-hello",
        "main.wasm",
        callbacks,
        .{},
    );
    defer {
        WasmRuntime.deactivate(guest);
        guest.deinit(allocator);
    }

    try WasmRuntime.executeCommand(guest, "hello.wasm");
    try std.testing.expect(TestState.logged);
}

test "safe workspace path rejects escapes" {
    try std.testing.expect(WasmRuntime.isSafeWorkspacePath("README.md", 512));
    try std.testing.expect(!WasmRuntime.isSafeWorkspacePath("../etc/passwd", 512));
    try std.testing.expect(!WasmRuntime.isSafeWorkspacePath("/absolute", 512));
}

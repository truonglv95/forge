const std = @import("std");
const zware = @import("zware");

pub const WasiSandbox = struct {
    allocator: std.mem.Allocator,
    store: zware.Store,
    instance: zware.Instance,
    memory_idx: usize,
    args: [][]const u8,

    pub const Error = error{
        InitFailed,
        MemoryMissing,
        InvokeFailed,
    };

    pub fn init(allocator: std.mem.Allocator, wasm_bytes: []u8, args: [][]const u8) !*WasiSandbox {
        const self = try allocator.create(WasiSandbox);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .store = zware.Store.init(allocator),
            .instance = undefined,
            .memory_idx = 0,
            .args = args,
        };
        errdefer self.store.deinit();

        try self.bindWasi();

        var module = zware.Module.init(allocator, wasm_bytes);
        module.decode() catch return error.InitFailed;
        defer module.deinit();

        self.instance = zware.Instance.init(allocator, &self.store, module);
        self.instance.instantiate() catch return error.InitFailed;

        self.memory_idx = self.instance.module.getExport(.Mem, "memory") catch return error.MemoryMissing;

        return self;
    }

    pub fn deinit(self: *WasiSandbox) void {
        self.instance.deinit();
        self.instance.module.deinit();
        self.store.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *WasiSandbox) !i32 {
        self.instance.invoke("_start", &[_]u64{}, &[_]u64{}, .{}) catch return -1;
        return 0; // Success
    }

    fn bindWasi(self: *WasiSandbox) !void {
        const ctx = @intFromPtr(self);
        const i32_2 = [_]zware.ValType{ .I32, .I32 };
        const i32_4 = [_]zware.ValType{ .I32, .I32, .I32, .I32 };
        const i32_1 = [_]zware.ValType{.I32};

        try self.store.exposeHostFunction("wasi_snapshot_preview1", "args_sizes_get", argsSizesGet, ctx, &i32_2, &i32_1);
        try self.store.exposeHostFunction("wasi_snapshot_preview1", "args_get", argsGet, ctx, &i32_2, &i32_1);
        try self.store.exposeHostFunction("wasi_snapshot_preview1", "fd_write", fdWrite, ctx, &i32_4, &i32_1);
        try self.store.exposeHostFunction("wasi_snapshot_preview1", "proc_exit", procExit, ctx, &i32_1, &[_]zware.ValType{});
        // fd_prestat_get, fd_prestat_dir_name etc. can be added here for full FS access control.
    }

    // WASI implementation
    fn argsSizesGet(vm: *zware.VirtualMachine, ctx: usize) zware.WasmError!void {
        const self: *WasiSandbox = @ptrFromInt(ctx);
        const mem = self.instance.getMemory(self.memory_idx) catch return error.Trap;
        const buf_size_ptr: u32 = @truncate(vm.popOperand(u64));
        const argc_ptr: u32 = @truncate(vm.popOperand(u64));

        const argc: u32 = @intCast(self.args.len);
        var buf_size: u32 = 0;
        for (self.args) |arg| {
            buf_size += @intCast(arg.len + 1);
        }

        std.mem.writeInt(u32, mem.data.items[argc_ptr .. argc_ptr + 4][0..4], argc, .little);
        std.mem.writeInt(u32, mem.data.items[buf_size_ptr .. buf_size_ptr + 4][0..4], buf_size, .little);
        try vm.pushOperand(u64, 0); // success
    }

    fn argsGet(vm: *zware.VirtualMachine, ctx: usize) zware.WasmError!void {
        const self: *WasiSandbox = @ptrFromInt(ctx);
        const mem = self.instance.getMemory(self.memory_idx) catch return error.Trap;
        const buf_ptr: u32 = @truncate(vm.popOperand(u64));
        const argv_ptr: u32 = @truncate(vm.popOperand(u64));

        var cur_argv_ptr = argv_ptr;
        var cur_buf_ptr = buf_ptr;

        for (self.args) |arg| {
            std.mem.writeInt(u32, mem.data.items[cur_argv_ptr .. cur_argv_ptr + 4][0..4], cur_buf_ptr, .little);
            @memcpy(mem.data.items[cur_buf_ptr .. cur_buf_ptr + arg.len], arg);
            mem.data.items[cur_buf_ptr + arg.len] = 0;
            cur_argv_ptr += 4;
            cur_buf_ptr += @intCast(arg.len + 1);
        }
        try vm.pushOperand(u64, 0); // success
    }

    fn fdWrite(vm: *zware.VirtualMachine, ctx: usize) zware.WasmError!void {
        const self: *WasiSandbox = @ptrFromInt(ctx);
        const mem = self.instance.getMemory(self.memory_idx) catch return error.Trap;

        const nwritten_ptr: u32 = @truncate(vm.popOperand(u64));
        const iovs_len: u32 = @truncate(vm.popOperand(u64));
        const iovs_ptr: u32 = @truncate(vm.popOperand(u64));
        const fd: u32 = @truncate(vm.popOperand(u64));

        var total_written: u32 = 0;
        var i: u32 = 0;
        while (i < iovs_len) : (i += 1) {
            const ptr_loc = iovs_ptr + i * 8;
            const len_loc = ptr_loc + 4;
            const buf_ptr = std.mem.readInt(u32, mem.data.items[ptr_loc .. ptr_loc + 4][0..4], .little);
            const buf_len = std.mem.readInt(u32, mem.data.items[len_loc .. len_loc + 4][0..4], .little);

            const content = mem.data.items[buf_ptr .. buf_ptr + buf_len];
            if (fd == 1) {
                std.io.getStdOut().writer().writeAll(content) catch {};
            } else if (fd == 2) {
                std.io.getStdErr().writer().writeAll(content) catch {};
            }
            total_written += buf_len;
        }

        std.mem.writeInt(u32, mem.data.items[nwritten_ptr .. nwritten_ptr + 4][0..4], total_written, .little);
        try vm.pushOperand(u64, 0); // success
    }

    fn procExit(vm: *zware.VirtualMachine, ctx: usize) zware.WasmError!void {
        _ = ctx;
        const exit_code: u32 = @truncate(vm.popOperand(u64));
        _ = exit_code;
        return error.Trap; // exit WASM execution
    }
};

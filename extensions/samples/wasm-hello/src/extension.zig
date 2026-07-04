extern "forge_host" fn forge_host_log(ptr: u32, len: u32) void;
extern "forge_host" fn forge_host_set_status(ptr: u32, len: u32) void;
extern "forge_host" fn forge_host_read_file(path_ptr: u32, path_len: u32, buf_ptr: u32, buf_cap: u32) i32;
extern "forge_host" fn forge_host_lsp_for_file(path_ptr: u32, path_len: u32, buf_ptr: u32, buf_cap: u32) i32;
extern "forge_host" fn forge_host_lsp_request(
    lang_ptr: u32,
    lang_len: u32,
    req_ptr: u32,
    req_len: u32,
    resp_ptr: u32,
    resp_cap: u32,
) i32;

export var memory: [65536]u8 = blk: {
    var mem: [65536]u8 = [_]u8{0} ** 65536;
    const text = "Hello from WASM extension!";
    @memcpy(mem[0..text.len], text);
    @memcpy(mem[32..][0..9], "README.md");
    @memcpy(mem[64..][0..27], "apps/forge-ide/src/main.zig");
    @memcpy(mem[96..][0..3], "zig");
    @memcpy(mem[128..][0..44], "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"shutdown\"}");
    break :blk mem;
};

const buf_read: u32 = 8192;
const buf_lsp: u32 = 8448;
const buf_lsp_resp: u32 = 16384;

export fn forge_activate() void {
    forge_host_set_status(0, 24);
}

export fn forge_execute_command(cmd_ptr: u32, cmd_len: u32) void {
    forge_host_log(cmd_ptr, cmd_len);

    const read_len = forge_host_read_file(32, 9, buf_read, 256);
    if (read_len > 0) {
        forge_host_log(buf_read, @intCast(read_len));
    }

    const lsp_len = forge_host_lsp_for_file(64, 27, buf_lsp, 32);
    if (lsp_len > 0) {
        forge_host_log(buf_lsp, @intCast(lsp_len));
    }

    const req_len = forge_host_lsp_request(96, 3, 128, 44, buf_lsp_resp, 512);
    if (req_len > 0) {
        forge_host_log(buf_lsp_resp, @intCast(req_len));
    }
}

export fn forge_deactivate() void {}

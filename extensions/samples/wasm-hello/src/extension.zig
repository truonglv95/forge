const forge = @import("forge-plugin").sdk;

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
    forge.guest.setStatus(memory[0..24]);
}

export fn forge_execute_command(cmd_ptr: u32, cmd_len: u32) void {
    forge.guest.log(memory[cmd_ptr..][0..cmd_len]);

    if (forge.guest.readFile(memory[32..][0..9], memory[buf_read..][0..256])) |content| {
        forge.guest.log(content);
    }

    if (forge.guest.languageForFile(memory[64..][0..27], memory[buf_lsp..][0..32])) |language| {
        forge.guest.log(language);
    }

    if (forge.guest.lspRequest(memory[96..][0..3], memory[128..][0..44], memory[buf_lsp_resp..][0..512])) |response| {
        forge.guest.log(response);
    }
}

export fn forge_deactivate() void {}

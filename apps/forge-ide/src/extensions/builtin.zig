const std = @import("std");
const plugin = @import("forge-plugin");

var status_sink: ?*const WorkbenchStatus = null;

pub const WorkbenchStatus = struct {
    setStatus: *const fn (message: []const u8) void,
};

pub fn bindStatus(status: *const WorkbenchStatus) void {
    status_sink = status;
}

const hello_commands = [_]plugin.CommandEntry{
    .{ .id = "hello.say", .title = "Say Hello" },
};

fn helloActivate(ctx: *plugin.ActivationContext) !void {
    _ = ctx;
    if (status_sink) |sink| sink.setStatus("Hello extension activated");
}

fn helloExecute(ctx: *plugin.ActivationContext, command_id: []const u8) !void {
    _ = ctx;
    if (!std.mem.eql(u8, command_id, "hello.say")) return;
    if (status_sink) |sink| sink.setStatus("Hello from Forge extension!");
}

pub const hello_extension = plugin.BuiltinExtension{
    .id = "forge.samples.hello",
    .name = "Hello Sample",
    .version = "0.1.0",
    .commands = &hello_commands,
    .activate = helloActivate,
    .executeCommand = helloExecute,
};

fn lspActivate(ctx: *plugin.ActivationContext) !void {
    try ctx.registerLanguage(.{
        .id = "zig",
        .server = "zls",
        .args = "",
        .file_pattern = "*.zig",
        .server_resolver = "vscode-zig-zls",
    });

    try ctx.registerLanguage(.{
        .id = "typescript",
        .server = "typescript-language-server",
        .args = "--stdio",
        .file_pattern = "*.ts",
    });

    try ctx.registerLanguage(.{
        .id = "typescriptreact",
        .server = "typescript-language-server",
        .args = "--stdio",
        .file_pattern = "*.tsx",
    });

    try ctx.registerLanguage(.{
        .id = "javascript",
        .server = "typescript-language-server",
        .args = "--stdio",
        .file_pattern = "*.js",
    });

    try ctx.registerLanguage(.{
        .id = "javascriptreact",
        .server = "typescript-language-server",
        .args = "--stdio",
        .file_pattern = "*.jsx",
    });

    try ctx.registerLanguage(.{
        .id = "python",
        .server = "pyright-langserver",
        .args = "--stdio",
        .file_pattern = "*.py",
    });

    try ctx.registerLanguage(.{
        .id = "go",
        .server = "gopls",
        .args = "",
        .file_pattern = "*.go",
    });

    try ctx.registerLanguage(.{
        .id = "rust",
        .server = "rust-analyzer",
        .args = "",
        .file_pattern = "*.rs",
    });
}

pub const lsp_extension = plugin.BuiltinExtension{
    .id = "forge.builtin.lsp",
    .name = "Builtin LSP Configurations",
    .version = "1.0.0",
    .commands = &.{},
    .activate = lspActivate,
};

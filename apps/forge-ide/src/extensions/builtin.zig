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
    const langs = &ctx.host.contributions.languages;
    const allocator = ctx.allocator;

    try langs.append(allocator, .{
        .id = try allocator.dupe(u8, "zig"),
        .server = try allocator.dupe(u8, "zls"),
        .args = try allocator.dupe(u8, ""),
        .file_pattern = try allocator.dupe(u8, "*.zig"),
        .extension_id = try allocator.dupe(u8, ctx.extension_id),
    });

    try langs.append(allocator, .{
        .id = try allocator.dupe(u8, "python"),
        .server = try allocator.dupe(u8, "pyright-langserver"),
        .args = try allocator.dupe(u8, "--stdio"),
        .file_pattern = try allocator.dupe(u8, "*.py"),
        .extension_id = try allocator.dupe(u8, ctx.extension_id),
    });

    try langs.append(allocator, .{
        .id = try allocator.dupe(u8, "go"),
        .server = try allocator.dupe(u8, "gopls"),
        .args = try allocator.dupe(u8, ""),
        .file_pattern = try allocator.dupe(u8, "*.go"),
        .extension_id = try allocator.dupe(u8, ctx.extension_id),
    });
}

pub const lsp_extension = plugin.BuiltinExtension{
    .id = "forge.builtin.lsp",
    .name = "Builtin LSP Configurations",
    .version = "1.0.0",
    .commands = &.{},
    .activate = lspActivate,
};

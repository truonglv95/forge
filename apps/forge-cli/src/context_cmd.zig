const std = @import("std");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    const intent = if (parsed.positional.len > 0) parsed.positional[0] else null;

    var ctx_builder = try ai.context_loader.build(allocator, io, opened.root, .{
        .intent = intent,
        .explicit_files = parsed.flags.files,
        .max_bytes = if (parsed.flags.budget_bytes > 0) parsed.flags.budget_bytes else 1024 * 1024,
    });
    defer ctx_builder.deinit();

    if (parsed.flags.json) {
        try ai.context_loader.renderManifestJson(&ctx_builder, writer);
    } else {
        if (intent) |text| {
            try writer.print("Context manifest for intent: '{s}'\n\n", .{text});
        } else {
            try writer.writeAll("Context manifest\n\n");
        }
        try ai.context_loader.renderManifestHuman(&ctx_builder, writer);
    }

    return 0;
}

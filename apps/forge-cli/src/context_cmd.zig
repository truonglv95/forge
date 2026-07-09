const std = @import("std");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

fn parseMode(value: ?[]const u8) ai.tools.Mode {
    if (value) |mode| {
        if (std.mem.eql(u8, mode, "plan")) return .plan;
        if (std.mem.eql(u8, mode, "agent")) return .agent;
        if (std.mem.eql(u8, mode, "ask")) return .ask;
    }
    return .agent;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);
    workspace_cmd.scheduleSemanticIndex(allocator, io, null, opened);

    const intent = if (parsed.positional.len > 0) parsed.positional[0] else null;
    const intent_text = intent orelse "";
    const mode = parseMode(parsed.flags.mode);

    const route = ai.routing.plan(.{
        .mode = mode,
        .intent = intent_text,
        .has_active_file = parsed.flags.files.len > 0,
    }, .{
        .intent = intent,
        .explicit_files = parsed.flags.files,
        .max_bytes = if (parsed.flags.budget_bytes > 0) parsed.flags.budget_bytes else 1024 * 1024,
        .workspace_cwd = opened.path,
    });

    var tools_buf: [256]u8 = undefined;
    const tools_summary = ai.routing.formatToolsSummary(
        &tools_buf,
        route.capability_profile,
        route.intent,
        intent_text,
    );

    var ctx_builder = try ai.context_loader.build(allocator, io, opened.root, route.context);
    defer ctx_builder.deinit();
    {
        var routing_buf: [128]u8 = undefined;
        const summary = ai.routing.formatRoutingSummary(&routing_buf, .{
            .mode = mode,
            .intent = intent_text,
            .has_active_file = parsed.flags.files.len > 0,
        }, route);
        ctx_builder.addBlock(.intent, "routing", summary) catch {};
    }

    if (parsed.flags.json) {
        try ai.context_loader.renderManifestJson(&ctx_builder, writer);
    } else {
        if (intent) |text| {
            try writer.print("Context manifest for intent: '{s}'\n\n", .{text});
        } else {
            try writer.writeAll("Context manifest\n\n");
        }
        try writer.print(
            "Routing: task={s} profile={s} tools={s}\n\n",
            .{ ai.routing.intentLabel(route.intent), @tagName(route.capability_profile), tools_summary },
        );
        try ai.context_loader.renderManifestHuman(&ctx_builder, writer);
    }

    return 0;
}

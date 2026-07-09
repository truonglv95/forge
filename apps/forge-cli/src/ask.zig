const std = @import("std");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: ask requires an intent\n");
        return 2;
    }

    const intent = parsed.positional[0];

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);
    workspace_cmd.scheduleSemanticIndex(allocator, io, environ_map, opened);

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    if (!parsed.flags.quiet and !parsed.flags.json) scope.installSigint();

    if (!parsed.flags.quiet and !parsed.flags.json) {
        try writer.print("Asking: {s}\n", .{intent});
    }

    const progress_writer: ?*std.Io.Writer = if (parsed.flags.quiet or parsed.flags.json) null else writer;
    var cancel_token = scope.token();

    var provider_options = ai_workflow.providerOptionsFromFlags(allocator, .ask, parsed.flags, io, opened.root);
    defer provider_options.deinit(allocator);

    const generated = ai_workflow.generateAndPersist(
        allocator,
        io,
        environ_map,
        opened,
        .ask,
        intent,
        parsed.flags.files,
        provider_options,
        .{
            .cancel_token = &cancel_token,
            .progress_writer = progress_writer,
            .progress_json = parsed.flags.json,
        },
    ) catch |err| {
        if (err == error.Cancelled) {
            try writer.writeAll("error: ask cancelled\n");
            return 130;
        }
        return ai_workflow.writeError(writer, err);
    };
    defer allocator.free(generated.run_id);
    defer allocator.free(generated.proposal_rel);

    if (parsed.flags.json) {
        try writer.print(
            "{{\"status\":\"ok\",\"type\":\"ask\",\"run_id\":\"{s}\",\"proposal_path\":\"{s}\",\"state\":\"proposed\"}}\n",
            .{ generated.run_id, generated.proposal_rel },
        );
    } else {
        try writer.print("Proposal saved to {s}\n", .{generated.proposal_rel});
        try writer.print("Run record: .forge/runs/{s}.json\n", .{generated.run_id});
        try writer.writeAll("Review with: forge diff <proposal> --workspace <path>\n");
    }

    return 0;
}

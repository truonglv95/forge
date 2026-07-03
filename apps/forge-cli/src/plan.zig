const std = @import("std");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: plan command requires an intent\n");
        return 2;
    }
    const intent = parsed.positional[0];

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    if (!parsed.flags.quiet and !parsed.flags.json) {
        try writer.print("Planning intent: '{s}'\n", .{intent});
        try writer.writeAll("Building context...\nInvoking model...\n");
    }

    const generated = ai_workflow.generateAndPersist(
        allocator,
        io,
        environ_map,
        opened,
        .plan,
        intent,
        parsed.flags.files,
        ai_workflow.providerOptionsFromFlags(.plan, parsed.flags),
    ) catch |err| switch (err) {
        error.MissingProviderCredentials => {
            try writer.writeAll("error: gemini provider requires GEMINI_API_KEY, GOOGLE_API_KEY, or macOS Keychain entry (service forge-gemini)\n");
            return 2;
        },
        error.ProviderFailed => {
            try writer.writeAll("error: AI provider failed\n");
            return 2;
        },
    };
    defer allocator.free(generated.run_id);
    defer allocator.free(generated.proposal_rel);

    if (parsed.flags.json) {
        try writer.print(
            "{{\"status\":\"ok\",\"type\":\"plan\",\"run_id\":\"{s}\",\"proposal_path\":\"{s}\",\"state\":\"planning\"}}\n",
            .{ generated.run_id, generated.proposal_rel },
        );
    } else {
        try writer.print("Proposal saved to {s}\n", .{generated.proposal_rel});
        try writer.print("Run record: .forge/runs/{s}.json\n", .{generated.run_id});
        try writer.writeAll("Review with: forge diff <proposal> --workspace <path>\n");
    }

    return 0;
}

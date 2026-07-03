const std = @import("std");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

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

    if (!parsed.flags.quiet and !parsed.flags.json) {
        try writer.print("Asking: {s}\n", .{intent});
        try writer.writeAll("Building context...\nInvoking model...\n");
    }

    const generated = @import("ai_workflow.zig").generateAndPersist(
        allocator,
        io,
        environ_map,
        opened,
        .ask,
        intent,
        parsed.flags.files,
        @import("ai_workflow.zig").providerOptionsFromFlags(.ask, parsed.flags),
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

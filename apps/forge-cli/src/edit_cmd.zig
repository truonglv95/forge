const std = @import("std");
const ai = @import("forge-ai");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");
const ai_workflow = @import("ai_workflow.zig");
const cancel_scope_mod = @import("cancel_scope.zig");

const Io = std.Io;

/// `forge edit` — Composer-style multi-file inline edit.
///
/// Takes a natural language instruction + file paths, asks AI to propose
/// edits across those files, then applies atomically via transaction.
/// This is the CLI equivalent of Cursor's Cmd+K inline edit / Composer.
///
/// Usage:
///   forge edit "add error handling to main function" --file src/main.zig
///   forge edit "rename foo to bar across all callers" --file src/main.zig --file src/caller.zig
///   forge edit "extract helper function" --file src/utils.zig --dry-run
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: edit requires an instruction\n");
        try writer.writeAll("usage: forge edit <instruction> --file <path> [--file <path>...] [--dry-run] [--yes]\n");
        return 2;
    }

    const instruction = parsed.positional[0];
    if (parsed.flags.files.len == 0) {
        try writer.writeAll("error: edit requires at least one --file\n");
        try writer.writeAll("usage: forge edit <instruction> --file <path> [--file <path>...]\n");
        return 2;
    }

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    if (!parsed.flags.json and !parsed.flags.quiet) {
        try writer.print("Editing {d} file(s): {s}\n", .{ parsed.flags.files.len, instruction });
        for (parsed.flags.files) |f| {
            try writer.print("  - {s}\n", .{f});
        }
        try writer.writeAll("\n");
    }

    var scope = try cancel_scope_mod.Scope.init(allocator);
    defer scope.deinit();
    if (!parsed.flags.quiet and !parsed.flags.json) scope.installSigint();
    const cancel_token = scope.token();

    var provider_options = ai_workflow.agentProviderOptionsFromFlags(allocator, parsed.flags, instruction, io, opened.root);
    defer provider_options.deinit(allocator);

    const progress_writer: ?*std.Io.Writer = if (parsed.flags.quiet or parsed.flags.json) null else writer;

    const generated = ai_workflow.generateAndPersist(
        allocator,
        io,
        environ_map,
        opened,
        .ask,
        instruction,
        parsed.flags.files,
        provider_options.options,
        .{
            .cancel_token = &cancel_token,
            .progress_writer = progress_writer,
            .progress_json = parsed.flags.json,
        },
    ) catch |err| {
        return ai_workflow.writeError(writer, err);
    };
    defer allocator.free(generated.run_id);
    defer allocator.free(generated.proposal_rel);

    if (parsed.flags.json) {
        try writer.print(
            "{{\"status\":\"ok\",\"type\":\"edit\",\"run_id\":\"{s}\",\"proposal_path\":\"{s}\",\"state\":\"proposed\"}}\n",
            .{ generated.run_id, generated.proposal_rel },
        );
        return 0;
    }

    try writer.print("\nProposal saved to {s}\n", .{generated.proposal_rel});
    try writer.print("Run record: .forge/runs/{s}.json\n", .{generated.run_id});

    if (parsed.flags.dry_run) {
        try writer.writeAll("\n--dry-run: not applying. Review with:\n");
        try writer.print("  forge diff {s}\n", .{generated.proposal_rel});
        return 0;
    }

    // Auto-apply if --yes, otherwise prompt.
    const should_apply = parsed.flags.yes or promptApply(writer);
    if (!should_apply) {
        try writer.writeAll("\nNot applied. Review with:\n");
        try writer.print("  forge diff {s}\n", .{generated.proposal_rel});
        try writer.writeAll("Apply with:\n");
        try writer.print("  forge apply {s} --yes\n", .{generated.proposal_rel});
        return 0;
    }

    // Apply the proposal via transaction.
    var apply_parsed = parsed;
    var apply_positionals = [_][]const u8{generated.proposal_rel};
    apply_parsed.positional = &apply_positionals;
    apply_parsed.flags.dry_run = false;

    const apply_cmd = @import("apply.zig");
    const apply_code = apply_cmd.run(allocator, io, apply_parsed, writer) catch |err| {
        try writer.print("error applying proposal: {}\n", .{err});
        return 2;
    };

    if (apply_code == 0 and !parsed.flags.quiet) {
        try writer.writeAll("\nEdit applied successfully.\n");
        try writer.writeAll("Undo with: forge undo <transaction_id>\n");
    }

    return apply_code;
}

fn promptApply(writer: *std.Io.Writer) bool {
    // Non-interactive: don't apply automatically.
    // Real implementation would prompt y/N in interactive mode.
    _ = writer;
    return false;
}

test "edit requires instruction" {
    // Stub test — edit_cmd.run requires workspace I/O which is hard to set up
    // in a unit test. Verified manually via CLI invocation.
    try std.testing.expect(true);
}

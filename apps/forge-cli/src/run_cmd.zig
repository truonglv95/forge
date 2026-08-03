const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: run requires a subcommand (list|show)\n");
        return 2;
    }

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    const sub = parsed.positional[0];
    if (std.mem.eql(u8, sub, "list")) {
        return listRuns(allocator, io, opened.root, parsed, writer);
    }
    if (std.mem.eql(u8, sub, "show")) {
        if (parsed.positional.len < 2) {
            try writer.writeAll("error: run show requires a run id\n");
            return 2;
        }
        return showRun(allocator, io, opened.root, parsed.positional[1], parsed, writer);
    }

    try writer.print("error: unknown run subcommand '{s}'\n", .{sub});
    return 2;
}

fn listRuns(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    var list = try workspace.runs.listEntries(allocator, io, root);
    defer list.deinit();

    if (parsed.flags.json) {
        try writer.writeAll("{\"status\":\"ok\",\"type\":\"run_list\",\"runs\":[");
        for (list.items, 0..) |entry, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print(
                "{{\"run_id\":\"{s}\",\"state\":\"{s}\",\"timestamp_ms\":{d}}}",
                .{ entry.run_id, entry.state, entry.timestamp_ms },
            );
        }
        try writer.writeAll("]}\n");
    } else if (list.items.len == 0) {
        try writer.writeAll("No AI runs recorded.\n");
    } else {
        try writer.writeAll("AI runs:\n");
        for (list.items) |entry| {
            try writer.print("  {s} [{s}] ({d})\n", .{
                entry.run_id,
                entry.state,
                entry.timestamp_ms,
            });
        }
    }

    return 0;
}

fn showRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    run_id: []const u8,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    const json_body = workspace.runs.loadRunJson(allocator, io, root, run_id) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("error: run '{s}' not found\n", .{run_id});
            return 2;
        },
        else => return err,
    };
    defer allocator.free(json_body);

    if (parsed.flags.json) {
        try writer.writeAll(json_body);
        if (json_body.len == 0 or json_body[json_body.len - 1] != '\n') try writer.writeAll("\n");
    } else {
        const JsonRun = struct {
            run_id: []const u8,
            intent: []const u8,
            state: []const u8,
            proposal_path: []const u8,
            provider_id: []const u8,
            model_id: []const u8,
            timestamp_ms: i64,
        };
        var parsed_run = try std.json.parseFromSlice(JsonRun, allocator, json_body, .{ .ignore_unknown_fields = true });
        defer parsed_run.deinit();

        try writer.print("Run {s}\n", .{parsed_run.value.run_id});
        try writer.print("  state: {s}\n", .{parsed_run.value.state});
        try writer.print("  intent: {s}\n", .{parsed_run.value.intent});
        try writer.print("  proposal: {s}\n", .{parsed_run.value.proposal_path});
        try writer.print("  provider: {s} / {s}\n", .{ parsed_run.value.provider_id, parsed_run.value.model_id });
        try writer.print("  timestamp_ms: {d}\n", .{parsed_run.value.timestamp_ms});
    }

    return 0;
}

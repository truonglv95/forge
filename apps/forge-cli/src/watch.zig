const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    if (!parsed.flags.quiet) {
        try writer.writeAll("Watching workspace for changes");
        if (parsed.flags.once) try writer.writeAll(" (single poll)");
        try writer.writeAll("...\n");
    }

    var previous: ?workspace.watch.Snapshot = null;
    defer if (previous) |*snap| snap.deinit();

    var poll_count: u32 = 0;
    while (true) {
        var events = try workspace.watch.poll(allocator, io, opened.root, opened.path, &previous);
        defer events.deinit();

        for (events.items) |event| {
            if (parsed.flags.json) {
                try writer.print(
                    "{{\"type\":\"watch\",\"path\":\"{s}\",\"kind\":\"{s}\"}}\n",
                    .{ event.path, @tagName(event.kind) },
                );
            } else {
                try writer.print("{s}: {s}\n", .{ @tagName(event.kind), event.path });
            }
        }

        poll_count += 1;
        if (parsed.flags.once) break;
        if (parsed.flags.max_polls > 0 and poll_count >= parsed.flags.max_polls) break;

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real) catch break;
    }

    return 0;
}

const std = @import("std");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    if (parsed.positional.len == 0 or !std.mem.eql(u8, parsed.positional[0], "sync")) {
        try writer.writeAll("usage: forge parsers sync [--workspace <path>] [--json]\n");
        return 2;
    }

    var opened = try workspace_cmd.OpenedWorkspace.open(allocator, io, parsed);
    defer opened.close(io);

    var set = try workspace.parser_resolver.ensure(allocator, io, opened.root);
    defer set.deinit(allocator);

    if (parsed.flags.json) {
        const Json = struct {
            type: []const u8 = "parser_sync",
            parser_set_id: []const u8,
            toolchain_fingerprint: u64,
            sync_file: []const u8 = workspace.parser_sync.sync_file,
        };
        const line = try std.json.Stringify.valueAlloc(allocator, Json{
            .parser_set_id = set.parser_set_id,
            .toolchain_fingerprint = set.toolchain_fingerprint,
        }, .{});
        defer allocator.free(line);
        try writer.print("{s}\n", .{line});
        return 0;
    }

    try writer.print("parser set: {s}\n", .{set.parser_set_id});
    try writer.print("toolchain fingerprint: {d}\n", .{set.toolchain_fingerprint});
    try writer.print("wrote {s}\n", .{workspace.parser_sync.sync_file});
    return 0;
}

test "parsers sync requires sync subcommand" {
    const allocator = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const parsed = args_mod.CliArgs{
        .flags = .{},
        .command = .parsers,
        .positional = &.{},
    };
    try std.testing.expectEqual(@as(u8, 2), try run(allocator, std.testing.io, parsed, &writer));
}

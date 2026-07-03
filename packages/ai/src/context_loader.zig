const std = @import("std");
const context = @import("context.zig");
const workspace = @import("forge-workspace");

pub const LoadOptions = struct {
    max_bytes: usize = 1024 * 1024,
    intent: ?[]const u8 = null,
    explicit_files: []const []const u8 = &.{},
};

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    options: LoadOptions,
) !context.ContextBuilder {
    var builder = context.ContextBuilder.init(allocator, options.max_bytes);

    if (options.intent) |intent| {
        try builder.addBlock(.intent, "intent", intent);
    }

    for (options.explicit_files) |file_path| {
        const wp = workspace.WorkspacePath.parse(file_path) catch {
            try builder.rejected.put(try allocator.dupe(u8, file_path), "Invalid workspace path");
            continue;
        };

        var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch |err| {
            const reason = switch (err) {
                error.FileNotFound => "File not found",
                else => "Failed to read file",
            };
            try builder.rejected.put(try allocator.dupe(u8, file_path), reason);
            continue;
        };
        defer snap.deinit();

        try builder.addBlock(.file, file_path, snap.content);
    }

    return builder;
}

pub fn renderManifestHuman(builder: *const context.ContextBuilder, writer: *std.Io.Writer) !void {
    for (builder.blocks.items) |block| {
        const tag = if (block.is_truncated) "TRUNCATED" else "INCLUDED";
        try writer.print("[{s}] {s} ({s}, {d} bytes)\n", .{
            tag,
            block.name,
            @tagName(block.block_type),
            block.content.len,
        });
    }

    var reject_it = builder.rejected.iterator();
    while (reject_it.next()) |entry| {
        try writer.print("[REJECTED] {s} ({s})\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    try writer.print("\nTotal budget used: {d} / {d} bytes\n", .{ builder.used_bytes, builder.max_bytes });
}

pub fn renderManifestJson(builder: *const context.ContextBuilder, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"schema_version\":1,\"items\":[");
    var first = true;
    for (builder.blocks.items) |block| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.print(
            "{{\"kind\":\"{s}\",\"name\":\"{s}\",\"included\":true,\"truncated\":{},\"bytes\":{d}}}",
            .{ @tagName(block.block_type), block.name, block.is_truncated, block.content.len },
        );
    }

    var reject_it = builder.rejected.iterator();
    while (reject_it.next()) |entry| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.print(
            "{{\"kind\":\"file\",\"name\":\"{s}\",\"included\":false,\"reason\":\"{s}\",\"bytes\":0}}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
    }

    try writer.print("],\"budget_bytes\":{d},\"used_bytes\":{d}}}\n", .{ builder.max_bytes, builder.used_bytes });
}

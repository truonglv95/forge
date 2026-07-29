const std = @import("std");
const workspace = @import("forge-workspace");
const plugin = @import("forge-plugin");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: *const @import("args.zig").CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    const workspace_path = parsed.flags.workspace orelse ".";
    var root = try workspace.WorkspaceRoot.open(io, workspace_path);
    defer root.close(io);

    const sub = parsed.positional[0];
    if (std.mem.eql(u8, sub, "list")) {
        return try listCatalog(allocator, io, root, writer);
    }
    if (std.mem.eql(u8, sub, "install")) {
        if (parsed.positional.len < 2) {
            try writer.print("usage: forge ext install <extension-id>\n", .{});
            return 2;
        }
        return try installExtension(allocator, io, root, parsed.positional[1], parsed.flags.dry_run, writer);
    }
    if (std.mem.eql(u8, sub, "uninstall")) {
        if (parsed.positional.len < 2) {
            try writer.print("usage: forge ext uninstall <extension-id>\n", .{});
            return 2;
        }
        return try uninstallExtension(allocator, io, root, parsed.positional[1], parsed.flags.dry_run, writer);
    }

    try writer.print("usage: forge ext <list|install|uninstall> [id]\n", .{});
    return 2;
}

fn listCatalog(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, writer: *std.Io.Writer) !u8 {
    var catalog = plugin.marketplace.loadCatalog(allocator, io, root) catch |err| {
        try writer.print("catalog unavailable: {}\n", .{err});
        return 1;
    };
    defer catalog.deinit(allocator);

    for (catalog.entries) |entry| {
        const installed = plugin.marketplace.isInstalled(allocator, io, root, &entry) catch false;
        try writer.print("{s}\t{s}\t{s}\t{}\n", .{ entry.id, entry.version, entry.name, installed });
    }
    return 0;
}

fn installExtension(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    extension_id: []const u8,
    dry_run: bool,
    writer: *std.Io.Writer,
) !u8 {
    var catalog = try plugin.marketplace.loadCatalog(allocator, io, root);
    defer catalog.deinit(allocator);
    const entry = plugin.marketplace.findEntry(&catalog, extension_id) orelse {
        try writer.print("extension not found: {s}\n", .{extension_id});
        return 1;
    };
    if (dry_run) {
        try writer.print("would install {s} from extensions/{s}\n", .{ entry.id, entry.source });
        return 0;
    }
    const dest = try plugin.marketplace.install(allocator, io, root, entry);
    defer allocator.free(dest);
    try writer.print("installed {s} to .forge/extensions/{s}\n", .{ entry.id, dest });
    return 0;
}

fn uninstallExtension(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    extension_id: []const u8,
    dry_run: bool,
    writer: *std.Io.Writer,
) !u8 {
    if (dry_run) {
        try writer.print("would uninstall {s}\n", .{extension_id});
        return 0;
    }
    plugin.marketplace.uninstall(allocator, io, root, extension_id) catch |err| {
        try writer.print("uninstall failed: {}\n", .{err});
        return 1;
    };
    try writer.print("uninstalled {s}\n", .{extension_id});
    return 0;
}

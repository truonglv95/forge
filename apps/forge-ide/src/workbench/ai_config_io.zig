const std = @import("std");
const workspace = @import("forge-workspace");

pub fn writeTomlKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const wp = try workspace.WorkspacePath.parse("forge.toml");
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch {
        const content = try std.fmt.allocPrint(allocator, "[{s}]\n{s} = {s}\n", .{ section_name, key, value });
        defer allocator.free(content);
        try workspace.atomic.replaceFile(io, root, wp, content);
        return;
    };
    defer snap.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var in_section = false;
    var wrote = false;
    var lines = std.mem.splitScalar(u8, snap.content, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = std.mem.trim(u8, &std.ascii.whitespace, trimmed[1 .. trimmed.len - 1]);
            if (in_section and !wrote) {
                try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{s} = {s}\n", .{ key, value }));
                wrote = true;
            }
            in_section = std.mem.eql(u8, name, section_name);
            try out.appendSlice(allocator, raw_line);
            try out.append(allocator, '\n');
            continue;
        }
        if (in_section and std.mem.startsWith(u8, trimmed, key)) {
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
                try out.appendSlice(allocator, raw_line);
                try out.append(allocator, '\n');
                continue;
            };
            const existing_key = std.mem.trim(u8, &std.ascii.whitespace, trimmed[0..eq]);
            if (std.mem.eql(u8, existing_key, key)) {
                try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{s} = {s}\n", .{ key, value }));
                wrote = true;
                continue;
            }
        }
        try out.appendSlice(allocator, raw_line);
        try out.append(allocator, '\n');
    }

    if (!wrote) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\n[{s}]\n{s} = {s}\n", .{ section_name, key, value }));
    }

    try workspace.atomic.replaceFile(io, root, wp, out.items);
}

pub fn writeTomlQuotedString(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    var quoted_buf: [512]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{value}) catch {
        return;
    };
    try writeTomlKey(allocator, io, root, section_name, key, quoted);
}

pub fn writeAiProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    provider: []const u8,
) !void {
    try writeTomlQuotedString(allocator, io, root, "ai", "provider", provider);
}

pub fn writeAiModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    model: []const u8,
) !void {
    try writeTomlQuotedString(allocator, io, root, "ai", "model", model);
}

pub fn writeAiMcp(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    enabled: bool,
) !void {
    const value = if (enabled) "true" else "false";
    try writeTomlKey(allocator, io, root, "ai", "mcp", value);
}

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
    _ = root;
    const settings_abs = try workspace.global_store.joinHome(allocator, "settings.toml");
    defer allocator.free(settings_abs);

    const content = workspace.global_store.readAbsoluteFile(allocator, io, settings_abs) catch {
        const default_content = try std.fmt.allocPrint(allocator, "[{s}]\n{s} = {s}\n", .{ section_name, key, value });
        defer allocator.free(default_content);
        try workspace.global_store.replaceAbsoluteFile(io, settings_abs, default_content);
        return;
    };
    defer allocator.free(content);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var in_section = false;
    var wrote = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &std.ascii.whitespace);
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
            const existing_key = std.mem.trim(u8, trimmed[0..eq], &std.ascii.whitespace);
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
        if (in_section) {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{s} = {s}\n", .{ key, value }));
        } else {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\n[{s}]\n{s} = {s}\n", .{ section_name, key, value }));
        }
    }

    try workspace.global_store.replaceAbsoluteFile(io, settings_abs, out.items);
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

pub fn writeAiOllamaUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    url: []const u8,
) !void {
    try writeTomlQuotedString(allocator, io, root, "ai", "ollama_url", url);
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

const std = @import("std");

pub const default_max_bytes: usize = 12 * 1024;

pub fn maxBytesForTool(tool_name: []const u8) usize {
    if (std.mem.eql(u8, tool_name, "list_tree")) return 8 * 1024;
    if (std.mem.eql(u8, tool_name, "read_file")) return 16 * 1024;
    if (std.mem.eql(u8, tool_name, "codebase_search") or std.mem.eql(u8, tool_name, "search")) return 12 * 1024;
    return default_max_bytes;
}

/// Returns an owned slice, truncating long tool output with a footer notice.
pub fn bound(allocator: std.mem.Allocator, tool_name: []const u8, observation: []const u8) ![]u8 {
    const limit = maxBytesForTool(tool_name);
    if (observation.len <= limit) return allocator.dupe(u8, observation);

    const footer = try std.fmt.allocPrint(allocator, "\n\n... [{s} output truncated: {d} -> {d} bytes]\n", .{
        tool_name,
        observation.len,
        limit,
    });
    defer allocator.free(footer);

    const keep = if (limit > footer.len) limit - footer.len else 0;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, observation[0..keep]);
    try out.appendSlice(allocator, footer);
    return try out.toOwnedSlice(allocator);
}

const std = @import("std");

pub const Location = struct {
    path: []const u8,
    line: usize,
};

pub fn parseStopLine(line: []const u8) ?Location {
    const at = std.mem.lastIndexOf(u8, line, " at ") orelse return null;
    const loc = line[at + 4 ..];
    if (loc.len == 0) return null;

    const last_colon = std.mem.lastIndexOf(u8, loc, ":") orelse return null;
    const after_last = loc[last_colon + 1 ..];
    if (after_last.len == 0 or after_last[0] < '0' or after_last[0] > '9') return null;

    const prev = loc[0..last_colon];
    const second_colon = std.mem.lastIndexOf(u8, prev, ":");

    const path_end: usize = if (second_colon) |sc| sc else last_colon;
    const line_str: []const u8 = if (second_colon) |sc| loc[sc + 1 .. last_colon] else after_last;
    const line_num = std.fmt.parseInt(usize, line_str, 10) catch return null;
    const path = loc[0..path_end];
    if (path.len == 0) return null;

    return .{
        .path = path,
        .line = if (line_num > 0) line_num - 1 else 0,
    };
}

pub fn pathsMatch(workspace_rel: []const u8, parsed_path: []const u8) bool {
    if (std.mem.eql(u8, workspace_rel, parsed_path)) return true;
    if (std.mem.endsWith(u8, workspace_rel, parsed_path)) return true;
    const rel_base = std.fs.path.basename(workspace_rel);
    const parsed_base = std.fs.path.basename(parsed_path);
    return std.mem.eql(u8, rel_base, parsed_base);
}

test "parseStopLine extracts file and zero-based line" {
    const line = "frame #0: 0x100003f20 forge`debug`main at apps/forge-ide/src/main.zig:42:5";
    const loc = parseStopLine(line).?;
    try std.testing.expectEqualStrings("apps/forge-ide/src/main.zig", loc.path);
    try std.testing.expectEqual(@as(usize, 41), loc.line);
}

test "pathsMatch accepts basename from lldb" {
    try std.testing.expect(pathsMatch("apps/forge-ide/src/main.zig", "main.zig"));
}

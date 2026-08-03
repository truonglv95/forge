const std = @import("std");
const workspace = @import("forge-workspace");
const contributions_mod = @import("contributions.zig");

pub fn loadThemeOverrides(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    theme: *const contributions_mod.ThemeContribution,
) !workspace.ThemeOverrides {
    const rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ theme.extension_root, theme.path });
    defer allocator.free(rel);
    const wp = try workspace.WorkspacePath.parse(rel);
    var snap = try workspace.FileSnapshot.read(allocator, io, root, wp);
    defer snap.deinit();
    return workspace.ThemeSettings.parseSection(snap.content);
}

test "theme contribution loader compiles" {
    _ = loadThemeOverrides;
}

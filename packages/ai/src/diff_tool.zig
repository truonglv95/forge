const std = @import("std");
const workspace = @import("forge-workspace");
const edit = @import("forge-workspace").edit;

/// Diff tool (RFC-0019).
///
/// Lets the model preview the effect of a proposed edit BEFORE applying it.
/// This is useful when the model wants to verify its search/replace blocks
/// match the actual file content. The diff is returned as a unified diff
/// string that the model can inspect.
///
/// Unlike `replace_file_content` which directly proposes the edit, `diff`
/// only returns the preview — the model must still call
/// `replace_file_content` to actually propose the change.
pub const DiffError = error{
    FileNotFound,
    SearchNotFound,
    OutOfMemory,
    WorkspaceFailed,
};

/// Generate a unified diff for a single search/replace operation.
/// Returns an owned slice (caller frees).
pub fn previewSearchReplace(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    path: []const u8,
    search: []const u8,
    replace: []const u8,
) DiffError![]u8 {
    const wp = workspace.WorkspacePath.parse(path) catch return error.WorkspaceFailed;
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return error.FileNotFound;
    defer snap.deinit();

    // Find the search block in the file content.
    const idx = std.mem.indexOf(u8, snap.content, search) orelse return error.SearchNotFound;

    // Build a unified diff.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const prefix = if (idx > 80) snap.content[idx - 80 .. idx] else snap.content[0..idx];
    const suffix_end = @min(idx + search.len + 80, snap.content.len);
    const suffix = snap.content[idx + search.len .. suffix_end];

    buf.appendSlice(allocator, "--- a/") catch return error.OutOfMemory;
    buf.appendSlice(allocator, path) catch return error.OutOfMemory;
    buf.appendSlice(allocator, "\n+++ b/") catch return error.OutOfMemory;
    buf.appendSlice(allocator, path) catch return error.OutOfMemory;
    buf.appendSlice(allocator, "\n@@ -1,1 +1,1 @@\n") catch return error.OutOfMemory;

    // Context before
    if (prefix.len > 0) {
        var pit = std.mem.splitScalar(u8, prefix, '\n');
        while (pit.next()) |line| {
            if (line.len == 0) continue;
            buf.append(allocator, ' ') catch return error.OutOfMemory;
            buf.appendSlice(allocator, line) catch return error.OutOfMemory;
            buf.append(allocator, '\n') catch return error.OutOfMemory;
        }
    }

    // Removed (search)
    var sit = std.mem.splitScalar(u8, search, '\n');
    while (sit.next()) |line| {
        buf.append(allocator, '-') catch return error.OutOfMemory;
        buf.appendSlice(allocator, line) catch return error.OutOfMemory;
        buf.append(allocator, '\n') catch return error.OutOfMemory;
    }

    // Added (replace)
    var rit = std.mem.splitScalar(u8, replace, '\n');
    while (rit.next()) |line| {
        buf.append(allocator, '+') catch return error.OutOfMemory;
        buf.appendSlice(allocator, line) catch return error.OutOfMemory;
        buf.append(allocator, '\n') catch return error.OutOfMemory;
    }

    // Context after
    if (suffix.len > 0) {
        var suit = std.mem.splitScalar(u8, suffix, '\n');
        while (suit.next()) |line| {
            if (line.len == 0) continue;
            buf.append(allocator, ' ') catch return error.OutOfMemory;
            buf.appendSlice(allocator, line) catch return error.OutOfMemory;
            buf.append(allocator, '\n') catch return error.OutOfMemory;
        }
    }

    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

test "previewSearchReplace generates diff" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("test.zig"),
        \\const x = 42;
        \\fn foo() void {}
        \\pub fn main() void {}
    );

    const diff = try previewSearchReplace(allocator, io, root, "test.zig", "fn foo() void {}", "fn foo() u32 { return 42; }");
    defer allocator.free(diff);

    try std.testing.expect(std.mem.indexOf(u8, diff, "-fn foo() void {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+fn foo() u32 { return 42; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "--- a/test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+++ b/test.zig") != null);
}

test "previewSearchReplace returns SearchNotFound for missing block" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("test.zig"), "hello world\n");

    try std.testing.expectError(error.SearchNotFound, previewSearchReplace(allocator, io, root, "test.zig", "nonexistent", "replacement"));
}

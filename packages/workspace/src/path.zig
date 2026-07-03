const std = @import("std");

pub const WorkspacePath = struct {
    /// A valid, normalized, relative, UTF-8 path string using `/` separators.
    raw: []const u8,

    pub const ValidationError = error{
        AbsolutePath,
        ContainsNullByte,
        InvalidUtf8,
        ContainsEscape,
        InvalidFormat,
    };

    pub fn parse(path: []const u8) ValidationError!WorkspacePath {
        if (path.len == 0) return WorkspacePath{ .raw = "" };
        if (std.mem.startsWith(u8, path, "/")) return error.AbsolutePath;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.ContainsNullByte;
        if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;

        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, "..")) return error.ContainsEscape;
            if (std.mem.eql(u8, component, ".")) return error.InvalidFormat;
            if (component.len == 0) return error.InvalidFormat; // e.g., "a//b" or leading/trailing slash
            if (std.mem.indexOfScalar(u8, component, '\\') != null) return error.InvalidFormat;
        }

        return WorkspacePath{ .raw = path };
    }
};

pub const WorkspaceRoot = struct {
    dir: std.Io.Dir,

    pub fn init(dir: std.Io.Dir) WorkspaceRoot {
        return .{ .dir = dir };
    }

    pub fn open(io: std.Io, workspace_path: []const u8) std.Io.Dir.OpenError!WorkspaceRoot {
        const open_opts = std.Io.Dir.OpenOptions{
            .access_sub_paths = true,
            .iterate = true,
        };
        const dir = if (std.fs.path.isAbsolute(workspace_path))
            try std.Io.Dir.openDirAbsolute(io, workspace_path, open_opts)
        else
            try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, workspace_path, open_opts);
        return .{ .dir = dir };
    }

    pub fn close(self: *WorkspaceRoot, io: std.Io) void {
        self.dir.close(io);
        self.* = undefined;
    }
};

test "WorkspacePath validates safe relative paths" {
    const valid_paths = [_][]const u8{
        "",
        "src",
        "src/main.zig",
        "nested/dir/file.txt",
    };

    for (valid_paths) |p| {
        const wp = try WorkspacePath.parse(p);
        try std.testing.expectEqualStrings(p, wp.raw);
    }
}

test "WorkspacePath rejects unsafe and invalid paths" {
    try std.testing.expectError(error.AbsolutePath, WorkspacePath.parse("/etc/passwd"));
    try std.testing.expectError(error.ContainsNullByte, WorkspacePath.parse("src/main\x00.zig"));
    try std.testing.expectError(error.InvalidUtf8, WorkspacePath.parse("src/\xFF\xFE.zig"));
    try std.testing.expectError(error.ContainsEscape, WorkspacePath.parse("../outside.txt"));
    try std.testing.expectError(error.ContainsEscape, WorkspacePath.parse("src/../../outside.txt"));
    try std.testing.expectError(error.InvalidFormat, WorkspacePath.parse("./src"));
    try std.testing.expectError(error.InvalidFormat, WorkspacePath.parse("src//main.zig"));
    try std.testing.expectError(error.InvalidFormat, WorkspacePath.parse("src/main.zig/"));
    try std.testing.expectError(error.InvalidFormat, WorkspacePath.parse("src\\main.zig"));
}

test "WorkspaceRoot initializes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = WorkspaceRoot.init(tmp.dir);
    _ = root;
}

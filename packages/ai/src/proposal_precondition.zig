const std = @import("std");
const workspace = @import("forge-workspace");

const JsonEdit = struct {
    start: u64 = 0,
    end: u64 = 0,
    search: ?[]const u8 = null,
    replacement: []const u8,
};

const JsonFile = struct {
    path: []const u8,
    operation: []const u8,
    expected_hash: ?u64 = null,
    edits: []JsonEdit = &.{},
};

const JsonRoot = struct {
    schema_version: ?u32 = null,
    summary: ?[]const u8 = null,
    assumptions: ?[]const []const u8 = null,
    validation_tasks: ?[]const []const u8 = null,
    workspace_edit: ?struct { files: []JsonFile = &.{} } = null,
    files: ?[]JsonFile = null,
};

/// Fills missing expected_hash values for modify/delete edits from live workspace snapshots.
pub fn fillMissingExpectedHashes(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    proposal_body: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(JsonRoot, allocator, proposal_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const source_files = if (parsed.value.workspace_edit) |ws|
        ws.files
    else if (parsed.value.files) |legacy|
        legacy
    else
        return try allocator.dupe(u8, proposal_body);

    var changed = false;
    var out_files = try allocator.alloc(JsonFile, source_files.len);
    defer allocator.free(out_files);

    for (source_files, 0..) |src, index| {
        var expected_hash = src.expected_hash;
        if (expected_hash == null and needsPrecondition(src.operation)) {
            if (workspace.WorkspacePath.parse(src.path)) |wp| {
                var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch continue;
                defer snap.deinit();
                expected_hash = snap.hash;
                changed = true;
            } else |_| {}
        }
        out_files[index] = .{
            .path = src.path,
            .operation = src.operation,
            .expected_hash = expected_hash,
            .edits = src.edits,
        };
    }

    if (!changed) return try allocator.dupe(u8, proposal_body);

    const WorkspaceEditOut = struct { files: []const JsonFile };
    const Out = struct {
        schema_version: ?u32,
        summary: ?[]const u8,
        assumptions: ?[]const []const u8,
        validation_tasks: ?[]const []const u8,
        workspace_edit: ?WorkspaceEditOut,
        files: ?[]const JsonFile,
    };

    const workspace_edit = if (parsed.value.workspace_edit != null)
        WorkspaceEditOut{ .files = out_files }
    else
        null;

    return try std.json.Stringify.valueAlloc(allocator, Out{
        .schema_version = parsed.value.schema_version,
        .summary = parsed.value.summary,
        .assumptions = parsed.value.assumptions,
        .validation_tasks = parsed.value.validation_tasks,
        .workspace_edit = workspace_edit,
        .files = if (parsed.value.files != null) out_files else null,
    }, .{});
}

fn needsPrecondition(operation: []const u8) bool {
    return std.mem.eql(u8, operation, "modify") or std.mem.eql(u8, operation, "delete");
}

test "fillMissingExpectedHashes injects hash for modify" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "const x = 1;\n" });

    const body =
        \\{"schema_version":1,"summary":"add comment","workspace_edit":{"files":[{"path":"build.zig","operation":"modify","edits":[{"start":0,"end":0,"replacement":"// hi\n"}]}]}}
    ;

    const out = try fillMissingExpectedHashes(allocator, io, root, body);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"expected_hash\"") != null);
}

test "fillMissingExpectedHashes accepts search replace edits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "pub fn oldName() void {}\n" });

    const body =
        \\{"schema_version":1,"summary":"rename","workspace_edit":{"files":[{"path":"main.zig","operation":"modify","edits":[{"search":"pub fn oldName() void {}\n","replacement":"pub fn newName() void {}\n"}]}]}}
    ;

    const out = try fillMissingExpectedHashes(allocator, io, root, body);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"expected_hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"search\"") != null);
}

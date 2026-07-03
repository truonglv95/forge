const std = @import("std");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");

pub const schema_version: u32 = 1;

pub const Metadata = struct {
    schema_version: ?u32 = null,
    summary: ?[]const u8 = null,
    assumptions: []const []const u8 = &.{},
    validation_tasks: []const []const u8 = &.{},
};

pub const OwnedProposal = struct {
    allocator: std.mem.Allocator,
    files: []edit.FileEdit,
    metadata: Metadata = .{},

    pub fn deinit(self: *OwnedProposal) void {
        for (self.files) |file| {
            self.allocator.free(file.path);
            for (file.edits) |text_edit| self.allocator.free(text_edit.replacement);
            self.allocator.free(file.edits);
        }
        self.allocator.free(self.files);
        if (self.metadata.summary) |summary| self.allocator.free(summary);
        for (self.metadata.assumptions) |item| self.allocator.free(item);
        self.allocator.free(self.metadata.assumptions);
        for (self.metadata.validation_tasks) |item| self.allocator.free(item);
        self.allocator.free(self.metadata.validation_tasks);
        self.* = undefined;
    }

    pub fn workspaceEdit(self: *const OwnedProposal) edit.WorkspaceEdit {
        return .{ .files = self.files };
    }

    pub fn parseJson(allocator: std.mem.Allocator, source: []const u8) !OwnedProposal {
        const JsonEdit = struct { start: u64, end: u64, replacement: []const u8 };
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

        var parsed = try std.json.parseFromSlice(JsonRoot, allocator, source, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const json_files = if (parsed.value.workspace_edit) |ws|
            ws.files
        else if (parsed.value.files) |legacy|
            legacy
        else
            return error.InvalidProposal;

        const files = try allocator.alloc(edit.FileEdit, json_files.len);
        errdefer allocator.free(files);

        for (json_files, 0..) |json_file, file_index| {
            const operation = std.meta.stringToEnum(edit.FileOperation, json_file.operation) orelse return error.InvalidProposal;
            const edits = try allocator.alloc(edit.TextEdit, json_file.edits.len);
            errdefer allocator.free(edits);

            for (json_file.edits, 0..) |json_edit, edit_index| {
                edits[edit_index] = .{
                    .start = json_edit.start,
                    .end = json_edit.end,
                    .replacement = try allocator.dupe(u8, json_edit.replacement),
                };
            }

            files[file_index] = .{
                .path = try allocator.dupe(u8, json_file.path),
                .operation = operation,
                .expected_hash = json_file.expected_hash,
                .edits = edits,
            };
        }

        const summary = if (parsed.value.summary) |s| try allocator.dupe(u8, s) else null;
        errdefer if (summary) |owned| allocator.free(owned);

        const assumptions = try dupeStringSlice(allocator, parsed.value.assumptions orelse &.{});
        errdefer freeStringSlice(allocator, assumptions);

        const validation_tasks = try dupeStringSlice(allocator, parsed.value.validation_tasks orelse &.{});
        errdefer freeStringSlice(allocator, validation_tasks);

        return .{
            .allocator = allocator,
            .files = files,
            .metadata = .{
                .schema_version = parsed.value.schema_version,
                .summary = summary,
                .assumptions = assumptions,
                .validation_tasks = validation_tasks,
            },
        };
    }

    pub fn readPath(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, proposal_path: []const u8) !OwnedProposal {
        const wp = try path_mod.WorkspacePath.parse(proposal_path);
        var snap = try snapshot.FileSnapshot.read(allocator, io, root, wp);
        defer snap.deinit();
        return parseJson(allocator, snap.content);
    }
};

fn dupeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const owned = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(owned);
    for (items, 0..) |item, index| {
        owned[index] = try allocator.dupe(u8, item);
    }
    return owned;
}

fn freeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

test "proposal json parses legacy workspace edit" {
    const source =
        \\{"files":[{"path":"notes.txt","operation":"modify","expected_hash":1,"edits":[{"start":0,"end":1,"replacement":"b"}]}]}
    ;
    var proposal = try OwnedProposal.parseJson(std.testing.allocator, source);
    defer proposal.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposal.files.len);
    try std.testing.expectEqualStrings("notes.txt", proposal.files[0].path);
    try std.testing.expect(proposal.metadata.summary == null);
}

test "proposal json parses schema v1 envelope" {
    const source =
        \\{"schema_version":1,"summary":"Create notes","assumptions":["sample.txt unchanged"],"validation_tasks":["zig build test"],"workspace_edit":{"files":[{"path":"notes.txt","operation":"create","edits":[{"start":0,"end":0,"replacement":"hi"}]}]}}
    ;
    var proposal = try OwnedProposal.parseJson(std.testing.allocator, source);
    defer proposal.deinit();
    try std.testing.expectEqual(@as(u32, 1), proposal.metadata.schema_version.?);
    try std.testing.expectEqualStrings("Create notes", proposal.metadata.summary.?);
    try std.testing.expectEqual(@as(usize, 1), proposal.metadata.assumptions.len);
    try std.testing.expectEqualStrings("zig build test", proposal.metadata.validation_tasks[0]);
    try std.testing.expectEqual(@as(usize, 1), proposal.files.len);
}

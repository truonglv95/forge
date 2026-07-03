const std = @import("std");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");

pub const OwnedProposal = struct {
    allocator: std.mem.Allocator,
    files: []edit.FileEdit,

    pub fn deinit(self: *OwnedProposal) void {
        for (self.files) |file| {
            self.allocator.free(file.path);
            for (file.edits) |text_edit| self.allocator.free(text_edit.replacement);
            self.allocator.free(file.edits);
        }
        self.allocator.free(self.files);
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
        const JsonRoot = struct { files: []JsonFile };

        var parsed = try std.json.parseFromSlice(JsonRoot, allocator, source, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const files = try allocator.alloc(edit.FileEdit, parsed.value.files.len);
        errdefer allocator.free(files);

        for (parsed.value.files, 0..) |json_file, file_index| {
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

        return .{ .allocator = allocator, .files = files };
    }

    pub fn readPath(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, proposal_path: []const u8) !OwnedProposal {
        const wp = try path_mod.WorkspacePath.parse(proposal_path);
        var snap = try snapshot.FileSnapshot.read(allocator, io, root, wp);
        defer snap.deinit();
        return parseJson(allocator, snap.content);
    }
};

test "proposal json parses owned workspace edit" {
    const source =
        \\{"files":[{"path":"notes.txt","operation":"modify","expected_hash":1,"edits":[{"start":0,"end":1,"replacement":"b"}]}]}
    ;
    var proposal = try OwnedProposal.parseJson(std.testing.allocator, source);
    defer proposal.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposal.files.len);
    try std.testing.expectEqualStrings("notes.txt", proposal.files[0].path);
}

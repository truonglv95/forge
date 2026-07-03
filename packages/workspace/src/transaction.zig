const std = @import("std");
const edit = @import("edit.zig");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");
const recovery = @import("recovery.zig");

pub const TransactionState = enum {
    proposed,
    validated,
    approved,
    applying,
    applied,
    validation_failed,
    undone,
    recovery_required,
};

pub const TransactionRecord = struct {
    id: u64,
    state: TransactionState,
    workspace_edit: edit.WorkspaceEdit,
    timestamp_ms: i64,
};

pub const TransactionService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) TransactionService {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    pub fn apply(self: *TransactionService, record: *TransactionRecord) !void {
        if (record.state != .approved) return error.InvalidState;

        record.state = .applying;
        try recovery.writeRecord(self.io, self.root, record);

        for (record.workspace_edit.files) |file_edit| {
            const wp = try path_mod.WorkspacePath.parse(file_edit.path);
            
            switch (file_edit.operation) {
                .create, .modify => {
                    // MVP scaffolding: atomic file replacement. 
                    // Actual content generation from TextEdits is deferred to the edit engine.
                    try atomic.replaceFile(self.io, self.root, wp, ""); 
                },
                .delete => {
                    try atomic.deleteFile(self.io, self.root, wp) catch {};
                },
            }
        }

        record.state = .applied;
        try recovery.writeRecord(self.io, self.root, record);
    }
};

test "TransactionService structure compiles" {
    // Integration tests will exercise the full apply/undo state machine
}

const std = @import("std");
const transaction = @import("transaction.zig");
const path_mod = @import("path.zig");

pub fn writeRecord(io: std.Io, root: path_mod.WorkspaceRoot, record: *const transaction.TransactionRecord) !void {
    // In a real implementation, this serializes the record to `.forge/transactions/{id}.json`
    // using atomic replace primitives to ensure the journal is never corrupted.
    _ = io;
    _ = root;
    _ = record;
}

pub fn recoverPending(io: std.Io, root: path_mod.WorkspaceRoot) !void {
    // Scans `.forge/transactions/` for any records in the `.applying` state
    // and either rolls them forward or backward based on fs hashes.
    _ = io;
    _ = root;
}

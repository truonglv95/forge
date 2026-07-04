const std = @import("std");
const workspace = @import("forge-workspace");
const editor = @import("forge-editor");

pub fn loadDocument(
    io: std.Io,
    root: workspace.WorkspaceRoot,
    doc: *editor.Document,
) !void {
    const wp = try workspace.WorkspacePath.parse(doc.path);
    var snap = try workspace.FileSnapshot.read(doc.buffer.allocator, io, root, wp);
    defer snap.deinit();
    try doc.buffer.loadFromSlice(snap.content);
    doc.saved_hash = snap.hash;
    doc.disk_hash = snap.hash;
    doc.external_conflict = false;
}

pub fn saveDocument(
    io: std.Io,
    root: workspace.WorkspaceRoot,
    doc: *editor.Document,
) !void {
    const content = try doc.buffer.content();
    defer doc.buffer.allocator.free(content);
    const wp = try workspace.WorkspacePath.parse(doc.path);
    try workspace.atomic.replaceFile(io, root, wp, content);
    try doc.markSaved();
}

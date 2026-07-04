const std = @import("std");
const workspace = @import("forge-workspace");
const context_loader = @import("context_loader.zig");
const provider = @import("provider.zig");

pub fn mimeFromPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    return "image/png";
}

pub fn loadImages(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    attachments: []const context_loader.AttachmentInput,
) ![]provider.ImagePart {
    var list: std.ArrayList(provider.ImagePart) = .empty;
    errdefer freeImages(allocator, list.items);

    for (attachments) |attachment| {
        if (attachment.kind != .image) continue;
        const rel = attachment.stored_path orelse continue;
        const wp = workspace.WorkspacePath.parse(rel) catch continue;
        var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();
        if (snap.content.len == 0) continue;

        const encoder = std.base64.standard.Encoder;
        var b64_writer = std.Io.Writer.Allocating.init(allocator);
        defer b64_writer.deinit();
        encoder.encodeWriter(&b64_writer.writer, snap.content) catch continue;
        const encoded = allocator.dupe(u8, b64_writer.writer.buffer[0..b64_writer.writer.end]) catch continue;
        errdefer allocator.free(encoded);

        try list.append(allocator, .{
            .mime_type = try allocator.dupe(u8, mimeFromPath(rel)),
            .data_base64 = encoded,
        });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn freeImages(allocator: std.mem.Allocator, images: []const provider.ImagePart) void {
    for (images) |image| {
        allocator.free(image.mime_type);
        allocator.free(image.data_base64);
    }
    allocator.free(images);
}

test "mimeFromPath detects png" {
    try std.testing.expectEqualStrings("image/png", mimeFromPath("att.png"));
    try std.testing.expectEqualStrings("image/jpeg", mimeFromPath("photo.jpg"));
}

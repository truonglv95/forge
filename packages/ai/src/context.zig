const std = @import("std");
const secret_scanner = @import("secret_scanner.zig");

pub const BlockType = enum {
    file,
    intent,
    diagnostic,
    rules,
    attachment,
    retrieval,
    git_diff,
    recent,
    semantic,
    imports,
    lsp,
    docs,
    fused,
    expansion,
    memory,
    web,
};

pub const ContextBlock = struct {
    block_type: BlockType,
    name: []const u8,
    content: []const u8,
    is_truncated: bool = false,
    detail: ?[]const u8 = null,
};

pub const ManifestExtra = struct {
    kind: BlockType,
    name: []const u8,
    detail: []const u8,
    bytes: usize = 0,
};

pub const ContextBuilder = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    used_bytes: usize,
    blocks: std.ArrayList(ContextBlock),
    rejected: std.StringHashMap([]const u8),
    manifest_extras: std.ArrayList(ManifestExtra),

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) ContextBuilder {
        return .{
            .allocator = allocator,
            .max_bytes = max_bytes,
            .used_bytes = 0,
            .blocks = .empty,
            .rejected = std.StringHashMap([]const u8).init(allocator),
            .manifest_extras = .empty,
        };
    }

    pub fn deinit(self: *ContextBuilder) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block.name);
            self.allocator.free(block.content);
            if (block.detail) |detail| self.allocator.free(detail);
        }
        self.blocks.deinit(self.allocator);
        for (self.manifest_extras.items) |extra| {
            self.allocator.free(extra.name);
            self.allocator.free(extra.detail);
        }
        self.manifest_extras.deinit(self.allocator);
        var reject_it = self.rejected.iterator();
        while (reject_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.rejected.deinit();
    }

    pub fn addManifestExtra(
        self: *ContextBuilder,
        kind: BlockType,
        name: []const u8,
        detail: []const u8,
        bytes: usize,
    ) !void {
        try self.manifest_extras.append(self.allocator, .{
            .kind = kind,
            .name = try self.allocator.dupe(u8, name),
            .detail = try self.allocator.dupe(u8, detail),
            .bytes = bytes,
        });
    }

    pub fn addBlock(self: *ContextBuilder, btype: BlockType, name: []const u8, content: []const u8) !void {
        try self.addBlockWithDetail(btype, name, content, null);
    }

    pub fn addBlockWithDetail(
        self: *ContextBuilder,
        btype: BlockType,
        name: []const u8,
        content: []const u8,
        detail: ?[]const u8,
    ) !void {
        // 1. Check if the file is a known secret file
        if (btype == .file and secret_scanner.isSecretFile(name)) {
            try self.rejected.put(try self.allocator.dupe(u8, name), "Secret file extension or name detected");
            return;
        }

        // 2. Scan content for secrets
        if (secret_scanner.scan(content)) |_| {
            // Safe
        } else |err| {
            if (err == error.ContainsSecret) {
                try self.rejected.put(try self.allocator.dupe(u8, name), "Contains secret pattern");
                return;
            }
        }

        // 3. Handle capacity and truncation
        if (self.used_bytes >= self.max_bytes) {
            try self.rejected.put(try self.allocator.dupe(u8, name), "Context byte budget exceeded");
            return;
        }

        const remaining = self.max_bytes - self.used_bytes;
        const take_len = @min(content.len, remaining);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_content = try self.allocator.dupe(u8, content[0..take_len]);
        errdefer self.allocator.free(owned_content);
        const owned_detail = if (detail) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (owned_detail) |text| self.allocator.free(text);

        try self.blocks.append(self.allocator, .{
            .block_type = btype,
            .name = owned_name,
            .content = owned_content,
            .is_truncated = content.len > remaining,
            .detail = owned_detail,
        });
        self.used_bytes += owned_content.len;
    }
};

test "ContextBuilder budget and truncation" {
    const allocator = std.testing.allocator;
    var builder = ContextBuilder.init(allocator, 20);
    defer builder.deinit();

    try builder.addBlock(.file, "safe.txt", "123456789012345"); // 15 bytes
    try std.testing.expectEqual(@as(usize, 1), builder.blocks.items.len);
    try std.testing.expect(!builder.blocks.items[0].is_truncated);

    // Only 5 bytes left
    try builder.addBlock(.file, "long.txt", "1234567890");
    try std.testing.expectEqual(@as(usize, 2), builder.blocks.items.len);
    try std.testing.expect(builder.blocks.items[1].is_truncated);
    try std.testing.expectEqualStrings("12345", builder.blocks.items[1].content);

    // 0 bytes left
    try builder.addBlock(.file, "rejected.txt", "abc");
    try std.testing.expect(builder.rejected.contains("rejected.txt"));
}

test "ContextBuilder blocks secrets" {
    const allocator = std.testing.allocator;
    var builder = ContextBuilder.init(allocator, 1000);
    defer builder.deinit();

    try builder.addBlock(.file, ".env", "FOO=bar");
    try std.testing.expect(builder.rejected.contains(".env"));

    try builder.addBlock(.file, "main.zig", "const sk = \"sk-12345\";");
    try std.testing.expect(builder.rejected.contains("main.zig"));

    try std.testing.expectEqual(@as(usize, 0), builder.blocks.items.len);
}

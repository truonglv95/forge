const std = @import("std");
const secret_scanner = @import("secret_scanner.zig");

pub const BlockType = enum {
    file,
    intent,
    diagnostic,
};

pub const ContextBlock = struct {
    block_type: BlockType,
    name: []const u8,
    content: []const u8,
    is_truncated: bool = false,
};

pub const ContextBuilder = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    used_bytes: usize,
    blocks: std.ArrayList(ContextBlock),
    rejected: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) ContextBuilder {
        return .{
            .allocator = allocator,
            .max_bytes = max_bytes,
            .used_bytes = 0,
            .blocks = .empty,
            .rejected = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ContextBuilder) void {
        self.blocks.deinit(self.allocator);
        self.rejected.deinit();
    }

    pub fn addBlock(self: *ContextBuilder, btype: BlockType, name: []const u8, content: []const u8) !void {
        // 1. Check if the file is a known secret file
        if (btype == .file and secret_scanner.isSecretFile(name)) {
            try self.rejected.put(name, "Secret file extension or name detected");
            return;
        }
        
        // 2. Scan content for secrets
        if (secret_scanner.scan(content)) |_| {
            // Safe
        } else |err| {
            if (err == error.ContainsSecret) {
                try self.rejected.put(name, "Contains secret pattern");
                return;
            }
        }
        
        // 3. Handle capacity and truncation
        if (self.used_bytes >= self.max_bytes) {
            try self.rejected.put(name, "Context byte budget exceeded");
            return;
        }
        
        var block = ContextBlock{
            .block_type = btype,
            .name = name,
            .content = content,
            .is_truncated = false,
        };
        
        const remaining = self.max_bytes - self.used_bytes;
        if (content.len > remaining) {
            block.content = content[0..remaining];
            block.is_truncated = true;
        }
        
        try self.blocks.append(self.allocator, block);
        self.used_bytes += block.content.len;
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

//! Mention resolver — parses `@file:`, `@symbol:`, `@folder:`, `@web:`
//! tokens from a prompt and resolves them to context blocks that get
//! attached to the agent's context bundle.
//!
//! When the user submits a prompt, we scan it for mention tokens and:
//!   - @file:<path>     → read file content, attach as context block
//!   - @symbol:<name>   → query LSP workspace_symbol, attach definition
//!   - @folder:<path>   → list folder tree (depth-limited), attach
//!   - @web:<query>     → fetch web search results (best-effort)
//!
//! The resolved context is returned as an array of ResolvedMention
//! structs. The caller (agent_submit dispatch) passes these to
//! spawnGenerate as scope_files / extra context.

const std = @import("std");
const workspace = @import("forge-workspace");

pub const MentionKind = enum {
    file,
    symbol,
    folder,
    web,
};

pub const ResolvedMention = struct {
    kind: MentionKind,
    /// The original token (e.g. "@file:src/main.zig").
    token: []const u8,
    /// Human-readable label for UI display (e.g. "src/main.zig").
    label: []const u8,
    /// Resolved content (file text, symbol definition, folder listing,
    /// web snippet). Owned.
    content: []const u8,
    /// Whether resolution succeeded. When false, `content` is an error
    /// message.
    ok: bool = true,

    pub fn deinit(self: *ResolvedMention, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.label);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const ResolvedList = struct {
    items: []ResolvedMention,

    pub fn deinit(self: *ResolvedList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Scan `prompt` for mention tokens and return them as a list of
/// (kind, token, label) tuples. The caller can then resolve each.
/// Tokens are slices into `prompt` (not owned).
pub const ParsedMention = struct {
    kind: MentionKind,
    /// Start index of the token in the prompt (including the `@`).
    start: usize,
    /// End index (exclusive).
    end: usize,
    /// The label part (after the `:`). Slice into prompt.
    label: []const u8,
};

pub fn parseMentions(allocator: std.mem.Allocator, prompt: []const u8) ![]ParsedMention {
    var out: std.ArrayList(ParsedMention) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < prompt.len) {
        if (prompt[i] != '@') {
            i += 1;
            continue;
        }
        // Find the kind prefix.
        const kind_end = blk: {
            var j = i + 1;
            while (j < prompt.len and (std.ascii.isAlphabetic(prompt[j]) or prompt[j] == '_')) : (j += 1) {}
            break :blk j;
        };
        if (kind_end == i + 1) {
            i += 1;
            continue;
        }
        const kind_str = prompt[i + 1 .. kind_end];
        const kind: ?MentionKind = blk: {
            if (std.mem.eql(u8, kind_str, "file")) break :blk .file;
            if (std.mem.eql(u8, kind_str, "symbol")) break :blk .symbol;
            if (std.mem.eql(u8, kind_str, "folder")) break :blk .folder;
            if (std.mem.eql(u8, kind_str, "web")) break :blk .web;
            break :blk null;
        };
        if (kind == null) {
            i = kind_end;
            continue;
        }
        // Expect a colon after the kind.
        if (kind_end >= prompt.len or prompt[kind_end] != ':') {
            i = kind_end;
            continue;
        }
        // Find end of label (whitespace or end of string).
        var label_end = kind_end + 1;
        while (label_end < prompt.len and !std.ascii.isWhitespace(prompt[label_end])) : (label_end += 1) {}
        const label = prompt[kind_end + 1 .. label_end];
        if (label.len == 0) {
            i = label_end;
            continue;
        }
        try out.append(allocator, .{
            .kind = kind.?,
            .start = i,
            .end = label_end,
            .label = label,
        });
        i = label_end;
    }

    return out.toOwnedSlice(allocator);
}

/// Resolve all mentions in a prompt. Returns owned ResolvedMention array.
/// `root` is the workspace root for file/folder resolution.
/// `io` is needed for file reads.
pub fn resolveMentions(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    prompt: []const u8,
) !ResolvedList {
    const parsed = try parseMentions(allocator, prompt);
    defer allocator.free(parsed);

    var out: std.ArrayList(ResolvedMention) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (parsed) |p| {
        const token = try allocator.dupe(u8, prompt[p.start..p.end]);
        errdefer allocator.free(token);
        const label = try allocator.dupe(u8, p.label);
        errdefer allocator.free(label);

        switch (p.kind) {
            .file => {
                const content = readFileContent(allocator, io, root, p.label) catch |err| blk: {
                    const msg = std.fmt.allocPrint(allocator, "Failed to read {s}: {s}", .{ p.label, @errorName(err) }) catch break :blk try allocator.dupe(u8, "File read failed");
                    break :blk msg;
                };
                try out.append(allocator, .{
                    .kind = .file,
                    .token = token,
                    .label = label,
                    .content = content,
                    .ok = std.mem.indexOf(u8, content, "Failed to read") == null,
                });
            },
            .symbol => {
                // Symbol resolution requires LSP — we return a placeholder
                // that the agent can use. The LSP query happens in the
                // caller (workbench has access to lsp_proxy).
                const content = try std.fmt.allocPrint(allocator, "Symbol: {s}\n(Use lsp_workspace_symbol tool to find definition)", .{p.label});
                try out.append(allocator, .{
                    .kind = .symbol,
                    .token = token,
                    .label = label,
                    .content = content,
                    .ok = true,
                });
            },
            .folder => {
                const content = listFolderTree(allocator, io, root, p.label) catch |err| blk: {
                    const msg = std.fmt.allocPrint(allocator, "Failed to list {s}: {s}", .{ p.label, @errorName(err) }) catch break :blk try allocator.dupe(u8, "Folder list failed");
                    break :blk msg;
                };
                try out.append(allocator, .{
                    .kind = .folder,
                    .token = token,
                    .label = label,
                    .content = content,
                    .ok = std.mem.indexOf(u8, content, "Failed to list") == null,
                });
            },
            .web => {
                // Web resolution requires fetch_url tool — return a hint.
                const content = try std.fmt.allocPrint(allocator, "Web search query: {s}\n(Use fetch_url tool to retrieve specific URLs)", .{p.label});
                try out.append(allocator, .{
                    .kind = .web,
                    .token = token,
                    .label = label,
                    .content = content,
                    .ok = true,
                });
            },
        }
    }

    return .{ .items = try out.toOwnedSlice(allocator) };
}

fn readFileContent(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, path: []const u8) ![]u8 {
    var file = root.dir.openFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    // Cap at 256KB to avoid loading huge files.
    const cap: usize = @min(size, 256 * 1024);
    const content = try allocator.alloc(u8, cap);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    return content[0..read_len];
}

fn listFolderTree(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Folder tree for ");
    try out.appendSlice(allocator, path);
    try out.appendSlice(allocator, ":\n");

    var dir = root.dir.openDir(io, path, .{ .access_sub_paths = true, .iterate = true }) catch return error.DirNotFound;
    defer dir.close(io);

    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (count >= 100) {
            try out.appendSlice(allocator, "... (truncated at 100 entries)\n");
            break;
        }
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, entry.name);
        try out.append(allocator, '\n');
        count += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Build a context preamble string from resolved mentions. This gets
/// prepended to the user's prompt so the agent sees the mentioned
/// content.
pub fn buildContextPreamble(allocator: std.mem.Allocator, mentions: []const ResolvedMention) ![]u8 {
    if (mentions.len == 0) return try allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "--- Mentioned context ---\n\n");

    for (mentions) |m| {
        const kind_label = switch (m.kind) {
            .file => "File",
            .symbol => "Symbol",
            .folder => "Folder",
            .web => "Web",
        };
        try out.appendSlice(allocator, kind_label);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, m.label);
        try out.appendSlice(allocator, "\n```\n");
        // Cap content at 4KB per mention to avoid context bloat.
        const cap = @min(m.content.len, 4096);
        try out.appendSlice(allocator, m.content[0..cap]);
        if (m.content.len > 4096) {
            try out.appendSlice(allocator, "\n... (truncated)");
        }
        try out.appendSlice(allocator, "\n```\n\n");
    }

    try out.appendSlice(allocator, "--- End mentioned context ---\n\n");
    return out.toOwnedSlice(allocator);
}

test "parseMentions extracts file and symbol tokens" {
    const allocator = std.testing.allocator;
    const prompt = "Look at @file:src/main.zig and find @symbol:main";
    const parsed = try parseMentions(allocator, prompt);
    defer allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(MentionKind.file, parsed[0].kind);
    try std.testing.expectEqualStrings("src/main.zig", parsed[0].label);
    try std.testing.expectEqual(MentionKind.symbol, parsed[1].kind);
    try std.testing.expectEqualStrings("main", parsed[1].label);
}

test "parseMentions handles folder and web" {
    const allocator = std.testing.allocator;
    const prompt = "List @folder:src and search @web:how to parse JSON in zig";
    const parsed = try parseMentions(allocator, prompt);
    defer allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(MentionKind.folder, parsed[0].kind);
    try std.testing.expectEqualStrings("src", parsed[0].label);
    try std.testing.expectEqual(MentionKind.web, parsed[1].kind);
    try std.testing.expectEqualStrings("how", parsed[1].label); // stops at space
}

test "parseMentions ignores @ without valid kind" {
    const allocator = std.testing.allocator;
    const prompt = "Email me @user@example.com and @file:ok";
    const parsed = try parseMentions(allocator, prompt);
    defer allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expectEqual(MentionKind.file, parsed[0].kind);
}

test "parseMentions handles no mentions" {
    const allocator = std.testing.allocator;
    const parsed = try parseMentions(allocator, "no mentions here");
    defer allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 0), parsed.len);
}

test "buildContextPreamble returns empty for no mentions" {
    const allocator = std.testing.allocator;
    const preamble = try buildContextPreamble(allocator, &.{});
    defer allocator.free(preamble);
    try std.testing.expectEqualStrings("", preamble);
}

test "buildContextPreamble formats mentions" {
    const allocator = std.testing.allocator;
    var mentions = [_]ResolvedMention{
        .{
            .kind = .file,
            .token = try allocator.dupe(u8, "@file:src/main.zig"),
            .label = try allocator.dupe(u8, "src/main.zig"),
            .content = try allocator.dupe(u8, "fn main() {}"),
        },
    };
    defer for (&mentions) |*m| m.deinit(allocator);
    const preamble = try buildContextPreamble(allocator, &mentions);
    defer allocator.free(preamble);
    try std.testing.expect(std.mem.indexOf(u8, preamble, "File: src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, "fn main() {}") != null);
}

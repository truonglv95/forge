const std = @import("std");

pub const CursorPosition = struct {
    path: []const u8,
    line: u32,
    character: u32,
};

pub const DiagnosticEntry = struct {
    path: []const u8,
    line: u32,
    character: u32,
    severity: []const u8,
    message: []const u8,
};

pub const LspHint = struct {
    kind: enum { definition, reference },
    path: []const u8,
    line: u32,
    character: u32,
};

pub const Supplement = struct {
    cursor: ?CursorPosition = null,
    diagnostics: []const DiagnosticEntry = &.{},
    lsp_hints: []const LspHint = &.{},
    hover_text: ?[]const u8 = null,
    /// Kiro-style spec block — when non-null, the agent will inject the
    /// spec's requirements + design + tasks into the context. This is the
    /// "specs → implementation → hooks" loop: the agent sees the approved
    /// spec and implements against it.
    spec_block: ?[]const u8 = null,
};

pub fn formatDiagnosticsBlock(allocator: std.mem.Allocator, entries: []const DiagnosticEntry) !?[]const u8 {
    if (entries.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Workspace diagnostics\n\n");

    for (entries) |entry| {
        const line = try std.fmt.allocPrint(allocator, "- {s}:{d}:{d} [{s}] {s}\n", .{
            entry.path,
            entry.line + 1,
            entry.character + 1,
            entry.severity,
            entry.message,
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn formatLspBlock(allocator: std.mem.Allocator, supplement: Supplement) !?[]const u8 {
    if (supplement.lsp_hints.len == 0 and supplement.cursor == null and supplement.hover_text == null) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# LSP context\n\n");

    if (supplement.cursor) |cursor| {
        const line = try std.fmt.allocPrint(allocator, "cursor: {s}:{d}:{d}\n", .{
            cursor.path,
            cursor.line + 1,
            cursor.character + 1,
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    if (supplement.hover_text) |hover| {
        const line = try std.fmt.allocPrint(allocator, "hover: {s}\n", .{hover});
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    for (supplement.lsp_hints) |hint| {
        const kind = switch (hint.kind) {
            .definition => "definition",
            .reference => "reference",
        };
        const line = try std.fmt.allocPrint(allocator, "{s}: {s}:{d}:{d}\n", .{
            kind,
            hint.path,
            hint.line + 1,
            hint.character + 1,
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeDiagnosticEntries(allocator: std.mem.Allocator, entries: []const DiagnosticEntry) void {
    for (entries) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.severity);
        allocator.free(entry.message);
    }
    allocator.free(entries);
}

pub fn freeLspHints(allocator: std.mem.Allocator, hints: []const LspHint) void {
    for (hints) |hint| allocator.free(hint.path);
    allocator.free(hints);
}

pub fn freeSupplement(allocator: std.mem.Allocator, supplement: Supplement) void {
    if (supplement.cursor) |cursor| allocator.free(cursor.path);
    if (supplement.hover_text) |hover| allocator.free(hover);
    if (supplement.spec_block) |block| allocator.free(block);
    freeDiagnosticEntries(allocator, supplement.diagnostics);
    freeLspHints(allocator, supplement.lsp_hints);
}

/// Format a spec block for inclusion in agent context. Reads the spec's
/// requirements.md, design.md, and tasks.md files and concatenates them
/// into a single markdown block. Returns null if the spec has no files
/// or cannot be read.
///
/// This is the "specs → implementation → hooks" loop from Kiro: when
/// an approved spec exists for the current intent, the agent sees the
/// spec's requirements + design + tasks and implements against them.
pub fn formatSpecBlock(
    allocator: std.mem.Allocator,
    io: std.Io,
    spec_root_abs: []const u8,
) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Active spec\n\n");
    try out.appendSlice(allocator, "The following spec has been approved. Implement changes that satisfy these requirements, follow this design, and complete these tasks.\n\n");

    var any_added = false;
    const files = [_]struct { name: []const u8, label: []const u8 }{
        .{ .name = "requirements.md", .label = "## Requirements\n\n" },
        .{ .name = "design.md", .label = "## Design\n\n" },
        .{ .name = "tasks.md", .label = "## Tasks\n\n" },
    };
    _ = &files;

    for (files) |f| {
        const content = blk: {
            var dir = std.Io.Dir.openDirAbsolute(io, spec_root_abs, .{}) catch break :blk null;
            defer dir.close(io);
            var file = dir.openFile(io, f.name, .{}) catch break :blk null;
            defer file.close(io);
            const stat = file.stat(io) catch break :blk null;
            const size: usize = @intCast(stat.size);
            if (size == 0) break :blk null;
            const buf = allocator.alloc(u8, size) catch break :blk null;
            errdefer allocator.free(buf);
            const read = file.readPositionalAll(io, buf, 0) catch {
                allocator.free(buf);
                break :blk null;
            };
            if (read == 0) {
                allocator.free(buf);
                break :blk null;
            }
            break :blk buf[0..read];
        };
        if (content) |c| {
            defer allocator.free(c);
            try out.appendSlice(allocator, f.label);
            try out.appendSlice(allocator, c);
            try out.appendSlice(allocator, "\n\n");
            any_added = true;
        }
    }

    if (!any_added) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

test "formatDiagnosticsBlock renders entries" {
    const allocator = std.testing.allocator;
    const entries = [_]DiagnosticEntry{
        .{ .path = "main.zig", .line = 4, .character = 2, .severity = "error", .message = "undefined identifier" },
    };
    const block = try formatDiagnosticsBlock(allocator, &entries);
    defer allocator.free(block.?);
    try std.testing.expect(std.mem.indexOf(u8, block.?, "main.zig:5:3") != null);
}

test "formatLspBlock includes hover" {
    const allocator = std.testing.allocator;
    const supplement = Supplement{
        .hover_text = "fn main() void",
    };
    const block = try formatLspBlock(allocator, supplement);
    defer allocator.free(block.?);
    try std.testing.expect(std.mem.indexOf(u8, block.?, "hover:") != null);
}

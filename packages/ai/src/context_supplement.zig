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
    freeDiagnosticEntries(allocator, supplement.diagnostics);
    freeLspHints(allocator, supplement.lsp_hints);
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

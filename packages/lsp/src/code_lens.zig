const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

/// CodeLens — LSP textDocument/codeLens support.
/// Provides clickable commands inline above code elements (e.g. "Run |
/// Debug" above test functions, "3 references" above function definitions).
pub const CodeLens = struct {
    /// 0-indexed line number where the lens should appear.
    line: u32,
    /// 0-indexed start character.
    start_char: u32,
    /// 0-indexed end character.
    end_char: u32,
    /// Display title (e.g. "3 references", "Run Test").
    title: []const u8,
    /// Optional command identifier (e.g. "editor.action.showReferences").
    command: ?[]const u8 = null,
    /// Optional command arguments (JSON-encoded).
    arguments: ?[]const u8 = null,

    pub fn deinit(self: *CodeLens, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.command) |cmd| allocator.free(cmd);
        if (self.arguments) |args| allocator.free(args);
        self.* = undefined;
    }
};

pub const CodeLensStore = struct {
    allocator: std.mem.Allocator,
    items: []CodeLens = &.{},
    file_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) CodeLensStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CodeLensStore) void {
        for (self.items) |*item| item.deinit(self.allocator);
        if (self.items.len > 0) self.allocator.free(self.items);
        if (self.file_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn setItems(self: *CodeLensStore, items: []CodeLens, file_path: []const u8) !void {
        for (self.items) |*item| item.deinit(self.allocator);
        if (self.items.len > 0) self.allocator.free(self.items);
        if (self.file_path) |path| self.allocator.free(path);
        self.items = items;
        self.file_path = try self.allocator.dupe(u8, file_path);
    }

    pub fn clear(self: *CodeLensStore) void {
        for (self.items) |*item| item.deinit(self.allocator);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = &.{};
        if (self.file_path) |path| self.allocator.free(path);
        self.file_path = null;
    }

    /// Get all code lenses for a specific line.
    pub fn lensesForLine(self: *const CodeLensStore, line: u32) []const CodeLens {
        var result_start: ?usize = null;
        var result_end: usize = 0;
        for (self.items, 0..) |lens, i| {
            if (lens.line == line) {
                if (result_start == null) result_start = i;
                result_end = i + 1;
            }
        }
        if (result_start) |s| {
            return self.items[s..result_end];
        }
        return &.{};
    }
};

/// Build a textDocument/codeLens request.
pub fn buildCodeLensRequest(allocator: std.mem.Allocator, id: i64, uri: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/codeLens","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{ id, uri });
}

/// Parse a codeLens response.
pub fn parseCodeLensResponse(allocator: std.mem.Allocator, response: []const u8) ![]CodeLens {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const result = root.object.get("result") orelse return &.{};
    if (result != .array) return &.{};

    var list: std.ArrayList(CodeLens) = .empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    for (result.array.items) |lens_json| {
        const range = lens_json.object.get("range") orelse continue;
        const start = range.object.get("start") orelse continue;
        const start_line: u32 = if (start.object.get("line")) |l| @intCast(l.integer) else 0;

        const title_val = lens_json.object.get("title") orelse continue;
        const title_str = if (title_val == .string) title_val.string else "CodeLens";

        const command_val = lens_json.object.get("command");
        const command_str = if (command_val) |c| if (c == .string) c.string else null else null;

        try list.append(allocator, .{
            .line = start_line,
            .start_char = 0,
            .end_char = 0,
            .title = try allocator.dupe(u8, title_str),
            .command = if (command_str) |cmd| try allocator.dupe(u8, cmd) else null,
        });
    }

    return list.toOwnedSlice(allocator);
}

test "CodeLensStore init and clear" {
    var store = CodeLensStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 0), store.items.len);
}

test "lensesForLine returns correct items" {
    var store = CodeLensStore.init(std.testing.allocator);
    defer store.deinit();
    // Manually add items for testing
    var items = try std.testing.allocator.alloc(CodeLens, 2);
    items[0] = .{ .line = 5, .start_char = 0, .end_char = 10, .title = try std.testing.allocator.dupe(u8, "Run Test") };
    items[1] = .{ .line = 10, .start_char = 0, .end_char = 5, .title = try std.testing.allocator.dupe(u8, "3 references") };
    store.items = items;

    const lenses = store.lensesForLine(5);
    try std.testing.expectEqual(@as(usize, 1), lenses.len);
    try std.testing.expectEqualStrings("Run Test", lenses[0].title);
}

//! Document symbols — `textDocument/documentSymbol` request and response.
//!
//! Returns a tree of symbols defined in a single document. Used by the
//! symbol outline panel and breadcrumbs UI. Servers may return either
//! `SymbolInformation[]` (flat) or `DocumentSymbol[]` (hierarchical);
//! we normalize to a flat list with depth info for rendering.

const std = @import("std");
const navigation = @import("navigation.zig");

pub const SymbolKind = enum(u8) {
    File = 1,
    Module = 2,
    Namespace = 3,
    Package = 4,
    Class = 5,
    Method = 6,
    Property = 7,
    Field = 8,
    Constructor = 9,
    Enum = 10,
    Interface = 11,
    Function = 12,
    Variable = 13,
    Constant = 14,
    String = 15,
    Number = 16,
    Boolean = 17,
    Array = 18,
    Object = 19,
    Key = 20,
    Null = 21,
    EnumMember = 22,
    Struct = 23,
    Event = 24,
    Operator = 25,
    TypeParameter = 26,
    _,
};

pub const Symbol = struct {
    /// Display name (e.g. "main", "Buffer", "insertString").
    name: []const u8,
    /// Symbol kind (Function, Class, Method, etc.).
    kind: SymbolKind,
    /// 0-indexed start line of the symbol's range.
    line: u32,
    /// 0-indexed start character (column).
    character: u32,
    /// 0-indexed end line (for selection range).
    end_line: u32 = 0,
    /// 0-indexed end character.
    end_character: u32 = 0,
    /// Optional detail (e.g. "() void" for a function signature).
    detail: ?[]const u8 = null,
    /// Nesting depth (0 = top-level, 1 = nested in a class, etc.).
    depth: u8 = 0,
    /// Optional container name (for flat SymbolInformation responses).
    container_name: ?[]const u8 = null,

    pub fn deinit(self: *Symbol, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.detail) |d| allocator.free(d);
        if (self.container_name) |c| allocator.free(c);
        self.* = undefined;
    }

    /// Returns a single-character glyph for the symbol kind, used in the
    /// outline panel and breadcrumbs.
    pub fn glyph(self: Symbol) []const u8 {
        return switch (self.kind) {
            .File => "F",
            .Module, .Namespace, .Package => "M",
            .Class, .Struct, .Interface => "C",
            .Method, .Constructor => "M",
            .Function => "ƒ",
            .Property, .Field => "P",
            .Enum, .EnumMember => "E",
            .Constant, .Variable => "V",
            .String => "S",
            .Number, .Boolean => "N",
            .Array, .Object => "A",
            .Key => "K",
            .Null => "?",
            .Event => "EV",
            .Operator => "OP",
            .TypeParameter => "T",
            _ => "•",
        };
    }

    /// Returns true if this symbol kind is a "container" (has children).
    pub fn isContainer(self: Symbol) bool {
        return switch (self.kind) {
            .Class, .Struct, .Interface, .Enum, .Module, .Namespace, .Package, .File => true,
            else => false,
        };
    }
};

pub const SymbolList = struct {
    items: []Symbol,

    pub fn deinit(self: *SymbolList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Build a `textDocument/documentSymbol` JSON-RPC request.
pub fn buildDocumentSymbolRequest(
    allocator: std.mem.Allocator,
    request_id: i32,
    uri: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/documentSymbol","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{ request_id, uri });
}

/// Parse a `textDocument/documentSymbol` response. Handles both
/// `SymbolInformation[]` (flat) and `DocumentSymbol[]` (hierarchical)
/// response shapes — both are normalized to a flat `[]Symbol` with
/// `depth` indicating nesting level.
pub fn parseDocumentSymbolResponse(allocator: std.mem.Allocator, response_json: []const u8) !SymbolList {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    const result_val = root.object.get("result") orelse return error.InvalidResponse;
    if (result_val != .array) {
        // null result = no symbols.
        if (result_val == .null) {
            return .{ .items = try allocator.alloc(Symbol, 0) };
        }
        return error.InvalidResponse;
    }

    var out: std.ArrayList(Symbol) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    // Try DocumentSymbol first (hierarchical). Detect by presence of
    // "range" field on first element.
    if (result_val.array.items.len > 0) {
        const first = result_val.array.items[0];
        if (first == .object and first.object.contains("range")) {
            // Hierarchical DocumentSymbol[].
            for (result_val.array.items) |ds| {
                try parseDocumentSymbolRecursive(allocator, ds, 0, &out);
            }
        } else {
            // Flat SymbolInformation[].
            for (result_val.array.items) |si| {
                try parseSymbolInformation(allocator, si, &out);
            }
        }
    }

    return .{ .items = try out.toOwnedSlice(allocator) };
}

fn parseDocumentSymbolRecursive(
    allocator: std.mem.Allocator,
    ds: std.json.Value,
    depth: u8,
    out: *std.ArrayList(Symbol),
) !void {
    if (ds != .object) return;
    const name_val = ds.object.get("name") orelse return;
    if (name_val != .string) return;
    const name = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name);

    const kind_int: u8 = blk: {
        const k = ds.object.get("kind") orelse break :blk 0;
        if (k != .integer) break :blk 0;
        if (k.integer < 0 or k.integer > 255) break :blk 0;
        break :blk @intCast(k.integer);
    };

    var line: u32 = 0;
    var character: u32 = 0;
    var end_line: u32 = 0;
    var end_character: u32 = 0;
    if (ds.object.get("range")) |range| {
        if (range == .object) {
            if (range.object.get("start")) |start| {
                if (start == .object) {
                    if (start.object.get("line")) |l| {
                        if (l == .integer) line = @intCast(@max(0, l.integer));
                    }
                    if (start.object.get("character")) |c| {
                        if (c == .integer) character = @intCast(@max(0, c.integer));
                    }
                }
            }
            if (range.object.get("end")) |end| {
                if (end == .object) {
                    if (end.object.get("line")) |l| {
                        if (l == .integer) end_line = @intCast(@max(0, l.integer));
                    }
                    if (end.object.get("character")) |c| {
                        if (c == .integer) end_character = @intCast(@max(0, c.integer));
                    }
                }
            }
        }
    }

    const detail: ?[]const u8 = if (ds.object.get("detail")) |d| switch (d) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    errdefer if (detail) |d| allocator.free(d);

    try out.append(allocator, .{
        .name = name,
        .kind = @enumFromInt(kind_int),
        .line = line,
        .character = character,
        .end_line = end_line,
        .end_character = end_character,
        .detail = detail,
        .depth = depth,
    });

    // Recurse into children.
    if (ds.object.get("children")) |children| {
        if (children == .array) {
            for (children.array.items) |child| {
                try parseDocumentSymbolRecursive(allocator, child, depth + 1, out);
            }
        }
    }
}

fn parseSymbolInformation(
    allocator: std.mem.Allocator,
    si: std.json.Value,
    out: *std.ArrayList(Symbol),
) !void {
    if (si != .object) return;
    const name_val = si.object.get("name") orelse return;
    if (name_val != .string) return;
    const name = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name);

    const kind_int: u8 = blk: {
        const k = si.object.get("kind") orelse break :blk 0;
        if (k != .integer) break :blk 0;
        if (k.integer < 0 or k.integer > 255) break :blk 0;
        break :blk @intCast(k.integer);
    };

    var line: u32 = 0;
    var character: u32 = 0;
    if (si.object.get("location")) |loc| {
        if (loc == .object) {
            if (loc.object.get("range")) |range| {
                if (range == .object) {
                    if (range.object.get("start")) |start| {
                        if (start == .object) {
                            if (start.object.get("line")) |l| {
                                if (l == .integer) line = @intCast(@max(0, l.integer));
                            }
                            if (start.object.get("character")) |c| {
                                if (c == .integer) character = @intCast(@max(0, c.integer));
                            }
                        }
                    }
                }
            }
        }
    }

    const container_name: ?[]const u8 = if (si.object.get("containerName")) |c| switch (c) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    errdefer if (container_name) |c| allocator.free(c);

    try out.append(allocator, .{
        .name = name,
        .kind = @enumFromInt(kind_int),
        .line = line,
        .character = character,
        .depth = 0,
        .container_name = container_name,
    });
}

test "buildDocumentSymbolRequest includes method and uri" {
    const allocator = std.testing.allocator;
    const msg = try buildDocumentSymbolRequest(allocator, 1, "file:///tmp/a.zig");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "textDocument/documentSymbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "file:///tmp/a.zig") != null);
}

test "parseDocumentSymbolResponse handles hierarchical response" {
    const allocator = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[{"name":"main","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":5,"character":1}},"detail":"() void","children":[{"name":"x","kind":13,"range":{"start":{"line":1,"character":4},"end":{"line":1,"character":8}}}]}]}
    ;
    var list = try parseDocumentSymbolResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("main", list.items[0].name);
    try std.testing.expectEqual(@as(u8, 0), list.items[0].depth);
    try std.testing.expectEqualStrings("x", list.items[1].name);
    try std.testing.expectEqual(@as(u8, 1), list.items[1].depth);
}

test "parseDocumentSymbolResponse handles flat SymbolInformation" {
    const allocator = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":[{"name":"foo","kind":12,"location":{"uri":"file:///x.zig","range":{"start":{"line":3,"character":0}}},"containerName":"Bar"}]}
    ;
    var list = try parseDocumentSymbolResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("foo", list.items[0].name);
    try std.testing.expectEqualStrings("Bar", list.items[0].container_name.?);
}

test "parseDocumentSymbolResponse handles null result" {
    const allocator = std.testing.allocator;
    const response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    var list = try parseDocumentSymbolResponse(allocator, response);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "Symbol glyph returns single character" {
    const s = Symbol{ .name = "x", .kind = .Function, .line = 0, .character = 0 };
    try std.testing.expectEqualStrings("ƒ", s.glyph());
}

test "Symbol isContainer distinguishes containers from leaves" {
    const class_sym = Symbol{ .name = "Foo", .kind = .Class, .line = 0, .character = 0 };
    const fn_sym = Symbol{ .name = "bar", .kind = .Function, .line = 0, .character = 0 };
    try std.testing.expect(class_sym.isContainer());
    try std.testing.expect(!fn_sym.isContainer());
}

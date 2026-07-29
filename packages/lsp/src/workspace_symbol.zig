const std = @import("std");

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

pub const SymbolInformation = struct {
    name: []const u8,
    kind: SymbolKind,
    location: @import("navigation.zig").Location,
    containerName: ?[]const u8 = null,
};

pub const WorkspaceSymbol = struct {
    name: []const u8,
    kind: SymbolKind,
    location: @import("navigation.zig").Location,
    containerName: ?[]const u8 = null,
};

pub const List = struct {
    items: []SymbolInformation,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.name);
            allocator.free(item.location.uri);
            if (item.containerName) |c| allocator.free(c);
        }
        allocator.free(self.items);
    }
};

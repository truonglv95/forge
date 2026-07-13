const std = @import("std");

pub const SemanticTokenTypes = enum(u8) {
    namespace = 0,
    type,
    class,
    @"enum",
    interface,
    @"struct",
    typeParameter,
    parameter,
    variable,
    property,
    enumMember,
    event,
    function,
    method,
    macro,
    keyword,
    modifier,
    comment,
    string,
    number,
    regexp,
    operator,
    decorator,
    _,
};

pub const SemanticTokensLegend = struct {
    tokenTypes: [][]const u8,
    tokenModifiers: [][]const u8,

    pub fn deinit(self: *SemanticTokensLegend, allocator: std.mem.Allocator) void {
        for (self.tokenTypes) |t| allocator.free(t);
        for (self.tokenModifiers) |m| allocator.free(m);
        allocator.free(self.tokenTypes);
        allocator.free(self.tokenModifiers);
    }
};

pub const SemanticTokens = struct {
    resultId: ?[]const u8 = null,
    data: []u32,

    pub fn deinit(self: *SemanticTokens, allocator: std.mem.Allocator) void {
        if (self.resultId) |id| allocator.free(id);
        allocator.free(self.data);
    }
};

pub const AbsoluteToken = struct {
    line: u32,
    start: u32,
    length: u32,
    token_type: u32,
    modifiers: u32,
};

/// Standard LSP semantic token modifier bits (per the LSP 3.17 spec).
/// The server's legend may declare these in any order — these constants
/// assume the server follows the standard ordering (which most do, e.g.
/// clangd, gopls, rust-analyzer, TypeScript language server, pyright).
pub const ModifierBit = enum(u32) {
    declaration = 1 << 0,
    definition = 1 << 1,
    readonly = 1 << 2,
    static = 1 << 3,
    deprecated = 1 << 4,
    abstract = 1 << 5,
    async = 1 << 6,
    modification = 1 << 7,
    documentation = 1 << 8,
    default_library = 1 << 9,
};

pub fn hasModifier(modifiers: u32, mod: ModifierBit) bool {
    return (modifiers & @intFromEnum(mod)) != 0;
}

test "hasModifier identifies declaration bit" {
    try std.testing.expect(hasModifier(1, .declaration));
    try std.testing.expect(!hasModifier(2, .declaration));
    try std.testing.expect(hasModifier(17, .declaration)); // declaration | deprecated
    try std.testing.expect(hasModifier(17, .deprecated));
}

test "hasModifier identifies default_library bit" {
    try std.testing.expect(hasModifier(512, .default_library));
    try std.testing.expect(!hasModifier(511, .default_library));
}

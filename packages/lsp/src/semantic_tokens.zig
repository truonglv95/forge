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

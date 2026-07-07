const std = @import("std");
const parser_resolver = @import("parser_resolver.zig");

var active: ?parser_resolver.ParserSet = null;
var active_owned = false;

pub fn activateView(set: parser_resolver.ParserSet) void {
    active = set;
    active_owned = false;
}

pub fn activateOwned(allocator: std.mem.Allocator, set: parser_resolver.ParserSet) void {
    deactivate(allocator);
    active = set;
    active_owned = true;
}

pub fn activate(allocator: std.mem.Allocator, set: parser_resolver.ParserSet) !void {
    deactivate(allocator);
    active = set;
    active_owned = true;
}

pub fn deactivate(allocator: std.mem.Allocator) void {
    if (active_owned) {
        if (active) |*set| set.deinit(allocator);
    }
    active = null;
    active_owned = false;
}

pub fn get() ?parser_resolver.ParserSet {
    return active;
}

pub fn grammarTag(language_id: []const u8) ?[]const u8 {
    const set = active orelse return null;
    return set.grammarTag(language_id);
}

test "parser profile exposes active grammar tags" {
    var langs = [_]parser_resolver.ResolvedGrammar{
        .{ .language = "python", .grammar_tag = "v0.23.6" },
    };
    activateView(.{
        .parser_set_id = "core@0.20.8;python@v0.23.6",
        .toolchain_fingerprint = 1,
        .grammars = langs[0..],
    });
    defer deactivate(std.testing.allocator);
    try std.testing.expectEqualStrings("v0.23.6", grammarTag("python").?);
}

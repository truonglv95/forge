const std = @import("std");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");
const toolchain_probe = @import("toolchain_probe.zig");
const parser_catalog = @import("parser_catalog.zig");
const parser_sync = @import("parser_sync.zig");

pub const parser_lock_file = ".forge/parser_lock.json";

pub const tree_sitter_core_tag = parser_catalog.tree_sitter_core_tag;

pub const ResolvedGrammar = struct {
    language: []const u8,
    grammar_tag: []const u8,
    project_version: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

pub const ParserSet = struct {
    parser_set_id: []const u8,
    toolchain_fingerprint: u64,
    grammars: []ResolvedGrammar,

    pub fn deinit(self: *ParserSet, allocator: std.mem.Allocator) void {
        allocator.free(self.parser_set_id);
        for (self.grammars) |grammar| {
            allocator.free(grammar.language);
            allocator.free(grammar.grammar_tag);
            if (grammar.project_version) |version| allocator.free(version);
            if (grammar.source) |source| allocator.free(source);
        }
        allocator.free(self.grammars);
        self.* = undefined;
    }

    pub fn grammarTag(self: ParserSet, language_id: []const u8) ?[]const u8 {
        for (self.grammars) |grammar| {
            if (std.mem.eql(u8, grammar.language, language_id)) return grammar.grammar_tag;
        }
        return null;
    }
};

fn selectGrammar(language: []const u8, project_version: ?[]const u8) []const u8 {
    const catalog = parser_catalog.load();
    if (parser_catalog.selectGrammar(catalog, language, project_version)) |entry| {
        return entry.tag;
    }
    return defaultGrammarTag(language);
}

fn defaultGrammarTag(language: []const u8) []const u8 {
    if (std.mem.eql(u8, language, "python")) return "v0.23.6";
    if (std.mem.eql(u8, language, "typescript") or std.mem.eql(u8, language, "tsx")) return "v0.20.5";
    return "unknown";
}

fn formatParserSetId(allocator: std.mem.Allocator, grammars: []const ResolvedGrammar) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "core@");
    try buf.appendSlice(allocator, tree_sitter_core_tag);
    for (grammars) |grammar| {
        try buf.append(allocator, ';');
        try buf.appendSlice(allocator, grammar.language);
        try buf.append(allocator, '@');
        try buf.appendSlice(allocator, grammar.grammar_tag);
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn resolve(allocator: std.mem.Allocator, report: toolchain_probe.ToolchainReport) !ParserSet {
    var grammars: std.ArrayList(ResolvedGrammar) = .empty;
    errdefer {
        for (grammars.items) |grammar| {
            allocator.free(grammar.language);
            allocator.free(grammar.grammar_tag);
            if (grammar.project_version) |version| allocator.free(version);
            if (grammar.source) |source| allocator.free(source);
        }
        grammars.deinit(allocator);
    }

    const default_typescript = selectGrammar("typescript", null);
    const default_python = selectGrammar("python", null);
    const default_tsx = selectGrammar("tsx", null);

    try grammars.append(allocator, try makeResolved(allocator, "python", default_python, report, "python"));
    try grammars.append(allocator, try makeResolved(allocator, "typescript", default_typescript, report, "typescript"));
    try grammars.append(allocator, try makeResolved(allocator, "tsx", default_tsx, report, "typescript"));

    const parser_set_id = try formatParserSetId(allocator, grammars.items);
    errdefer allocator.free(parser_set_id);

    return .{
        .parser_set_id = parser_set_id,
        .toolchain_fingerprint = report.fingerprint,
        .grammars = try grammars.toOwnedSlice(allocator),
    };
}

fn makeResolved(
    allocator: std.mem.Allocator,
    language: []const u8,
    tag: []const u8,
    report: toolchain_probe.ToolchainReport,
    lookup_id: []const u8,
) !ResolvedGrammar {
    const detected = findDetected(report, lookup_id);
    const selected_tag = if (detected) |lang| selectGrammar(language, lang.version) else tag;
    return .{
        .language = try allocator.dupe(u8, language),
        .grammar_tag = try allocator.dupe(u8, selected_tag),
        .project_version = if (detected) |lang| try allocator.dupe(u8, lang.version) else null,
        .source = if (detected) |lang| try allocator.dupe(u8, lang.source) else null,
    };
}

fn findDetected(report: toolchain_probe.ToolchainReport, id: []const u8) ?toolchain_probe.DetectedLanguage {
    for (report.languages) |lang| {
        if (std.mem.eql(u8, lang.id, id)) return lang;
    }
    return null;
}

pub fn compute(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
) !ParserSet {
    var report = try toolchain_probe.probe(allocator, io, root);
    defer report.deinit(allocator);
    return try resolve(allocator, report);
}

pub fn ensure(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
) !ParserSet {
    var report = try toolchain_probe.probe(allocator, io, root);
    defer report.deinit(allocator);

    var set = try resolve(allocator, report);
    errdefer set.deinit(allocator);

    try persist(allocator, io, root, report, set);
    var sync_report = try parser_sync.sync(allocator, io, root, set);
    sync_report.deinit(allocator);
    return set;
}

pub fn manifestMatches(set: ParserSet, parser_set_id: []const u8, toolchain_fingerprint: u64) bool {
    return set.toolchain_fingerprint == toolchain_fingerprint and
        std.mem.eql(u8, set.parser_set_id, parser_set_id);
}

fn persist(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    report: toolchain_probe.ToolchainReport,
    set: ParserSet,
) !void {
    try root.dir.createDirPath(io, ".forge");

    const ToolchainJson = struct {
        detected_at_ms: i64,
        fingerprint: u64,
        languages: []const toolchain_probe.DetectedLanguage,
    };
    const toolchain_json = try std.json.Stringify.valueAlloc(allocator, ToolchainJson{
        .detected_at_ms = report.detected_at_ms,
        .fingerprint = report.fingerprint,
        .languages = report.languages,
    }, .{});
    defer allocator.free(toolchain_json);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(toolchain_probe.toolchain_file), toolchain_json);

    const LockJson = struct {
        tree_sitter_core: []const u8,
        parser_set_id: []const u8,
        toolchain_fingerprint: u64,
        resolved: []const ResolvedGrammar,
    };
    const lock_json = try std.json.Stringify.valueAlloc(allocator, LockJson{
        .tree_sitter_core = tree_sitter_core_tag,
        .parser_set_id = set.parser_set_id,
        .toolchain_fingerprint = set.toolchain_fingerprint,
        .resolved = set.grammars,
    }, .{});
    defer allocator.free(lock_json);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(parser_lock_file), lock_json);
}

test "parser resolver builds parser_set_id from toolchain" {
    const allocator = std.testing.allocator;
    var langs = [_]toolchain_probe.DetectedLanguage{
        .{ .id = "python", .version = "3.12.0", .source = "pyproject.toml" },
        .{ .id = "typescript", .version = "5.4.2", .source = "package.json" },
    };
    const report = toolchain_probe.ToolchainReport{
        .languages = langs[0..],
        .fingerprint = 42,
        .detected_at_ms = 1,
    };

    var set = try resolve(allocator, report);
    defer set.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, set.parser_set_id, "python@v0.23.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, set.parser_set_id, "typescript@v0.20.5") != null);
    try std.testing.expectEqualStrings("v0.23.6", set.grammarTag("python").?);
}

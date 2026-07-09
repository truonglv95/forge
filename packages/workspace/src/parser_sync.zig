const std = @import("std");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");
const parser_catalog = @import("parser_catalog.zig");
const parser_resolver = @import("parser_resolver.zig");

pub const sync_file = ".forge/parsers/sync.json";

pub const SyncOptions = struct {
    allow_fetch: bool = false,
};

pub const SyncEntry = struct {
    language: []const u8,
    grammar_tag: []const u8,
    origin: []const u8,
    status: []const u8,
    vendor_path: ?[]const u8 = null,
    artifact_url: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    project_version: ?[]const u8 = null,
};

pub const SyncReport = struct {
    synced_at_ms: i64,
    parser_set_id: []const u8,
    toolchain_fingerprint: u64,
    tree_sitter_core: []const u8,
    entries: []SyncEntry,

    pub fn deinit(self: *SyncReport, allocator: std.mem.Allocator) void {
        allocator.free(self.parser_set_id);
        allocator.free(self.tree_sitter_core);
        for (self.entries) |entry| {
            allocator.free(entry.language);
            allocator.free(entry.grammar_tag);
            allocator.free(entry.origin);
            allocator.free(entry.status);
            if (entry.vendor_path) |path| allocator.free(path);
            if (entry.artifact_url) |url| allocator.free(url);
            if (entry.sha256) |hash| allocator.free(hash);
            if (entry.project_version) |version| allocator.free(version);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub fn sync(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    set: parser_resolver.ParserSet,
) !SyncReport {
    return syncWithOptions(allocator, io, root, set, .{});
}

pub fn syncWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    set: parser_resolver.ParserSet,
    options: SyncOptions,
) !SyncReport {
    const catalog = parser_catalog.load();
    var entries: std.ArrayList(SyncEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.language);
            allocator.free(entry.grammar_tag);
            allocator.free(entry.origin);
            allocator.free(entry.status);
            if (entry.vendor_path) |path| allocator.free(path);
            if (entry.artifact_url) |url| allocator.free(url);
            if (entry.sha256) |hash| allocator.free(hash);
            if (entry.project_version) |version| allocator.free(version);
        }
        entries.deinit(allocator);
    }

    for (set.grammars) |grammar| {
        const catalog_entry = parser_catalog.findEntry(catalog, grammar.language, grammar.grammar_tag);
        const origin = if (catalog_entry) |entry| entry.origin else grammar.origin;
        const status: []const u8 = if (catalog_entry != null and catalog_entry.?.bundled)
            "bundled"
        else if (std.mem.eql(u8, origin, "fetch") and options.allow_fetch)
            "fetch_pending"
        else if (std.mem.eql(u8, origin, "fetch"))
            "fetch_disabled"
        else
            "missing";
        try entries.append(allocator, .{
            .language = try allocator.dupe(u8, grammar.language),
            .grammar_tag = try allocator.dupe(u8, grammar.grammar_tag),
            .origin = try allocator.dupe(u8, origin),
            .status = try allocator.dupe(u8, status),
            .vendor_path = if (catalog_entry) |entry|
                if (entry.vendor_path) |path| try allocator.dupe(u8, path) else null
            else if (grammar.vendor_path) |path| try allocator.dupe(u8, path) else null,
            .artifact_url = if (catalog_entry) |entry|
                if (entry.artifact_url) |url| try allocator.dupe(u8, url) else null
            else if (grammar.artifact_url) |url| try allocator.dupe(u8, url) else null,
            .sha256 = if (catalog_entry) |entry|
                if (entry.sha256) |hash| try allocator.dupe(u8, hash) else null
            else if (grammar.sha256) |hash| try allocator.dupe(u8, hash) else null,
            .project_version = if (grammar.project_version) |version| try allocator.dupe(u8, version) else null,
        });
        if (std.mem.eql(u8, status, "missing") or std.mem.eql(u8, status, "fetch_disabled")) {
            return error.MissingBundledGrammar;
        }
    }

    const report = SyncReport{
        .synced_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .parser_set_id = try allocator.dupe(u8, set.parser_set_id),
        .toolchain_fingerprint = set.toolchain_fingerprint,
        .tree_sitter_core = try allocator.dupe(u8, catalog.tree_sitter_core),
        .entries = try entries.toOwnedSlice(allocator),
    };

    try persist(allocator, io, root, report);
    return report;
}

pub fn lockCurrent(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !bool {
    const bytes = readRelative(allocator, io, root, parser_resolver.parser_lock_file) catch return false;
    defer allocator.free(bytes);
    const LockJson = struct {
        parser_set_id: []const u8 = "",
        toolchain_fingerprint: u64 = 0,
    };
    var parsed = std.json.parseFromSlice(LockJson, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();

    var current = try parser_resolver.compute(allocator, io, root);
    defer current.deinit(allocator);
    return parser_resolver.manifestMatches(
        current,
        parsed.value.parser_set_id,
        parsed.value.toolchain_fingerprint,
    );
}

fn persist(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    report: SyncReport,
) !void {
    try root.dir.createDirPath(io, ".forge/parsers");
    const json = try std.json.Stringify.valueAlloc(allocator, report, .{});
    defer allocator.free(json);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(sync_file), json);
}

fn readRelative(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, rel: []const u8) ![]u8 {
    var file = try root.dir.openFile(io, rel, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

test "parser sync records bundled grammar metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");

    var grammars = [_]parser_resolver.ResolvedGrammar{
        .{ .language = "python", .grammar_tag = "v0.23.6", .project_version = "3.12.0", .source = "pyproject.toml" },
    };
    const set = parser_resolver.ParserSet{
        .parser_set_id = "core@0.20.8;python@v0.23.6",
        .toolchain_fingerprint = 9,
        .grammars = grammars[0..],
    };

    var report = try sync(allocator, io, root, set);
    defer report.deinit(allocator);
    try std.testing.expectEqualStrings("bundled", report.entries[0].status);
}

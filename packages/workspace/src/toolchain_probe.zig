const std = @import("std");
const path_mod = @import("path.zig");
const snapshot = @import("snapshot.zig");
const atomic = @import("atomic.zig");
const global_store = @import("global_store.zig");
const util = @import("forge-util");

/// Sub-path within the session directory.
pub const toolchain_filename = "toolchain.json";
/// Legacy alias.
pub const toolchain_file = toolchain_filename;

pub const DetectedLanguage = struct {
    id: []const u8,
    version: []const u8,
    source: []const u8,
};

pub const ToolchainReport = struct {
    languages: []DetectedLanguage,
    fingerprint: u64,
    detected_at_ms: i64,

    pub fn deinit(self: *ToolchainReport, allocator: std.mem.Allocator) void {
        for (self.languages) |lang| {
            allocator.free(lang.id);
            allocator.free(lang.version);
            allocator.free(lang.source);
        }
        allocator.free(self.languages);
        self.* = undefined;
    }
};

pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
) !ToolchainReport {
    var detected: std.ArrayList(DetectedLanguage) = .empty;
    errdefer {
        for (detected.items) |lang| {
            allocator.free(lang.id);
            allocator.free(lang.version);
            allocator.free(lang.source);
        }
        detected.deinit(allocator);
    }

    if (try readText(allocator, io, root, "pyproject.toml")) |content| {
        defer allocator.free(content);
        if (parseRequiresPython(content)) |version| {
            try appendLanguage(allocator, &detected, "python", version, "pyproject.toml");
        }
    }

    if (try readText(allocator, io, root, ".python-version")) |content| {
        defer allocator.free(content);
        if (parseSingleVersionLine(content)) |version| {
            try appendLanguage(allocator, &detected, "python", version, ".python-version");
        }
    }

    if (try readText(allocator, io, root, "package.json")) |content| {
        defer allocator.free(content);
        if (parsePackageJsonDependency(content, "typescript")) |version| {
            try appendLanguage(allocator, &detected, "typescript", version, "package.json");
        }
        if (parsePackageJsonDependency(content, "@types/node")) |version| {
            try appendLanguage(allocator, &detected, "node", version, "package.json");
        } else if (parsePackageJsonEngines(content, "node")) |version| {
            try appendLanguage(allocator, &detected, "node", version, "package.json");
        }
    }

    if (try readText(allocator, io, root, "build.zig.zon")) |content| {
        defer allocator.free(content);
        if (parseZonStringField(content, "minimum_zig_version")) |version| {
            try appendLanguage(allocator, &detected, "zig", version, "build.zig.zon");
        }
    }

    if (try readText(allocator, io, root, "rust-toolchain.toml")) |content| {
        defer allocator.free(content);
        if (parseTomlStringField(content, "channel")) |version| {
            try appendLanguage(allocator, &detected, "rust", version, "rust-toolchain.toml");
        }
    } else if (try readText(allocator, io, root, "Cargo.toml")) |content| {
        defer allocator.free(content);
        if (parseTomlStringField(content, "edition")) |version| {
            try appendLanguage(allocator, &detected, "rust", version, "Cargo.toml");
        }
    }

    const languages = try detected.toOwnedSlice(allocator);
    const detected_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return .{
        .languages = languages,
        .fingerprint = fingerprint(languages),
        .detected_at_ms = detected_at_ms,
    };
}

fn appendLanguage(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(DetectedLanguage),
    id: []const u8,
    version: []const u8,
    source: []const u8,
) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing.id, id)) return;
    }
    try out.append(allocator, .{
        .id = try allocator.dupe(u8, id),
        .version = try normalizeVersion(allocator, version),
        .source = try allocator.dupe(u8, source),
    });
}

pub fn fingerprint(languages: []const DetectedLanguage) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var order: [16]usize = undefined;
    const len = @min(languages.len, order.len);
    for (0..len) |i| order[i] = i;
    std.sort.pdq(usize, order[0..len], languages, struct {
        fn less(langs: []const DetectedLanguage, a: usize, b: usize) bool {
            return std.mem.order(u8, langs[a].id, langs[b].id) == .lt;
        }
    }.less);
    for (order[0..len]) |index| {
        const lang = languages[index];
        hasher.update(lang.id);
        hasher.update("=");
        hasher.update(lang.version);
        hasher.update("\n");
    }
    return hasher.final();
}

fn readText(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    rel: []const u8,
) !?[]u8 {
    const wp = path_mod.WorkspacePath.parse(rel) catch return null;
    var snap = snapshot.FileSnapshot.read(allocator, io, root, wp) catch return null;
    defer snap.deinit();
    return try allocator.dupe(u8, snap.content);
}

fn parseRequiresPython(content: []const u8) ?[]const u8 {
    const needle = "requires-python";
    const index = std.mem.indexOf(u8, content, needle) orelse return null;
    const tail = content[index + needle.len ..];
    const eq = std.mem.indexOfScalar(u8, tail, '=') orelse return null;
    const value = parseQuotedOrBare(tail[eq + 1 ..]) orelse return null;
    return extractVersionNumber(value);
}

fn parseSingleVersionLine(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = util.trimAscii(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        return extractVersionNumber(trimmed);
    }
    return null;
}

fn parsePackageJsonDependency(content: []const u8, package_name: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const quoted = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{package_name}) catch return null;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, content, search_from, quoted)) |index| {
        search_from = index + quoted.len;
        const tail = content[index + quoted.len ..];
        const colon = std.mem.indexOfScalar(u8, tail, ':') orelse continue;
        const value = parseQuotedOrBare(tail[colon + 1 ..]) orelse continue;
        return extractVersionNumber(value);
    }
    return null;
}

fn parsePackageJsonEngines(content: []const u8, engine_name: []const u8) ?[]const u8 {
    const engines = std.mem.indexOf(u8, content, "\"engines\"") orelse return null;
    const tail = content[engines..];
    var needle_buf: [64]u8 = undefined;
    const quoted = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{engine_name}) catch return null;
    const index = std.mem.indexOf(u8, tail, quoted) orelse return null;
    const after = tail[index + quoted.len ..];
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    const value = parseQuotedOrBare(after[colon + 1 ..]) orelse return null;
    return extractVersionNumber(value);
}

fn parseZonStringField(content: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ".{s} = ", .{field}) catch return null;
    const index = std.mem.indexOf(u8, content, needle) orelse return null;
    const tail = content[index + needle.len ..];
    return parseQuotedOrBare(tail);
}

fn parseTomlStringField(content: []const u8, field: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (search_from < content.len) {
        const index = std.mem.indexOfPos(u8, content, search_from, field) orelse return null;
        search_from = index + field.len;
        const tail = content[index + field.len ..];
        const eq = std.mem.indexOfScalar(u8, tail, '=') orelse continue;
        const value = parseQuotedOrBare(tail[eq + 1 ..]) orelse continue;
        return extractVersionNumber(value) orelse value;
    }
    return null;
}

fn parseQuotedOrBare(source: []const u8) ?[]const u8 {
    const trimmed = util.trimAscii(source);
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '"') {
        const end = std.mem.indexOfScalar(u8, trimmed[1..], '"') orelse return null;
        return trimmed[1 .. 1 + end];
    }
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != '\n' and trimmed[end] != ',') : (end += 1) {}
    const bare = util.trimAscii(trimmed[0..end]);
    if (bare.len == 0) return null;
    return bare;
}

fn extractVersionNumber(raw: []const u8) ?[]const u8 {
    var digits: usize = 0;
    var end: usize = 0;
    var saw_digit = false;
    while (end < raw.len) : (end += 1) {
        const c = raw[end];
        if ((c >= '0' and c <= '9') or c == '.') {
            if (c >= '0' and c <= '9') {
                saw_digit = true;
                digits += 1;
            }
            continue;
        }
        if (saw_digit) break;
    }
    if (digits == 0) return null;
    return raw[0..end];
}

fn normalizeVersion(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = util.trimAscii(raw);
    const extracted = extractVersionNumber(trimmed) orelse trimmed;
    var parts: [3]u32 = .{ 0, 0, 0 };
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, extracted, '.');
    while (it.next()) |part| {
        if (count >= parts.len) break;
        const value = std.fmt.parseInt(u32, part, 10) catch 0;
        parts[count] = value;
        count += 1;
    }
    return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ parts[0], parts[1], parts[2] });
}

test "toolchain probe reads python and typescript manifests" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir, ".");

    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse("pyproject.toml"), "[project]\nrequires-python = \">=3.12\"\n");
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse("package.json"), "{\"devDependencies\":{\"typescript\":\"^5.4.2\"}}\n");
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse("build.zig.zon"), ".{\n    .minimum_zig_version = \"0.14.0\",\n}\n");

    var report = try probe(allocator, io, root);
    defer report.deinit(allocator);

    try std.testing.expect(report.languages.len >= 3);
    try std.testing.expect(report.fingerprint != 0);
}

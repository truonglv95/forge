const std = @import("std");
const context_cache = @import("context_cache.zig");
const workspace = @import("forge-workspace");

pub const Options = struct {
    max_hops: u32 = 2,
    max_files: usize = 12,
    preview_bytes: usize = 2048,
    cache: ?*context_cache.ContextCache = null,
};

pub fn collectNeighborPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    seed_paths: []const []const u8,
    skip_paths: []const []const u8,
    options: Options,
) ![]const []const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    for (skip_paths) |path| try markSeen(allocator, &seen, path);
    for (seed_paths) |path| try markSeen(allocator, &seen, path);

    var frontier: std.ArrayList([]const u8) = .empty;
    defer {
        for (frontier.items) |path| allocator.free(path);
        frontier.deinit(allocator);
    }
    for (seed_paths) |path| {
        try frontier.append(allocator, try allocator.dupe(u8, path));
    }

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    var hop: u32 = 0;
    while (hop < options.max_hops and frontier.items.len > 0) : (hop += 1) {
        var next: std.ArrayList([]const u8) = .empty;
        defer next.deinit(allocator);
        errdefer {
            for (next.items) |path| allocator.free(path);
        }

        for (frontier.items) |path| {
            const wp = workspace.WorkspacePath.parse(path) catch continue;
            var mtime: i128 = 0;
            if (root.dir.statFile(io, wp.raw, .{})) |stat| {
                mtime = stat.mtime.nanoseconds;
            } else |_| {}

            var cached_imports: ?[][]const u8 = null;
            if (options.cache) |cache| {
                cache.mutex.lock();
                if (cache.entries.get(path)) |entry| {
                    if (entry.mtime == mtime and entry.imports != null) {
                        cached_imports = entry.imports.?;
                    }
                }
                cache.mutex.unlock();
            }

            var owned_imports: []const []const u8 = undefined;

            if (cached_imports) |imports| {
                var mut_imports = allocator.alloc([]const u8, imports.len) catch continue;
                for (imports, 0..) |imp, i| {
                    mut_imports[i] = allocator.dupe(u8, imp) catch "";
                }
                owned_imports = mut_imports;
            } else {
                var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch continue;
                defer snap.deinit();

                owned_imports = extractImports(allocator, io, root, path, snap.content) catch continue;

                if (options.cache) |cache| {
                    cache.mutex.lock();

                    var owned_path = path;
                    var entry = cache.entries.get(path) orelse context_cache.ContextCache.Entry{ .mtime = mtime };
                    if (entry.mtime != mtime) {
                        if (entry.preview) |p| allocator.free(p);
                        if (entry.imports) |arr| {
                            for (arr) |p| allocator.free(p);
                            allocator.free(arr);
                        }
                        entry = context_cache.ContextCache.Entry{ .mtime = mtime };
                    }
                    if (!cache.entries.contains(path)) {
                        owned_path = allocator.dupe(u8, path) catch path;
                    } else {
                        if (entry.imports) |arr| {
                            for (arr) |p| allocator.free(p);
                            allocator.free(arr);
                        }
                    }

                    if (allocator.alloc([]const u8, owned_imports.len)) |cache_array| {
                        for (owned_imports, 0..) |imp, i| {
                            cache_array[i] = allocator.dupe(u8, imp) catch "";
                        }
                        entry.imports = cache_array;
                        cache.entries.put(owned_path, entry) catch {};
                    } else |_| {}

                    cache.mutex.unlock();
                }
            }

            defer freeImports(allocator, owned_imports);

            for (owned_imports) |import_path| {
                if (seen.contains(import_path)) continue;
                try markSeen(allocator, &seen, import_path);

                try out.append(allocator, try allocator.dupe(u8, import_path));
                if (out.items.len >= options.max_files) return try out.toOwnedSlice(allocator);

                try next.append(allocator, try allocator.dupe(u8, import_path));
            }
        }

        for (frontier.items) |path| allocator.free(path);
        frontier.clearRetainingCapacity();
        try frontier.appendSlice(allocator, next.items);
    }

    return try out.toOwnedSlice(allocator);
}

fn markSeen(allocator: std.mem.Allocator, seen: *std.StringHashMap(void), path: []const u8) !void {
    const owned = try allocator.dupe(u8, path);
    const gop = try seen.getOrPut(owned);
    if (gop.found_existing) allocator.free(owned);
}

pub fn extractImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    content: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    if (std.mem.endsWith(u8, file_path, ".zig")) {
        try extractZigImports(allocator, io, root, file_path, content, &out);
    } else if (endsWithAny(file_path, &.{ ".js", ".ts", ".tsx", ".jsx", ".mjs", ".cjs" })) {
        try extractJsImports(allocator, io, root, file_path, content, &out);
    } else if (endsWithAny(file_path, &.{ ".c", ".h", ".cc", ".cpp", ".hpp" })) {
        try extractCIncludes(allocator, io, root, file_path, content, &out);
    } else if (std.mem.endsWith(u8, file_path, ".py")) {
        try extractPythonImports(allocator, io, root, file_path, content, &out);
    } else if (std.mem.endsWith(u8, file_path, ".rs")) {
        try extractRustImports(allocator, io, root, file_path, content, &out);
    } else if (std.mem.endsWith(u8, file_path, ".go")) {
        try extractGoImports(allocator, io, root, file_path, content, &out);
    } else if (std.mem.endsWith(u8, file_path, ".java")) {
        try extractJavaImports(allocator, io, root, file_path, content, &out);
    }

    return try out.toOwnedSlice(allocator);
}

/// Extract Python imports: `import X`, `from X import Y`, `from . import Y`.
/// Resolves relative imports against the file's directory. Standard library
/// and site-packages modules are NOT resolved to files (they don't live in
/// the workspace).
fn extractPythonImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    content: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    _ = io;
    _ = root;
    const base_dir = std.fs.path.dirname(file_path) orelse ".";

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        // `from X import Y` or `from .X import Y`
        if (std.mem.startsWith(u8, trimmed, "from ")) {
            const rest = std.mem.trim(u8, trimmed[5..], " \t");
            const space_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const module = rest[0..space_idx];
            if (module.len == 0) continue;
            if (try resolvePythonModule(allocator, base_dir, module)) |path| {
                try out.append(allocator, path);
            }
            continue;
        }

        // `import X` or `import X.Y`
        if (std.mem.startsWith(u8, trimmed, "import ")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            // `import X as Y` or `import X, Y`
            var module_part = rest;
            if (std.mem.indexOf(u8, rest, " as ")) |idx| module_part = rest[0..idx];
            if (std.mem.indexOf(u8, module_part, ",")) |idx| module_part = module_part[0..idx];
            module_part = std.mem.trim(u8, module_part, " \t");
            if (module_part.len == 0) continue;
            if (try resolvePythonModule(allocator, base_dir, module_part)) |path| {
                try out.append(allocator, path);
            }
            continue;
        }
    }
}

/// Resolve a Python module name to a workspace-relative file path.
/// `foo.bar` → `foo/bar.py` or `foo/bar/__init__.py`.
/// `.foo` (relative) → `<base_dir>/foo.py`.
fn resolvePythonModule(allocator: std.mem.Allocator, base_dir: []const u8, module: []const u8) !?[]const u8 {
    // Skip stdlib/site-packages (no dots in first segment typically means
    // stdlib like `os`, `sys`; but `foo.bar` is likely local). We resolve
    // all and let the caller filter non-existent paths.
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var mit = std.mem.splitScalar(u8, module, '.');
    while (mit.next()) |part| {
        if (part.len == 0) continue; // relative import dot
        try parts.append(allocator, part);
    }
    if (parts.items.len == 0) return null;

    // Try `dir/parts.../last.py`
    const joined = try std.fs.path.join(allocator, &.{ base_dir, try std.mem.join(allocator, "/", parts.items) });
    defer allocator.free(joined);

    const py_path = try std.fmt.allocPrint(allocator, "{s}.py", .{joined});
    // Caller will check existence; we return the candidate.
    // Avoid duplicate if base_dir is "."
    if (std.mem.eql(u8, base_dir, ".")) {
        const rel = try std.mem.join(allocator, "/", parts.items);
        defer allocator.free(rel);
        allocator.free(py_path);
        return try std.fmt.allocPrint(allocator, "{s}.py", .{rel});
    }
    return py_path;
}

/// Extract Rust imports: `use foo::bar;`, `use crate::baz;`, `mod foo;`.
fn extractRustImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    content: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    _ = io;
    _ = root;
    const base_dir = std.fs.path.dirname(file_path) orelse ".";

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        if (std.mem.startsWith(u8, trimmed, "use ")) {
            const rest = std.mem.trim(u8, trimmed[4..], " \t");
            const semi = std.mem.indexOfScalar(u8, rest, ';') orelse continue;
            const path = rest[0..semi];
            // `use foo::bar::Baz` → `foo/bar.rs` or `foo/bar/mod.rs`
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);
            var pit = std.mem.splitScalar(u8, path, ':');
            while (pit.next()) |part| {
                if (part.len == 0) continue; // skip `::` empty
                try parts.append(allocator, part);
            }
            if (parts.items.len == 0) continue;
            // Skip `crate`, `self`, `super` roots — resolve relative to src/
            if (std.mem.eql(u8, parts.items[0], "crate") or std.mem.eql(u8, parts.items[0], "self") or std.mem.eql(u8, parts.items[0], "super")) {
                // Try src/<rest...>.rs
                const rel = try std.mem.join(allocator, "/", parts.items[1..]);
                defer allocator.free(rel);
                const candidate = try std.fmt.allocPrint(allocator, "src/{s}.rs", .{rel});
                try out.append(allocator, candidate);
            } else {
                const rel = try std.mem.join(allocator, "/", parts.items);
                defer allocator.free(rel);
                const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}.rs", .{ base_dir, rel });
                try out.append(allocator, candidate);
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "mod ")) {
            const rest = std.mem.trim(u8, trimmed[4..], " \t");
            const semi = std.mem.indexOfScalar(u8, rest, ';') orelse continue;
            const name = rest[0..semi];
            if (name.len == 0) continue;
            const candidate1 = try std.fmt.allocPrint(allocator, "{s}/{s}.rs", .{ base_dir, name });
            try out.append(allocator, candidate1);
            const candidate2 = try std.fmt.allocPrint(allocator, "{s}/{s}/mod.rs", .{ base_dir, name });
            try out.append(allocator, candidate2);
            continue;
        }
    }
}

/// Extract Go imports: `import "path"`, `import ( ... )`.
fn extractGoImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    content: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    _ = io;
    _ = root;
    _ = file_path;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        // `import "path"` or `import alias "path"`
        if (std.mem.startsWith(u8, trimmed, "import ")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            if (std.mem.startsWith(u8, rest, "(")) continue; // block import
            const quote_idx = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const end_quote = std.mem.indexOfScalarPos(u8, rest, quote_idx + 1, '"') orelse continue;
            const path = rest[quote_idx + 1 .. end_quote];
            if (path.len > 0) {
                try out.append(allocator, try allocator.dupe(u8, path));
            }
            continue;
        }

        // Inside import block: `"path"` or `alias "path"`
        if (std.mem.startsWith(u8, trimmed, "\"")) {
            const end_quote = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse continue;
            const path = trimmed[1..end_quote];
            if (path.len > 0) {
                try out.append(allocator, try allocator.dupe(u8, path));
            }
            continue;
        }
    }
}

/// Extract Java imports: `import com.foo.Bar;`, `import static com.foo.Bar.baz;`.
fn extractJavaImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    content: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    _ = io;
    _ = root;
    _ = file_path;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        if (std.mem.startsWith(u8, trimmed, "import ")) {
            const rest = std.mem.trim(u8, trimmed[7..], " \t");
            // Skip `static`
            const after = if (std.mem.startsWith(u8, rest, "static ")) rest[7..] else rest;
            const semi = std.mem.indexOfScalar(u8, after, ';') orelse continue;
            const path = after[0..semi];
            // `com.foo.Bar` → `com/foo/Bar.java`
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);
            var pit = std.mem.splitScalar(u8, path, '.');
            while (pit.next()) |part| {
                if (part.len == 0) continue;
                try parts.append(allocator, part);
            }
            if (parts.items.len == 0) continue;
            // Skip if last part is `*` (wildcard import)
            if (std.mem.eql(u8, parts.items[parts.items.len - 1], "*")) continue;
            const rel = try std.mem.join(allocator, "/", parts.items);
            defer allocator.free(rel);
            const candidate = try std.fmt.allocPrint(allocator, "{s}.java", .{rel});
            try out.append(allocator, candidate);
            continue;
        }
    }
}

fn extractCIncludes(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    content: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    _ = io;
    _ = root;
    const base_dir = std.fs.path.dirname(file_path) orelse ".";
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (!std.mem.startsWith(u8, trimmed, "#include")) continue;
        const first_quote = std.mem.indexOfScalar(u8, trimmed, '"') orelse continue;
        const rest = trimmed[first_quote + 1 ..];
        const second_quote = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const include_name = rest[0..second_quote];
        if (include_name.len == 0) continue;
        const joined = try std.fs.path.join(allocator, &.{ base_dir, include_name });
        errdefer allocator.free(joined);
        try out.append(allocator, joined);
    }
}

fn extractZigImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    content: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, content, offset, "@import")) |pos| {
        const open = std.mem.indexOfPos(u8, content, pos, "(") orelse break;
        const quote = std.mem.indexOfPos(u8, content, open + 1, "\"") orelse {
            offset = pos + 1;
            continue;
        };
        const close_quote = std.mem.indexOfPos(u8, content, quote + 1, "\"") orelse {
            offset = pos + 1;
            continue;
        };
        const spec = content[quote + 1 .. close_quote];
        if (resolveRelativeImport(allocator, io, root, file_path, spec)) |resolved| {
            try out.append(allocator, resolved);
        }
        offset = close_quote + 1;
    }
}

fn extractJsImports(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    content: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var offset: usize = 0;
    while (offset < content.len) {
        const from_pos = std.mem.indexOfPos(u8, content, offset, "from") orelse break;
        const quote = std.mem.indexOfPos(u8, content, from_pos, "\"") orelse blk: {
            const sq = std.mem.indexOfPos(u8, content, from_pos, "'") orelse break;
            break :blk sq;
        };
        const quote_char = content[quote];
        const close = std.mem.indexOfPos(u8, content, quote + 1, &[_]u8{quote_char}) orelse break;
        const spec = content[quote + 1 .. close];
        if (std.mem.startsWith(u8, spec, ".")) {
            if (resolveRelativeImport(allocator, io, root, file_path, spec)) |resolved| {
                try out.append(allocator, resolved);
            }
        }
        offset = close + 1;
    }

    offset = 0;
    while (std.mem.indexOfPos(u8, content, offset, "require(")) |pos| {
        const quote = std.mem.indexOfPos(u8, content, pos, "\"") orelse blk: {
            const sq = std.mem.indexOfPos(u8, content, pos, "'") orelse break;
            break :blk sq;
        };
        const quote_char = content[quote];
        const close = std.mem.indexOfPos(u8, content, quote + 1, &[_]u8{quote_char}) orelse break;
        const spec = content[quote + 1 .. close];
        if (std.mem.startsWith(u8, spec, ".")) {
            if (resolveRelativeImport(allocator, io, root, file_path, spec)) |resolved| {
                try out.append(allocator, resolved);
            }
        }
        offset = close + 1;
    }
}

fn resolveRelativeImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    file_path: []const u8,
    spec: []const u8,
) ?[]const u8 {
    if (spec.len == 0) return null;
    if (std.mem.indexOf(u8, spec, "://") != null) return null;

    const dir = std.fs.path.dirname(file_path) orelse "";
    const joined = std.fs.path.resolve(allocator, &.{ dir, spec }) catch return null;
    defer allocator.free(joined);

    const normalized = normalizeWorkspacePath(joined) orelse return null;

    if (fileExists(allocator, io, root, normalized)) {
        return allocator.dupe(u8, normalized) catch null;
    }

    var with_zig: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrint(&with_zig, "{s}.zig", .{normalized})) |path| {
        if (fileExists(allocator, io, root, path)) return allocator.dupe(u8, path) catch null;
    } else |_| {}

    var with_index: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrint(&with_index, "{s}/mod.zig", .{normalized})) |path| {
        if (fileExists(allocator, io, root, path)) return allocator.dupe(u8, path) catch null;
    } else |_| {}

    return null;
}

fn normalizeWorkspacePath(path: []const u8) ?[]const u8 {
    var cleaned = std.mem.trim(u8, path, "/");
    if (std.mem.startsWith(u8, cleaned, "./")) cleaned = cleaned[2..];
    if (cleaned.len == 0 or cleaned.len >= std.fs.max_path_bytes) return null;
    return cleaned;
}

fn fileExists(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, path: []const u8) bool {
    const wp = workspace.WorkspacePath.parse(path) catch return false;
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return false;
    snap.deinit();
    return true;
}

fn endsWithAny(path: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) return true;
    }
    return false;
}

pub fn freeImports(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

pub fn formatImportBlock(allocator: std.mem.Allocator, paths: []const []const u8, previews: []const []const u8) !?[]const u8 {
    if (paths.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Import graph neighbors\n\n");
    for (paths, 0..) |path, index| {
        const preview = if (index < previews.len) previews[index] else "";
        const section = try std.fmt.allocPrint(allocator, "## {s}\n```\n{s}\n```\n\n", .{ path, preview });
        defer allocator.free(section);
        try out.appendSlice(allocator, section);
    }
    return try out.toOwnedSlice(allocator);
}

test "extract zig imports" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.createDirPath(io, "apps");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("lib/util.zig"), "pub fn util() void {}\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("apps/main.zig"),
        \\const std = @import("std");
        \\const util = @import("../lib/util.zig");
    );

    const content = try tmp.dir.readFileAlloc(io, "apps/main.zig", allocator, .unlimited);
    defer allocator.free(content);

    const imports = try extractImports(allocator, io, root, "apps/main.zig", content);
    defer freeImports(allocator, imports);
    try std.testing.expect(imports.len >= 1);
}

test "extract C includes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try tmp.dir.createDirPath(io, "src");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/main.c"),
        \\#include "util.h"
        \\#include <stdio.h>
        \\int main() { return 0; }
    );
    const imports = try extractImports(allocator, io, root, "src/main.c", "#include \"util.h\"\n");
    defer freeImports(allocator, imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("src/util.h", imports[0]);
}

test "collectNeighborPaths does not use freed import keys in seen set" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.createDirPath(io, "apps");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("lib/util.zig"), "pub fn util() void {}\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("lib/helper.zig"),
        \\const util = @import("util.zig");
    );
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("apps/main.zig"),
        \\const helper = @import("../lib/helper.zig");
    );

    const seeds = [_][]const u8{"apps/main.zig"};
    const neighbors = try collectNeighborPaths(allocator, io, root, &seeds, &.{}, .{
        .max_hops = 2,
        .max_files = 8,
    });
    defer freePaths(allocator, neighbors);
    try std.testing.expect(neighbors.len >= 1);
}

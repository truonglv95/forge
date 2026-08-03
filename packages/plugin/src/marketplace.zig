const std = @import("std");
const util = @import("forge-util");
const workspace = @import("forge-workspace");

pub const CatalogEntry = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    publisher: []const u8,
    source: []const u8,

    pub fn deinit(self: *CatalogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.publisher);
        allocator.free(self.source);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    version: u16,
    entries: []CatalogEntry,

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const ParseError = error{
    InvalidSyntax,
    InvalidValue,
    UnknownKey,
    MissingCatalogSection,
    OutOfMemory,
};

pub fn parseCatalog(allocator: std.mem.Allocator, source: []const u8) ParseError!Catalog {
    var catalog = Catalog{ .version = 1, .entries = &.{} };
    var in_catalog = false;
    var in_entry = false;
    var entries: std.ArrayList(CatalogEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var current = CatalogEntry{
        .id = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, ""),
        .version = try allocator.dupe(u8, "0.0.0"),
        .description = try allocator.dupe(u8, ""),
        .publisher = try allocator.dupe(u8, ""),
        .source = try allocator.dupe(u8, ""),
    };
    errdefer current.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
            raw_line[0..index]
        else
            raw_line;
        const line = util.trimAscii(without_comment);
        if (line.len == 0) continue;

        if (line[0] == '[') {
            var inner = line;
            while (inner.len > 0 and inner[0] == '[') inner = inner[1..];
            while (inner.len > 0 and inner[inner.len - 1] == ']') inner = inner[0 .. inner.len - 1];
            const section = util.trimAscii(inner);
            if (std.mem.eql(u8, section, "catalog")) {
                in_catalog = true;
                in_entry = false;
            } else if (std.mem.eql(u8, section, "entry")) {
                if (current.id.len > 0) {
                    try entries.append(allocator, current);
                    current = .{
                        .id = try allocator.dupe(u8, ""),
                        .name = try allocator.dupe(u8, ""),
                        .version = try allocator.dupe(u8, "0.0.0"),
                        .description = try allocator.dupe(u8, ""),
                        .publisher = try allocator.dupe(u8, ""),
                        .source = try allocator.dupe(u8, ""),
                    };
                }
                in_entry = true;
            } else {
                return error.UnknownKey;
            }
            continue;
        }

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSyntax;
        const key = util.trimAscii(line[0..equals]);
        const value = util.trimAscii(line[equals + 1 ..]);

        if (in_catalog and !in_entry) {
            if (std.mem.eql(u8, key, "version")) {
                catalog.version = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            } else {
                return error.UnknownKey;
            }
            continue;
        }

        if (!in_entry) continue;

        const parsed = try parseString(allocator, value);
        if (std.mem.eql(u8, key, "id")) {
            allocator.free(current.id);
            current.id = parsed;
        } else if (std.mem.eql(u8, key, "name")) {
            allocator.free(current.name);
            current.name = parsed;
        } else if (std.mem.eql(u8, key, "version")) {
            allocator.free(current.version);
            current.version = parsed;
        } else if (std.mem.eql(u8, key, "description")) {
            allocator.free(current.description);
            current.description = parsed;
        } else if (std.mem.eql(u8, key, "publisher")) {
            allocator.free(current.publisher);
            current.publisher = parsed;
        } else if (std.mem.eql(u8, key, "source")) {
            allocator.free(current.source);
            current.source = parsed;
        } else {
            allocator.free(parsed);
            return error.UnknownKey;
        }
    }

    if (current.id.len > 0) try entries.append(allocator, current);
    catalog.entries = try entries.toOwnedSlice(allocator);
    if (catalog.entries.len == 0) return error.MissingCatalogSection;
    return catalog;
}

pub fn loadCatalog(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !Catalog {
    const wp = workspace.WorkspacePath.parse("extensions/catalog.toml") catch return error.MissingCatalogSection;
    var snap = try workspace.FileSnapshot.read(allocator, io, root, wp);
    defer snap.deinit();
    return parseCatalog(allocator, snap.content);
}

pub fn findEntry(catalog: *const Catalog, extension_id: []const u8) ?*const CatalogEntry {
    for (catalog.entries) |*entry| {
        if (std.mem.eql(u8, entry.id, extension_id)) return entry;
    }
    return null;
}

pub fn isInstalled(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, entry: *const CatalogEntry) !bool {
    const dest_name = try destinationName(allocator, entry);
    defer allocator.free(dest_name);
    const global_store = @import("forge-workspace").global_store;
    const global_ext = try global_store.getExtensionsDir(allocator);
    defer allocator.free(global_ext);
    const dest_rel = try std.fmt.allocPrint(allocator, "{s}/{s}/forge.toml", .{ global_ext, dest_name });
    defer allocator.free(dest_rel);
    const wp = workspace.WorkspacePath.parse(dest_rel) catch return false;
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return false;
    snap.deinit();
    return true;
}

pub fn install(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    entry: *const CatalogEntry,
) ![]const u8 {
    const dest_name = try destinationName(allocator, entry);
    errdefer allocator.free(dest_name);

    const src_prefix = try std.fmt.allocPrint(allocator, "extensions/{s}", .{entry.source});
    defer allocator.free(src_prefix);
    const global_store = @import("forge-workspace").global_store;
    const global_ext = try global_store.getExtensionsDir(allocator);
    defer allocator.free(global_ext);
    const dst_prefix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ global_ext, dest_name });
    defer allocator.free(dst_prefix);

    try copyTree(allocator, io, root, src_prefix, dst_prefix);
    return dest_name;
}

pub fn uninstall(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, extension_id: []const u8) !void {
    var catalog = loadCatalog(allocator, io, root) catch return error.ExtensionNotInCatalog;
    defer catalog.deinit(allocator);
    const entry = findEntry(&catalog, extension_id) orelse return error.ExtensionNotInCatalog;
    const dest_name = try destinationName(allocator, entry);
    defer allocator.free(dest_name);
    const global_store = @import("forge-workspace").global_store;
    const global_ext = try global_store.getExtensionsDir(allocator);
    defer allocator.free(global_ext);
    const dst_prefix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ global_ext, dest_name });
    defer allocator.free(dst_prefix);
    try deleteTree(allocator, io, root, dst_prefix);
}

fn destinationName(allocator: std.mem.Allocator, entry: *const CatalogEntry) ![]const u8 {
    if (std.mem.lastIndexOfScalar(u8, entry.source, '/')) |idx| {
        return allocator.dupe(u8, entry.source[idx + 1 ..]);
    }
    return allocator.dupe(u8, entry.source);
}

fn parseString(allocator: std.mem.Allocator, value: []const u8) ParseError![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidValue;
    return allocator.dupe(u8, value[1 .. value.len - 1]) catch return error.OutOfMemory;
}

fn copyTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    src_prefix: []const u8,
    dst_prefix: []const u8,
) !void {
    var walker = root.dir.walk(allocator) catch return error.InvalidSyntax;
    defer walker.deinit();

    while (true) {
        const entry_opt = walker.next(io) catch break;
        const entry = entry_opt orelse break;
        if (!std.mem.startsWith(u8, entry.path, src_prefix)) continue;
        const rel = entry.path[src_prefix.len..];
        if (rel.len == 0) continue;
        const rel_trim = if (rel[0] == '/') rel[1..] else rel;
        const dst_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_prefix, rel_trim });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .directory => try workspace.atomic.createDirPath(io, root, dst_path),
            .file => {
                const src_wp = workspace.WorkspacePath.parse(entry.path) catch continue;
                var snap = try workspace.FileSnapshot.read(allocator, io, root, src_wp);
                defer snap.deinit();
                const dst_wp = workspace.WorkspacePath.parse(dst_path) catch continue;
                try workspace.atomic.replaceFile(io, root, dst_wp, snap.content);
            },
            else => {},
        }
    }
}

fn deleteTree(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, prefix: []const u8) !void {
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }

    var walker = root.dir.walk(allocator) catch return;
    defer walker.deinit();
    while (true) {
        const entry_opt = walker.next(io) catch break;
        const entry = entry_opt orelse break;
        if (!std.mem.startsWith(u8, entry.path, prefix)) continue;
        if (entry.kind == .file) {
            try files.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    var i: usize = files.items.len;
    while (i > 0) {
        i -= 1;
        const wp = try workspace.WorkspacePath.parse(files.items[i]);
        workspace.atomic.deleteFile(io, root, wp) catch {};
    }
}

pub const ExtensionNotInCatalog = error{ExtensionNotInCatalog};

test "catalog parser reads entries" {
    const allocator = std.testing.allocator;
    var catalog = try parseCatalog(allocator,
        \\[catalog]
        \\version = 1
        \\
        \\[[entry]]
        \\id = "forge.theme.solarized"
        \\name = "Solarized"
        \\version = "0.1.0"
        \\description = "Solarized theme"
        \\publisher = "forge"
        \\source = "catalog/solarized"
    );
    defer catalog.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try std.testing.expectEqualStrings("forge.theme.solarized", catalog.entries[0].id);
}

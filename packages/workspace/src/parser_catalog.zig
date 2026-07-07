const std = @import("std");

pub const tree_sitter_core_tag = "0.20.8";

pub const Entry = struct {
    language: []const u8,
    tag: []const u8,
    min_version: []const u8,
    origin: []const u8 = "bundled",
    bundled: bool = false,
    vendor_path: ?[]const u8 = null,
    artifact_url: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
};

pub const Catalog = struct {
    tree_sitter_core: []const u8,
    grammars: []const Entry,
};

const grammars = [_]Entry{
    .{
        .language = "python",
        .tag = "v0.23.6",
        .min_version = "3.8.0",
        .origin = "bundled",
        .bundled = true,
        .vendor_path = "third_party/tree-sitter-python",
        .sha256 = "bundled",
    },
    .{
        .language = "typescript",
        .tag = "v0.20.5",
        .min_version = "5.0.0",
        .origin = "bundled",
        .bundled = true,
        .vendor_path = "third_party/tree-sitter-typescript/typescript",
        .sha256 = "bundled",
    },
    .{
        .language = "tsx",
        .tag = "v0.20.5",
        .min_version = "5.0.0",
        .origin = "bundled",
        .bundled = true,
        .vendor_path = "third_party/tree-sitter-typescript/tsx",
        .sha256 = "bundled",
    },
};

pub fn load() Catalog {
    return .{
        .tree_sitter_core = tree_sitter_core_tag,
        .grammars = grammars[0..],
    };
}

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    fn parse(raw: []const u8) Version {
        var parts: [3]u32 = .{ 0, 0, 0 };
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, raw, '.');
        while (it.next()) |part| : (count += 1) {
            if (count >= parts.len) break;
            parts[count] = std.fmt.parseInt(u32, part, 10) catch 0;
        }
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    fn gte(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch >= other.patch;
    }
};

pub fn selectGrammar(catalog: Catalog, language: []const u8, project_version: ?[]const u8, allow_fetch: bool) ?Entry {
    const project = if (project_version) |raw| Version.parse(raw) else null;
    var best: ?Entry = null;
    var best_min = Version{ .major = 0, .minor = 0, .patch = 0 };
    for (catalog.grammars) |entry| {
        if (!std.mem.eql(u8, entry.language, language)) continue;
        if (!entry.bundled and !allow_fetch) continue;
        const min = Version.parse(entry.min_version);
        if (project) |version| {
            if (!version.gte(min)) continue;
        }
        if (best == null or min.gte(best_min)) {
            best = entry;
            best_min = min;
        }
    }
    return best;
}

pub fn findEntry(catalog: Catalog, language: []const u8, tag: []const u8) ?Entry {
    for (catalog.grammars) |entry| {
        if (std.mem.eql(u8, entry.language, language) and std.mem.eql(u8, entry.tag, tag)) {
            return entry;
        }
    }
    return null;
}

test "parser catalog loads bundled grammars" {
    const catalog = load();
    try std.testing.expectEqualStrings("0.20.8", catalog.tree_sitter_core);
    try std.testing.expect(selectGrammar(catalog, "python", "3.12.0", false) != null);
    try std.testing.expectEqualStrings("v0.23.6", selectGrammar(catalog, "python", "3.12.0", false).?.tag);
}

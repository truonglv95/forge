//! Skills system — reusable, user-defined agent capabilities.
//!
//! A skill is a markdown file (.forge/skills/<name>/SKILL.md) with YAML
//! frontmatter that describes a reusable agent capability. Skills are
//! injected into the agent context when the user's intent matches the
//! skill's trigger keywords, similar to Claude Code's Skills system.
//!
//! Example SKILL.md:
//!   ---
//!   name: zig-fmt
//!   description: Format Zig code after edits
//!   triggers: [format, fmt, "zig build"]
//!   tools: [replace_file_content, run_command]
//!   ---
//!   # Zig Format Skill
//!   After editing .zig files, run `zig fmt` to ensure consistent formatting.
//!   Use the run_command tool with `zig fmt <file>` for each modified file.
//!
//! Skills are loaded from .forge/skills/ (project-level) and
//! ~/.forge/skills/ (user-level). Project skills override user skills
//! with the same name.

const std = @import("std");
const workspace = @import("forge-workspace");

pub const SkillError = error{
    InvalidFrontmatter,
    MissingName,
    ReadFailed,
    OutOfMemory,
    WorkspaceFailed,
};

/// YAML frontmatter for a skill.
pub const SkillMeta = struct {
    name: []const u8,
    description: []const u8 = "",
    /// Keywords that trigger this skill. If any keyword appears in the user's
    /// intent, the skill is considered a match.
    triggers: []const []const u8 = &.{},
    /// Tools this skill is allowed to use (optional restriction). If empty,
    /// the skill inherits the agent's current capability profile.
    tools: []const []const u8 = &.{},
    /// Skill scope: project (from .forge/skills/) or user (from ~/.forge/skills/).
    scope: SkillScope = .project,
};

pub const SkillScope = enum { project, user };

/// A loaded skill with its metadata and markdown body.
pub const Skill = struct {
    allocator: std.mem.Allocator,
    meta: SkillMeta,
    body: []const u8, // markdown body (instructions for the agent)
    source_path: []const u8, // absolute path to SKILL.md

    pub fn deinit(self: *Skill) void {
        self.allocator.free(self.meta.name);
        if (self.meta.description.len > 0) self.allocator.free(self.meta.description);
        for (self.meta.triggers) |t| self.allocator.free(t);
        if (self.meta.triggers.len > 0) self.allocator.free(self.meta.triggers);
        for (self.meta.tools) |t| self.allocator.free(t);
        if (self.meta.tools.len > 0) self.allocator.free(self.meta.tools);
        if (self.body.len > 0) self.allocator.free(self.body);
        self.allocator.free(self.source_path);
        self.* = undefined;
    }
};

/// List of loaded skills.
pub const SkillList = struct {
    allocator: std.mem.Allocator,
    items: []Skill,

    pub fn deinit(self: *SkillList) void {
        for (self.items) |*s| s.deinit();
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Load all skills from .forge/skills/ (project) and ~/.forge/skills/ (user).
/// Project skills override user skills with the same name.
pub fn loadAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    home_dir: ?[]const u8,
) SkillError!SkillList {
    var skills: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills.items) |*s| s.deinit();
        skills.deinit(allocator);
    }

    // Load user-level skills first (so project skills can override).
    if (home_dir) |home| {
        loadFromDir(allocator, io, home, .user, &skills) catch {};
    }

    // Load project-level skills.
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);
    const project_skills_dir = std.fmt.allocPrint(allocator, "{s}/skills", .{session_dir}) catch return error.OutOfMemory;
    defer allocator.free(project_skills_dir);
    loadFromDir(allocator, io, project_skills_dir, .project, &skills) catch {};

    return .{ .allocator = allocator, .items = try skills.toOwnedSlice(allocator) };
}

fn loadFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    scope: SkillScope,
    skills: *std.ArrayList(Skill),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const skill_name = entry.name;
        const skill_file_path = std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ dir_path, skill_name }) catch continue;
        defer allocator.free(skill_file_path);

        var file = std.Io.Dir.openFileAbsolute(io, skill_file_path, .{}) catch continue;
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);
        if (size == 0) continue;
        const content = try allocator.alloc(u8, size);
        errdefer allocator.free(content);
        const read = try file.readPositionalAll(io, content, 0);
        if (read == 0) {
            allocator.free(content);
            continue;
        }

        const parsed = parseSkillFile(allocator, content[0..read], skill_file_path, scope) catch {
            allocator.free(content);
            continue;
        };
        defer allocator.free(content);

        // Check if a skill with this name already exists (override).
        var found_existing = false;
        for (skills.items) |*existing| {
            if (std.mem.eql(u8, existing.meta.name, parsed.meta.name)) {
                // Override: free existing and replace.
                existing.deinit();
                existing.* = parsed;
                found_existing = true;
                break;
            }
        }
        if (!found_existing) {
            try skills.append(allocator, parsed);
        } else {
            // parsed was moved into existing; nothing to free.
        }
    }
}

/// Parse a SKILL.md file: extract YAML frontmatter (between --- markers)
/// and the markdown body.
pub fn parseSkillFile(
    allocator: std.mem.Allocator,
    content: []const u8,
    source_path: []const u8,
    scope: SkillScope,
) SkillError!Skill {
    // Find frontmatter delimiters.
    if (!std.mem.startsWith(u8, content, "---")) return error.InvalidFrontmatter;
    const fm_start = 3;
    const fm_end = std.mem.indexOfPos(u8, content, fm_start, "\n---") orelse return error.InvalidFrontmatter;
    const frontmatter = content[fm_start..fm_end];
    const body_start = fm_end + 4; // skip \n---
    const body = if (body_start < content.len) std.mem.trim(u8, content[body_start..], &std.ascii.whitespace) else "";

    const meta = try parseFrontmatter(allocator, frontmatter, scope);

    return .{
        .allocator = allocator,
        .meta = meta,
        .body = if (body.len > 0) try allocator.dupe(u8, body) else "",
        .source_path = try allocator.dupe(u8, source_path),
    };
}

/// Parse simple YAML frontmatter (key: value pairs, with list support for
/// triggers and tools). This is a minimal parser — not full YAML.
fn parseFrontmatter(allocator: std.mem.Allocator, fm: []const u8, scope: SkillScope) SkillError!SkillMeta {
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    errdefer if (name) |n| allocator.free(n);
    errdefer if (description) |d| allocator.free(d);
    var triggers: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (triggers.items) |t| allocator.free(t);
        triggers.deinit(allocator);
    }
    var tools: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tools.items) |t| allocator.free(t);
        tools.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0) continue;

        // Parse "key: value" or "key: [item1, item2]".
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);

        if (std.mem.eql(u8, key, "name")) {
            name = try allocator.dupe(u8, stripQuotes(value));
        } else if (std.mem.eql(u8, key, "description")) {
            description = try allocator.dupe(u8, stripQuotes(value));
        } else if (std.mem.eql(u8, key, "triggers")) {
            try parseList(allocator, value, &triggers);
        } else if (std.mem.eql(u8, key, "tools")) {
            try parseList(allocator, value, &tools);
        }
    }

    if (name == null) return error.MissingName;

    const owned_triggers = if (triggers.items.len > 0)
        try triggers.toOwnedSlice(allocator)
    else
        &[_][]const u8{};
    const owned_tools = if (tools.items.len > 0)
        try tools.toOwnedSlice(allocator)
    else
        &[_][]const u8{};

    return .{
        .name = name.?,
        .description = if (description) |d| d else "",
        .triggers = owned_triggers,
        .tools = owned_tools,
        .scope = scope,
    };
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

fn parseList(allocator: std.mem.Allocator, value: []const u8, list: *std.ArrayList([]const u8)) !void {
    // Parse [item1, item2, item3] or item1 (single value).
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    const inner = if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |item| {
        const cleaned = std.mem.trim(u8, item, &std.ascii.whitespace);
        if (cleaned.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, stripQuotes(cleaned)));
    }
}

/// Check if a skill matches the given intent. Returns true if any trigger
/// keyword appears in the intent (case-insensitive substring match).
pub fn skillMatches(skill: *const Skill, intent: []const u8) bool {
    if (skill.meta.triggers.len == 0) return false;
    for (skill.meta.triggers) |trigger| {
        if (std.mem.indexOf(u8, intent, trigger) != null) return true;
    }
    return false;
}

/// Format a skill as a context block for injection into the agent prompt.
/// Returns owned slice that the caller must free.
pub fn formatSkillBlock(allocator: std.mem.Allocator, skill: *const Skill) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.print(allocator, "## Skill: {s}\n", .{skill.meta.name});
    if (skill.meta.description.len > 0) {
        try buf.print(allocator, "{s}\n\n", .{skill.meta.description});
    }
    if (skill.body.len > 0) {
        try buf.appendSlice(allocator, skill.body);
        try buf.append(allocator, '\n');
    }
    if (skill.meta.tools.len > 0) {
        try buf.appendSlice(allocator, "\nAllowed tools: ");
        for (skill.meta.tools, 0..) |t, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, t);
        }
        try buf.append(allocator, '\n');
    }

    return try buf.toOwnedSlice(allocator);
}

/// Find skills that match the given intent. Returns a list of matching skill
/// names (caller owns the slice and must free each name + the slice).
pub fn findMatchingSkills(
    allocator: std.mem.Allocator,
    skills: []const Skill,
    intent: []const u8,
) ![][]const u8 {
    var matches: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit(allocator);
    }
    for (skills) |*skill| {
        if (skillMatches(skill, intent)) {
            try matches.append(allocator, try allocator.dupe(u8, skill.meta.name));
        }
    }
    return try matches.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "parseSkillFile extracts frontmatter and body" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: zig-fmt
        \\description: "Format Zig code after edits"
        \\triggers: [format, fmt, "zig build"]
        \\tools: [replace_file_content, run_command]
        \\---
        \\# Zig Format Skill
        \\
        \\After editing .zig files, run `zig fmt` to ensure consistent formatting.
    ;
    var skill = try parseSkillFile(allocator, content, ".forge/skills/zig-fmt/SKILL.md", .project);
    defer skill.deinit();

    try std.testing.expectEqualStrings("zig-fmt", skill.meta.name);
    try std.testing.expectEqualStrings("Format Zig code after edits", skill.meta.description);
    try std.testing.expectEqual(@as(usize, 3), skill.meta.triggers.len);
    try std.testing.expectEqualStrings("format", skill.meta.triggers[0]);
    try std.testing.expectEqualStrings("fmt", skill.meta.triggers[1]);
    try std.testing.expectEqualStrings("zig build", skill.meta.triggers[2]);
    try std.testing.expectEqual(@as(usize, 2), skill.meta.tools.len);
    try std.testing.expectEqualStrings("replace_file_content", skill.meta.tools[0]);
    try std.testing.expect(std.mem.indexOf(u8, skill.body, "Zig Format Skill") != null);
}

test "parseSkillFile rejects missing frontmatter" {
    const allocator = std.testing.allocator;
    const content = "no frontmatter here";
    try std.testing.expectError(error.InvalidFrontmatter, parseSkillFile(allocator, content, "test", .project));
}

test "parseSkillFile rejects missing name" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\description: "skill without name"
        \\---
        \\body
    ;
    try std.testing.expectError(error.MissingName, parseSkillFile(allocator, content, "test", .project));
}

test "skillMatches finds trigger in intent" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: test-skill
        \\triggers: [format, fmt]
        \\---
        \\body
    ;
    var skill = try parseSkillFile(allocator, content, "test", .project);
    defer skill.deinit();

    try std.testing.expect(skillMatches(&skill, "please format the code"));
    try std.testing.expect(skillMatches(&skill, "run zig fmt"));
    try std.testing.expect(!skillMatches(&skill, "search for files"));
}

test "skillMatches returns false for empty triggers" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: no-triggers
        \\---
        \\body
    ;
    var skill = try parseSkillFile(allocator, content, "test", .project);
    defer skill.deinit();

    try std.testing.expect(!skillMatches(&skill, "anything"));
}

test "formatSkillBlock produces markdown" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\name: zig-fmt
        \\description: "Format Zig code"
        \\triggers: [format]
        \\tools: [run_command]
        \\---
        \\Run zig fmt after edits.
    ;
    var skill = try parseSkillFile(allocator, content, "test", .project);
    defer skill.deinit();

    const block = try formatSkillBlock(allocator, &skill);
    defer allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "## Skill: zig-fmt") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Format Zig code") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Run zig fmt after edits") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Allowed tools: run_command") != null);
}

test "findMatchingSkills returns matching skill names" {
    const allocator = std.testing.allocator;
    var skill1 = try parseSkillFile(allocator,
        \\---
        \\name: zig-fmt
        \\triggers: [format, fmt]
        \\---
        \\body1
    , "test1", .project);
    defer skill1.deinit();

    var skill2 = try parseSkillFile(allocator,
        \\---
        \\name: python-test
        \\triggers: [pytest, "python test"]
        \\---
        \\body2
    , "test2", .project);
    defer skill2.deinit();

    const skills = [_]Skill{ skill1, skill2 };
    const matches = try findMatchingSkills(allocator, &skills, "run format on src");
    defer {
        for (matches) |m| allocator.free(m);
        allocator.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("zig-fmt", matches[0]);
}

test "parseList handles single value" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |t| allocator.free(t);
        list.deinit(allocator);
    }

    try parseList(allocator, "format", &list);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("format", list.items[0]);
}

test "parseList handles quoted values" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |t| allocator.free(t);
        list.deinit(allocator);
    }

    try parseList(allocator, "[\"zig build\", format]", &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("zig build", list.items[0]);
    try std.testing.expectEqualStrings("format", list.items[1]);
}

test "stripQuotes removes surrounding quotes" {
    try std.testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
    try std.testing.expectEqualStrings("hello", stripQuotes("'hello'"));
    try std.testing.expectEqualStrings("hello", stripQuotes("hello"));
}

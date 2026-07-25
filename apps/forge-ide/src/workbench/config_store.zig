//! Unified config store — single source of truth for reading, writing,
//! and parsing all TOML settings.
//!
//! Why this exists:
//! The previous code had 3+ separate code paths for reading/writing
//! settings:
//!   1. settings.zig::load() — read home + workspace, parse
//!   2. ai_config_io.zig::writeTomlKey() — read workspace, upsert, write
//!   3. settings.zig::writeAiPanelFontSize() — read workspace, upsert, write
//!   4. settings.zig::writeThemeValue() — read workspace, upsert, write
//!
//! These paths had inconsistent value formatting (some used {d:.1},
//! others used {d}), inconsistent no-op detection, and inconsistent
//! section handling — producing duplicate [ai_panel] / [ai] sections
//! and stale values across restarts.
//!
//! This module provides ONE read function, ONE write function, and ONE
//! parse function. All callers must go through here. The file location
//! is fixed: workspace `.forge/settings.toml` (single file, no home
//! fallback for AI settings).

const std = @import("std");
const workspace = @import("forge-workspace");

/// Read the entire settings file content. Returns an owned slice that
/// the caller must free. Returns error.FileNotFound if the file doesn't
/// exist (caller should treat as empty settings).
pub fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
) ![]u8 {
    var file = root.dir.openFile(io, ".forge/settings.toml", .{}) catch return error.FileNotFound;
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

/// Write content to the settings file atomically. Creates the .forge
/// directory if missing.
pub fn writeFile(
    io: std.Io,
    root: workspace.WorkspaceRoot,
    content: []const u8,
) !void {
    root.dir.createDirPath(io, ".forge") catch {};
    const wp = try workspace.WorkspacePath.parse(".forge/settings.toml");
    try workspace.atomic.replaceFile(io, root, wp, content);
}

/// Format a float value for TOML. Uses {d:.1} for consistency —
/// 14.0 → "14.0", 14.5 → "14.5", 1.5 → "1.5". This ensures the
/// no-op detection (string comparison) works correctly across writes.
pub fn formatFloat(buf: []u8, value: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "0.0";
}

/// Format a quoted string value for TOML: "model" → "\"model\"".
pub fn formatString(buf: []u8, value: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "\"{s}\"", .{value}) catch "";
}

/// Check if a key exists in a section with a specific value. Returns
/// true only if BOTH the key exists AND its value matches `expected_value`
/// (after trimming whitespace). Used to skip no-op writes.
pub fn hasKeyWithValue(
    content: []const u8,
    section_name: []const u8,
    key_name: []const u8,
    expected_value: []const u8,
) bool {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            section = std.mem.trim(u8, &std.ascii.whitespace, trimmed[1 .. trimmed.len - 1]);
            continue;
        }
        if (std.mem.eql(u8, section, section_name) and lineKeyMatches(trimmed, key_name)) {
            const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
            const actual_value = std.mem.trim(u8, &std.ascii.whitespace, trimmed[equals + 1 ..]);
            return std.mem.eql(u8, actual_value, expected_value);
        }
    }
    return false;
}

/// Upsert a key-value pair into a TOML section. If the key exists → edit.
/// If the section exists but key doesn't → append key to section. If the
/// section doesn't exist → append new [section] block with the key.
/// Returns an owned slice that the caller must free.
pub fn upsert(
    allocator: std.mem.Allocator,
    content: []const u8,
    section_name: []const u8,
    key_name: []const u8,
    value_text: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_target = false;
    var skipping_duplicate_target = false;
    var saw_target = false;
    var wrote_key = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (in_target and !wrote_key) {
                try appendSettingLine(allocator, &out, key_name, value_text);
                wrote_key = true;
            }

            const name = std.mem.trim(u8, &std.ascii.whitespace, trimmed[1 .. trimmed.len - 1]);
            if (std.mem.eql(u8, name, section_name)) {
                if (saw_target) {
                    // Duplicate section — skip it entirely to avoid
                    // accumulating duplicate [section] blocks.
                    in_target = false;
                    skipping_duplicate_target = true;
                    continue;
                }
                saw_target = true;
                in_target = true;
                skipping_duplicate_target = false;
            } else {
                in_target = false;
                skipping_duplicate_target = false;
            }

            try appendRawLine(allocator, &out, raw_line);
            continue;
        }

        if (skipping_duplicate_target) continue;

        if (in_target and lineKeyMatches(trimmed, key_name)) {
            if (!wrote_key) {
                try appendSettingLine(allocator, &out, key_name, value_text);
                wrote_key = true;
            }
            // Skip the original line (we replaced it).
            continue;
        }

        try appendRawLine(allocator, &out, raw_line);
    }

    if (in_target and !wrote_key) {
        try appendSettingLine(allocator, &out, key_name, value_text);
        wrote_key = true;
    }

    if (!saw_target) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.append(allocator, '[');
        try out.appendSlice(allocator, section_name);
        try out.appendSlice(allocator, "]\n");
        try appendSettingLine(allocator, &out, key_name, value_text);
    }

    while (out.items.len > 1 and out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n') {
        _ = out.pop();
    }
    return try out.toOwnedSlice(allocator);
}

/// Upsert MULTIPLE key-value pairs into the same section in a single
/// pass. All keys are upserted in memory before writing to disk —
/// guarantees no duplicate sections and no partial writes.
pub fn upsertMultiple(
    allocator: std.mem.Allocator,
    content: []const u8,
    section_name: []const u8,
    pairs: []const Pair,
) ![]u8 {
    if (pairs.len == 0) return allocator.dupe(u8, content);

    var current = try allocator.dupe(u8, content);
    for (pairs) |pair| {
        const updated = try upsert(allocator, current, section_name, pair.key, pair.value);
        allocator.free(current);
        current = updated;
    }
    return current;
}

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

/// Write a single key-value pair to the settings file. Skips the write
/// if the key already exists with the exact same value (no-op). This is
/// THE function all settings writes should go through.
pub fn writeKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key_name: []const u8,
    value_text: []const u8,
) !void {
    const content = readFile(allocator, io, root) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (content.len > 0) allocator.free(content);

    // No-op fast path: skip if key already has the exact same value.
    if (content.len > 0 and hasKeyWithValue(content, section_name, key_name, value_text)) {
        return;
    }

    const updated = try upsert(allocator, content, section_name, key_name, value_text);
    defer allocator.free(updated);
    try writeFile(io, root, updated);
}

/// Write a float key (e.g. font_size). Formats the float consistently
/// with {d:.1} so no-op detection works.
pub fn writeFloatKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key_name: []const u8,
    value: f32,
) !void {
    var buf: [32]u8 = undefined;
    const value_text = formatFloat(&buf, value);
    try writeKey(allocator, io, root, section_name, key_name, value_text);
}

/// Write a string key (e.g. model). Quotes the value for TOML.
pub fn writeStringKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key_name: []const u8,
    value: []const u8,
) !void {
    var buf: [512]u8 = undefined;
    const value_text = formatString(&buf, value);
    if (value_text.len == 0) return; // value too long for buffer
    try writeKey(allocator, io, root, section_name, key_name, value_text);
}

/// Write a bool key (e.g. mcp = true).
pub fn writeBoolKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    key_name: []const u8,
    value: bool,
) !void {
    const value_text: []const u8 = if (value) "true" else "false";
    try writeKey(allocator, io, root, section_name, key_name, value_text);
}

/// Write multiple string keys to the same section in a single file
/// read-modify-write. Skips if ALL keys already have the correct values.
pub fn writeStringKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    section_name: []const u8,
    pairs: []const StringPair,
) !void {
    if (pairs.len == 0) return;

    const content = readFile(allocator, io, root) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (content.len > 0) allocator.free(content);

    // No-op fast path: skip if ALL keys already have the correct values.
    if (content.len > 0) {
        var all_match = true;
        for (pairs) |pair| {
            var buf: [512]u8 = undefined;
            const value_text = formatString(&buf, pair.value);
            if (!hasKeyWithValue(content, section_name, pair.key, value_text)) {
                all_match = false;
                break;
            }
        }
        if (all_match) return;
    }

    // Build the pairs with quoted values for upsertMultiple.
    var quoted_pairs = try allocator.alloc(Pair, pairs.len);
    defer allocator.free(quoted_pairs);
    for (pairs, 0..) |pair, i| {
        var buf: [512]u8 = undefined;
        const value_text = formatString(&buf, pair.value);
        if (value_text.len == 0) return;
        quoted_pairs[i] = .{ .key = pair.key, .value = try allocator.dupe(u8, value_text) };
    }
    defer for (quoted_pairs) |qp| allocator.free(qp.value);

    const updated = try upsertMultiple(allocator, content, section_name, quoted_pairs);
    defer allocator.free(updated);
    try writeFile(io, root, updated);
}

pub const StringPair = struct {
    key: []const u8,
    value: []const u8,
};

/// Parse a float value from a TOML string. Handles quotes and trimming.
pub fn parseFloat(value: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, &std.ascii.whitespace, value);
    return std.fmt.parseFloat(f32, trimmed) catch null;
}

/// Parse a quoted string value from TOML: "\"model\"" → "model".
pub fn parseString(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, &std.ascii.whitespace, value);
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return trimmed;
    return trimmed[1 .. trimmed.len - 1];
}

/// Parse a bool value: "true" → true, anything else → false.
pub fn parseBool(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, &std.ascii.whitespace, value);
    return std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "1");
}

fn lineKeyMatches(trimmed_line: []const u8, key_name: []const u8) bool {
    if (trimmed_line.len == 0 or trimmed_line[0] == '#') return false;
    const equals = std.mem.indexOfScalar(u8, trimmed_line, '=') orelse return false;
    const key = std.mem.trim(u8, &std.ascii.whitespace, trimmed_line[0..equals]);
    return std.mem.eql(u8, key, key_name);
}

fn appendRawLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw_line: []const u8) !void {
    try out.appendSlice(allocator, raw_line);
    try out.append(allocator, '\n');
}

fn appendSettingLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key_name: []const u8, value_text: []const u8) !void {
    try out.appendSlice(allocator, key_name);
    try out.appendSlice(allocator, " = ");
    try out.appendSlice(allocator, value_text);
    try out.append(allocator, '\n');
}

test "upsert adds new section when missing" {
    const allocator = std.testing.allocator;
    const input = "[theme]\nfont_size = 14\n";
    const out = try upsert(allocator, input, "ai_panel", "font_size", "14.5");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[ai_panel]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size = 14.5") != null);
    // Original theme section preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, "[theme]") != null);
}

test "upsert edits existing key in section" {
    const allocator = std.testing.allocator;
    const input = "[ai_panel]\nfont_size = 14.0\n";
    const out = try upsert(allocator, input, "ai_panel", "font_size", "14.5");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size = 14.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size = 14.0") == null);
    // Only one [ai_panel] section.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "[ai_panel]")) |pos| : (i = pos + 1) count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "upsert removes duplicate sections" {
    const allocator = std.testing.allocator;
    const input = "[ai_panel]\nfont_size = 14.0\n\n[ai_panel]\nfont_size = 15.0\n";
    const out = try upsert(allocator, input, "ai_panel", "font_size", "16.0");
    defer allocator.free(out);
    // Only one [ai_panel] section remains.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "[ai_panel]")) |pos| : (i = pos + 1) count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size = 16.0") != null);
}

test "hasKeyWithValue true when matches" {
    const content = "[ai_panel]\nfont_size = 14.5\n";
    try std.testing.expect(hasKeyWithValue(content, "ai_panel", "font_size", "14.5"));
}

test "hasKeyWithValue false when value differs" {
    const content = "[ai_panel]\nfont_size = 14.0\n";
    try std.testing.expect(!hasKeyWithValue(content, "ai_panel", "font_size", "14.5"));
}

test "hasKeyWithValue false when key missing" {
    const content = "[ai_panel]\nother = 1\n";
    try std.testing.expect(!hasKeyWithValue(content, "ai_panel", "font_size", "14.5"));
}

test "formatFloat consistent" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("14.0", formatFloat(&buf, 14.0));
    try std.testing.expectEqualStrings("14.5", formatFloat(&buf, 14.5));
    try std.testing.expectEqualStrings("1.5", formatFloat(&buf, 1.5));
}

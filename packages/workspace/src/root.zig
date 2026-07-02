//! Workspace configuration and filesystem-facing contracts.

const std = @import("std");
const core = @import("forge-core");
const util = @import("forge-util");

pub const edit = @import("edit.zig");
pub const FileEdit = edit.FileEdit;
pub const FileOperation = edit.FileOperation;
pub const TextEdit = edit.TextEdit;
pub const WorkspaceEdit = edit.WorkspaceEdit;

pub const subsystem = core.Subsystem.workspace;

pub const AiApplyMode = enum { review, disabled };

pub const Config = struct {
    name: []const u8 = "forge-workspace",
    tab_width: u8 = 4,
    ai_apply_mode: AiApplyMode = .review,

    pub fn parse(source: []const u8) error{ InvalidSyntax, InvalidValue, UnknownKey }!Config {
        var config = Config{};
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, source, '\n');

        while (lines.next()) |raw_line| {
            const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
                raw_line[0..index]
            else
                raw_line;
            const line = util.trimAscii(without_comment);
            if (line.len == 0) continue;

            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSyntax;
                section = util.trimAscii(line[1 .. line.len - 1]);
                continue;
            }

            const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSyntax;
            const key = util.trimAscii(line[0..equals]);
            const value = util.trimAscii(line[equals + 1 ..]);

            if (std.mem.eql(u8, section, "project") and std.mem.eql(u8, key, "name")) {
                config.name = try parseString(value);
            } else if (std.mem.eql(u8, section, "editor") and std.mem.eql(u8, key, "tab_width")) {
                config.tab_width = std.fmt.parseInt(u8, value, 10) catch return error.InvalidValue;
                if (config.tab_width == 0 or config.tab_width > 16) return error.InvalidValue;
            } else if (std.mem.eql(u8, section, "ai") and std.mem.eql(u8, key, "apply_mode")) {
                const mode = try parseString(value);
                config.ai_apply_mode = std.meta.stringToEnum(AiApplyMode, mode) orelse return error.InvalidValue;
            } else {
                return error.UnknownKey;
            }
        }
        return config;
    }
};

fn parseString(value: []const u8) error{InvalidValue}![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidValue;
    }
    return value[1 .. value.len - 1];
}

test "workspace config parses the supported schema" {
    const config = try Config.parse(
        \\[project]
        \\name = "forge"
        \\[editor]
        \\tab_width = 2
        \\[ai]
        \\apply_mode = "review"
    );
    try std.testing.expectEqualStrings("forge", config.name);
    try std.testing.expectEqual(@as(u8, 2), config.tab_width);
    try std.testing.expectEqual(AiApplyMode.review, config.ai_apply_mode);
}

test "workspace config rejects unknown settings" {
    try std.testing.expectError(error.UnknownKey, Config.parse("[project]\ncolor = \"blue\""));
    try std.testing.expectError(error.InvalidValue, Config.parse("[editor]\ntab_width = 0"));
}

test {
    std.testing.refAllDecls(@This());
}

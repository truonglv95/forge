//! Workspace configuration and filesystem-facing contracts.

const std = @import("std");
const core = @import("forge-core");
const util = @import("forge-util");

pub const edit = @import("edit.zig");
pub const FileEdit = edit.FileEdit;
pub const FileOperation = edit.FileOperation;
pub const TextEdit = edit.TextEdit;
pub const WorkspaceEdit = edit.WorkspaceEdit;

pub const path = @import("path.zig");
pub const WorkspacePath = path.WorkspacePath;
pub const WorkspaceRoot = path.WorkspaceRoot;

pub const ignore = @import("ignore.zig");
pub const IgnoreRules = ignore.IgnoreRules;
pub const Limits = ignore.Limits;

pub const snapshot = @import("snapshot.zig");
pub const FileSnapshot = snapshot.FileSnapshot;

pub const atomic = @import("atomic.zig");

pub const transaction = @import("transaction.zig");
pub const TransactionService = transaction.TransactionService;
pub const TransactionRecord = transaction.TransactionRecord;
pub const TransactionState = transaction.TransactionState;

pub const recovery = @import("recovery.zig");

pub const tree = @import("tree.zig");
pub const ScanSummary = tree.ScanSummary;

pub const search = @import("search.zig");
pub const SearchResult = search.SearchResult;

pub const git_diff = @import("git_diff.zig");
pub const recent_files = @import("recent_files.zig");
pub const codebase_index = @import("codebase_index.zig");

pub const watch = @import("watch.zig");
pub const WatchEvent = watch.Event;
pub const WatchEventKind = watch.EventKind;

pub const proposal = @import("proposal.zig");
pub const OwnedProposal = proposal.OwnedProposal;

pub const preview = @import("preview.zig");

pub const history = @import("history.zig");
pub const HistoryEntry = history.Entry;
pub const HistoryEntryList = history.EntryList;
pub const LoadedRecord = history.LoadedRecord;

pub const execution = @import("execution.zig");

pub const checkpoint = @import("checkpoint.zig");
pub const hooks = @import("hooks.zig");

pub const runs = @import("runs.zig");
pub const sessions = @import("sessions.zig");
pub const agent_memory = @import("agent_memory.zig");

pub const theme = @import("theme.zig");
pub const Theme = theme.Theme;
pub const ThemeSettings = theme.ThemeSettings;
pub const ThemePreset = theme.ThemePreset;
pub const FontWeight = theme.FontWeight;
pub const ThemeOverrides = theme.ThemeOverrides;
pub const Rgba = theme.Rgba;

pub const subsystem = core.Subsystem.workspace;

pub const AiApplyMode = enum { review, disabled };

pub const Config = struct {
    name: []const u8 = "forge-workspace",
    tab_width: u8 = 4,
    ai_apply_mode: AiApplyMode = .review,
    ai_provider: []const u8 = "auto",
    ai_model: ?[]const u8 = null,
    ai_mcp_enabled: bool = true,
    theme: theme_mod.ThemeSettings = .{},
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
            } else if (std.mem.eql(u8, section, "ai") and std.mem.eql(u8, key, "provider")) {
                config.ai_provider = try parseString(value);
            } else if (std.mem.eql(u8, section, "ai") and std.mem.eql(u8, key, "model")) {
                config.ai_model = try parseString(value);
            } else if (std.mem.eql(u8, section, "ai") and std.mem.eql(u8, key, "mcp")) {
                config.ai_mcp_enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
            } else if (std.mem.eql(u8, section, "theme")) {
                try config.theme.applyKey(key, value);
            } else {
                return error.UnknownKey;
            }
        }
        return config;
    }

    pub fn buildTheme(self: Config, allocator: std.mem.Allocator) !theme_mod.Theme {
        return theme_mod.Theme.fromSettings(allocator, self.tab_width, self.theme);
    }
};

const theme_mod = @import("theme.zig");

fn parseString(value: []const u8) error{InvalidValue}![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidValue;
    }
    return value[1 .. value.len - 1];
}

test "workspace config parses theme settings" {
    const config = try Config.parse(
        \\[project]
        \\name = "forge"
        \\[editor]
        \\tab_width = 2
        \\[theme]
        \\preset = "light"
        \\font_size = 16
        \\font_weight = "medium"
        \\line_height = 1.4
        \\[ai]
        \\apply_mode = "review"
    );
    try std.testing.expectEqualStrings("forge", config.name);
    try std.testing.expectEqual(@as(u8, 2), config.tab_width);
    try std.testing.expectEqual(ThemePreset.light, config.theme.preset);
    try std.testing.expectEqual(@as(f32, 16), config.theme.font_size);
    try std.testing.expectEqual(FontWeight.medium, config.theme.font_weight);
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

//! Launch configurations — `.forge/launch.json` parsing for the debugger.
//!
//! Replaces the hardcoded `default_launches` in debug_panel.zig with a
//! configurable system modeled on VS Code's `launch.json`. The file
//! format is JSON (we deliberately avoid TOML here because the schema is
//! array-of-objects which TOML handles awkwardly).
//!
//! Schema:
//!   {
//!     "version": "0.1.0",
//!     "configurations": [
//!       {
//!         "name": "Debug Current File",
//!         "type": "lldb-dap",
//!         "request": "launch",
//!         "program": "${file}",
//!         "cwd": "${workspaceFolder}",
//!         "args": [],
//!         "stopOnEntry": false
//!       }
//!     ]
//!   }
//!
//! Variable substitution:
//!   - `${file}` — absolute path of the currently active file.
//!   - `${workspaceFolder}` — absolute path of the workspace root.
//!   - `${fileBasename}` — basename of the active file.
//!   - `${fileDirname}` — directory containing the active file.

const std = @import("std");

pub const Config = struct {
    name: []const u8,
    /// DAP adapter type, e.g. "lldb", "gdb", "python", "node", "go".
    /// Used to autodetect the adapter command.
    type: []const u8,
    /// "launch" or "attach".
    request: []const u8,
    /// Program path (after variable substitution). Owned.
    program: []const u8,
    /// Working directory (owned). Defaults to workspace root.
    cwd: ?[]const u8 = null,
    /// Program arguments (each owned). Empty if none.
    args: []const []const u8 = &.{},
    /// Whether to stop on program entry.
    stop_on_entry: bool = false,
    /// Optional environment variables as "KEY=VALUE" strings (owned).
    env: []const []const u8 = &.{},
    /// For "attach" requests: PID to attach to.
    pid: ?u32 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type);
        allocator.free(self.request);
        allocator.free(self.program);
        if (self.cwd) |c| allocator.free(c);
        for (self.args) |a| allocator.free(a);
        if (self.args.len > 0) allocator.free(self.args);
        for (self.env) |e| allocator.free(e);
        if (self.env.len > 0) allocator.free(self.env);
        self.* = undefined;
    }
};

pub const SubstitutionContext = struct {
    workspace_folder: []const u8,
    active_file: ?[]const u8 = null,
};

/// Auto-detect the best DAP adapter command for a given file extension.
/// Returns the argv (caller may borrow; static data).
pub fn autoDetectAdapter(file_path: []const u8) []const []const u8 {
    const ext = std.fs.path.extension(file_path);
    if (ext.len == 0) return &.{"lldb-dap"};
    const lower = ext[1..];
    if (std.mem.eql(u8, lower, "py")) return &.{ "debugpy", "--adapter" };
    if (std.mem.eql(u8, lower, "js") or std.mem.eql(u8, lower, "ts") or std.mem.eql(u8, lower, "mjs") or std.mem.eql(u8, lower, "cjs")) return &.{"js-debug-adapter"};
    if (std.mem.eql(u8, lower, "go")) return &.{ "dlv", "dap" };
    if (std.mem.eql(u8, lower, "rs")) return &.{"rustc-lldb-dap"};
    if (std.mem.eql(u8, lower, "c") or std.mem.eql(u8, lower, "cpp") or std.mem.eql(u8, lower, "cc") or std.mem.eql(u8, lower, "cxx") or std.mem.eql(u8, lower, "h") or std.mem.eql(u8, lower, "hpp")) return &.{"lldb-dap"};
    if (std.mem.eql(u8, lower, "java")) return &.{"jdtls"};
    if (std.mem.eql(u8, lower, "zig")) return &.{"lldb-dap"};
    // Default to LLDB for unknown extensions (most languages can be
    // debugged via LLDB if compiled with debug info).
    return &.{"lldb-dap"};
}

/// Substitute `${...}` variables in `text` using `ctx`. Returns an owned
/// slice. Unknown variables are left as-is.
pub fn substitute(allocator: std.mem.Allocator, text: []const u8, ctx: SubstitutionContext) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '$' and text[i + 1] == '{') {
            // Find closing brace.
            const end_idx = std.mem.indexOfScalarPos(u8, text, i + 2, '}') orelse {
                try out.append(allocator, text[i]);
                i += 1;
                continue;
            };
            const var_name = text[i + 2 .. end_idx];
            if (std.mem.eql(u8, var_name, "workspaceFolder")) {
                try out.appendSlice(allocator, ctx.workspace_folder);
            } else if (std.mem.eql(u8, var_name, "file")) {
                if (ctx.active_file) |f| try out.appendSlice(allocator, f);
            } else if (std.mem.eql(u8, var_name, "fileBasename")) {
                if (ctx.active_file) |f| {
                    try out.appendSlice(allocator, std.fs.path.basename(f));
                }
            } else if (std.mem.eql(u8, var_name, "fileDirname")) {
                if (ctx.active_file) |f| {
                    try out.appendSlice(allocator, std.fs.path.dirname(f) orelse "");
                }
            } else {
                // Unknown variable — leave as-is.
                try out.appendSlice(allocator, text[i .. end_idx + 1]);
            }
            i = end_idx + 1;
        } else {
            try out.append(allocator, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Parse a `.forge/launch.json` document. Returns an array of owned
/// `Config` items (caller must free with `freeConfigs`).
pub fn parseLaunchJson(allocator: std.mem.Allocator, json_content: []const u8) ![]Config {
    const ConfigJson = struct {
        name: []const u8,
        type: []const u8,
        request: []const u8,
        program: []const u8,
        cwd: ?[]const u8 = null,
        args: ?[]const []const u8 = null,
        stopOnEntry: ?bool = null,
        env: ?std.json.Value = null,
        pid: ?u32 = null,
    };
    const Wrapper = struct {
        configurations: []const ConfigJson = &.{},
    };

    var parsed = try std.json.parseFromSlice(Wrapper, allocator, json_content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var configs: std.ArrayList(Config) = .empty;
    errdefer {
        for (configs.items) |*c| c.deinit(allocator);
        configs.deinit(allocator);
    }

    for (parsed.value.configurations) |cj| {
        const args_owned: []const []const u8 = if (cj.args) |args| blk: {
            const arr = try allocator.alloc([]const u8, args.len);
            for (args, 0..) |a, i| arr[i] = try allocator.dupe(u8, a);
            break :blk arr;
        } else &.{};
        errdefer {
            for (args_owned) |a| allocator.free(a);
            if (args_owned.len > 0) allocator.free(args_owned);
        }

        var env_list: std.ArrayList([]const u8) = .empty;
        errdefer env_list.deinit(allocator);
        if (cj.env) |env_val| {
            if (env_val == .object) {
                var it = env_val.object.iterator();
                while (it.next()) |kv| {
                    const key = kv.key_ptr.*;
                    const val_str = switch (kv.value_ptr.*) {
                        .string => |s| s,
                        .integer => |n| blk: {
                            var buf: [32]u8 = undefined;
                            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
                            break :blk s;
                        },
                        .float => |f| blk: {
                            var buf: [32]u8 = undefined;
                            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0";
                            break :blk s;
                        },
                        .bool => |b| if (b) "true" else "false",
                        else => "",
                    };
                    const line = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, val_str });
                    try env_list.append(allocator, line);
                }
            }
        }
        const env_owned: []const []const u8 = try env_list.toOwnedSlice(allocator);
        errdefer {
            for (env_owned) |e| allocator.free(e);
            allocator.free(env_owned);
        }

        try configs.append(allocator, .{
            .name = try allocator.dupe(u8, cj.name),
            .type = try allocator.dupe(u8, cj.type),
            .request = try allocator.dupe(u8, cj.request),
            .program = try allocator.dupe(u8, cj.program),
            .cwd = if (cj.cwd) |c| try allocator.dupe(u8, c) else null,
            .args = args_owned,
            .stop_on_entry = cj.stopOnEntry orelse false,
            .env = env_owned,
            .pid = cj.pid,
        });
    }

    return configs.toOwnedSlice(allocator);
}

pub fn freeConfigs(allocator: std.mem.Allocator, configs: []Config) void {
    for (configs) |*c| c.deinit(allocator);
    if (configs.len > 0) allocator.free(configs);
}

/// Load `.forge/launch.json` from the workspace root. Returns an empty
/// array (not an error) if the file does not exist.
pub fn loadFromWorkspace(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8) ![]Config {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.forge/launch.json", .{workspace_path}) catch return &.{};

    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return &.{};
    defer file.close(io);
    const stat = file.stat(io) catch return &.{};
    const size: usize = @intCast(stat.size);
    const content = allocator.alloc(u8, size) catch return &.{};
    defer allocator.free(content);
    const read_len = file.readPositionalAll(io, content, 0) catch return &.{};
    if (read_len != size) return &.{};
    return parseLaunchJson(allocator, content);
}

test "substitute replaces ${workspaceFolder} and ${file}" {
    const allocator = std.testing.allocator;
    const result = try substitute(allocator, "${workspaceFolder}/src/${fileBasename}", .{
        .workspace_folder = "/home/user/proj",
        .active_file = "/home/user/proj/src/main.zig",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/proj/src/main.zig", result);
}

test "substitute leaves unknown variables as-is" {
    const allocator = std.testing.allocator;
    const result = try substitute(allocator, "${unknownVar}", .{
        .workspace_folder = "/x",
    });
    defer allocator.free(result);
    try std.testing.expectEqualStrings("${unknownVar}", result);
}

test "autoDetectAdapter picks debugpy for .py" {
    const cmd = autoDetectAdapter("script.py");
    try std.testing.expectEqualStrings("debugpy", cmd[0]);
}

test "autoDetectAdapter picks lldb-dap for .zig" {
    const cmd = autoDetectAdapter("main.zig");
    try std.testing.expectEqualStrings("lldb-dap", cmd[0]);
}

test "parseLaunchJson reads configurations" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "0.1.0",
        \\  "configurations": [
        \\    {
        \\      "name": "Debug",
        \\      "type": "lldb",
        \\      "request": "launch",
        \\      "program": "${file}",
        \\      "stopOnEntry": true
        \\    }
        \\  ]
        \\}
    ;
    const configs = try parseLaunchJson(allocator, json);
    defer freeConfigs(allocator, configs);
    try std.testing.expectEqual(@as(usize, 1), configs.len);
    try std.testing.expectEqualStrings("Debug", configs[0].name);
    try std.testing.expect(configs[0].stop_on_entry);
}

test "parseLaunchJson handles empty configurations" {
    const allocator = std.testing.allocator;
    const json = "{\"configurations\": []}";
    const configs = try parseLaunchJson(allocator, json);
    defer freeConfigs(allocator, configs);
    try std.testing.expectEqual(@as(usize, 0), configs.len);
}

test "parseLaunchJson parses env object" {
    const allocator = std.testing.allocator;
    const json =
        \\{"configurations":[{"name":"t","type":"lldb","request":"launch","program":"x","env":{"FOO":"bar","NUM":42}}]}
    ;
    const configs = try parseLaunchJson(allocator, json);
    defer freeConfigs(allocator, configs);
    try std.testing.expectEqual(@as(usize, 2), configs[0].env.len);
}

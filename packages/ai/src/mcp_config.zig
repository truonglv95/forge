const std = @import("std");
const workspace = @import("forge-workspace");
const process_spawn = @import("forge-util").process_spawn;

pub const ConfigError = error{
    InvalidJson,
    OutOfMemory,
    IoFailed,
    FileTooLarge,
};

pub const Transport = enum {
    stdio,
    http,
    sse,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ServerSpec = struct {
    name: []const u8,
    transport: Transport,
    disabled: bool = false,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    url: ?[]const u8 = null,
    headers: []Header = &.{},
    env: []Header = &.{},
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    servers: []ServerSpec,
    enabled: bool = true,

    pub fn deinit(self: *Config) void {
        for (self.servers) |server| freeServerSpec(self.allocator, server);
        self.allocator.free(self.servers);
        self.* = undefined;
    }
};

pub const LoadContext = struct {
    workspace_cwd: []const u8,
    home_dir: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    io: std.Io,
};

pub fn loadAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    ctx: LoadContext,
) ConfigError!Config {
    var merged: std.StringHashMap(ServerSpec) = .init(allocator);
    errdefer {
        var it = merged.iterator();
        while (it.next()) |entry| freeServerSpec(allocator, entry.value_ptr.*);
        merged.deinit();
    }

    var global_enabled: bool = true;

    const workspace_sources = [_][]const u8{
        ".cursor/mcp.json",
        ".mcp.json",
        ".vscode/mcp.json",
        ".forge/mcp.json",
    };
    for (workspace_sources) |rel| {
        const wp = workspace.WorkspacePath.parse(rel) catch continue;
        var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();
        try mergeJsonInto(allocator, io, snap.content, ctx, &merged, &global_enabled);
    }

    // Also load global ~/.forge/mcp.json
    const global_forge_mcp = workspace.global_store.joinHome(allocator, "mcp.json") catch null;
    if (global_forge_mcp) |gp| {
        defer allocator.free(gp);
        if (std.Io.Dir.openFileAbsolute(io, gp, .{})) |gfile| {
            defer gfile.close(io);
            const content = readFileAlloc(allocator, io, gfile, 1024 * 1024) catch null;
            if (content) |c| {
                defer allocator.free(c);
                try mergeJsonInto(allocator, io, c, ctx, &merged, &global_enabled);
            }
        } else |_| {}
    }

    if (ctx.home_dir) |home| {
        const global_path = try std.fmt.allocPrint(allocator, "{s}/.cursor/mcp.json", .{home});
        defer allocator.free(global_path);
        if (std.Io.Dir.openFileAbsolute(io, global_path, .{})) |file| {
            defer file.close(io);
            const content = readFileAlloc(allocator, io, file, 1024 * 1024) catch return error.OutOfMemory;
            defer allocator.free(content);
            try mergeJsonInto(allocator, io, content, ctx, &merged, &global_enabled);
        } else |_| {}
    }

    if (!global_enabled) {
        var it = merged.iterator();
        while (it.next()) |entry| freeServerSpec(allocator, entry.value_ptr.*);
        merged.deinit();
        return Config{ .allocator = allocator, .servers = &.{}, .enabled = false };
    }

    var list: std.ArrayList(ServerSpec) = .empty;
    errdefer {
        for (list.items) |server| freeServerSpec(allocator, server);
        list.deinit(allocator);
    }

    var it = merged.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.disabled) {
            freeServerSpec(allocator, entry.value_ptr.*);
        } else {
            try list.append(allocator, entry.value_ptr.*);
        }
        allocator.free(entry.key_ptr.*);
    }

    merged.deinit();

    return Config{
        .allocator = allocator,
        .servers = try list.toOwnedSlice(allocator),
        .enabled = true,
    };
}

pub fn loadFromWorkspace(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    workspace_cwd: []const u8,
) ConfigError!Config {
    return loadAll(allocator, io, root, .{ .workspace_cwd = workspace_cwd, .io = io });
}

pub fn envEntries(spec: ServerSpec) []process_spawn.EnvEntry {
    _ = spec;
    return &.{};
}

fn mergeJsonInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    ctx: LoadContext,
    merged: *std.StringHashMap(ServerSpec),
    global_enabled: *bool,
) ConfigError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    const root_val = parsed.value;
    if (root_val != .object) return error.InvalidJson;

    if (root_val.object.get("enabled")) |enabled_val| {
        if (enabled_val == .bool and !enabled_val.bool) global_enabled.* = false;
    }

    const servers_obj = blk: {
        if (root_val.object.get("mcpServers")) |v| {
            if (v == .object) break :blk v.object;
        }
        if (root_val.object.get("servers")) |v| {
            if (v == .object) break :blk v.object;
        }
        return;
    };

    var it = servers_obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const spec = try parseServerEntry(allocator, io, entry.key_ptr.*, entry.value_ptr.object, ctx);
        if (merged.get(entry.key_ptr.*)) |old| freeServerSpec(allocator, old);
        try merged.put(try allocator.dupe(u8, entry.key_ptr.*), spec);
    }
}

fn parseServerEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    obj: std.json.ObjectMap,
    ctx: LoadContext,
) ConfigError!ServerSpec {
    const disabled = blk: {
        if (obj.get("disabled")) |v| {
            if (v == .bool) break :blk v.bool;
        }
        if (obj.get("enabled")) |v| {
            if (v == .bool) break :blk !v.bool;
        }
        break :blk false;
    };

    const transport: Transport = blk: {
        if (obj.get("type")) |t| {
            if (t == .string) {
                if (std.mem.eql(u8, t.string, "http")) break :blk .http;
                if (std.mem.eql(u8, t.string, "sse")) break :blk .sse;
            }
        }
        if (obj.get("url")) |u| {
            if (u == .string) break :blk .http;
        }
        break :blk .stdio;
    };

    const command_owned: ?[]const u8 = if (obj.get("command")) |cmd|
        if (cmd == .string) try expandTemplate(allocator, cmd.string, ctx) else null
    else
        null;

    var args_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args_list.items) |arg| allocator.free(arg);
        args_list.deinit(allocator);
    }
    if (obj.get("args")) |args_val| {
        if (args_val == .array) {
            for (args_val.array.items) |item| {
                if (item != .string) continue;
                try args_list.append(allocator, try expandTemplate(allocator, item.string, ctx));
            }
        }
    }

    const cwd_owned = if (obj.get("cwd")) |cwd_val|
        if (cwd_val == .string) try expandTemplate(allocator, cwd_val.string, ctx) else null
    else
        null;

    const url_owned = if (obj.get("url")) |url_val|
        if (url_val == .string) try expandTemplate(allocator, url_val.string, ctx) else null
    else
        null;

    var env_list: std.ArrayList(Header) = .empty;
    errdefer {
        for (env_list.items) |item| {
            allocator.free(item.name);
            allocator.free(item.value);
        }
        env_list.deinit(allocator);
    }
    if (obj.get("envFile")) |env_file_val| {
        if (env_file_val == .string) {
            try loadEnvFile(allocator, io, env_file_val.string, ctx, &env_list);
        }
    }
    if (obj.get("env")) |env_val| {
        if (env_val == .object) {
            var env_it = env_val.object.iterator();
            while (env_it.next()) |env_entry| {
                const value_str = switch (env_entry.value_ptr.*) {
                    .string => |s| try expandTemplate(allocator, s, ctx),
                    else => continue,
                };
                try env_list.append(allocator, .{
                    .name = try allocator.dupe(u8, env_entry.key_ptr.*),
                    .value = value_str,
                });
            }
        }
    }

    var headers_list: std.ArrayList(Header) = .empty;
    errdefer {
        for (headers_list.items) |item| {
            allocator.free(item.name);
            allocator.free(item.value);
        }
        headers_list.deinit(allocator);
    }
    if (obj.get("headers")) |headers_val| {
        if (headers_val == .object) {
            var hdr_it = headers_val.object.iterator();
            while (hdr_it.next()) |hdr_entry| {
                if (hdr_entry.value_ptr.* != .string) continue;
                try headers_list.append(allocator, .{
                    .name = try allocator.dupe(u8, hdr_entry.key_ptr.*),
                    .value = try expandTemplate(allocator, hdr_entry.value_ptr.string, ctx),
                });
            }
        }
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .transport = transport,
        .disabled = disabled,
        .command = command_owned,
        .args = try args_list.toOwnedSlice(allocator),
        .cwd = cwd_owned,
        .url = url_owned,
        .headers = try headers_list.toOwnedSlice(allocator),
        .env = try env_list.toOwnedSlice(allocator),
    };
}

fn loadEnvFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    rel_path: []const u8,
    ctx: LoadContext,
    out: *std.ArrayList(Header),
) ConfigError!void {
    const abs = try std.fs.path.join(allocator, &.{ ctx.workspace_cwd, rel_path });
    defer allocator.free(abs);
    var file = std.Io.Dir.openFileAbsolute(io, abs, .{}) catch return;
    defer file.close(io);
    const content = readFileAlloc(allocator, io, file, 256 * 1024) catch return error.OutOfMemory;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) continue;
        const expanded = try expandTemplate(allocator, value, ctx);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, key),
            .value = expanded,
        });
    }
}

pub fn expandTemplate(allocator: std.mem.Allocator, text: []const u8, ctx: LoadContext) ConfigError![]u8 {
    var out = try allocator.dupe(u8, text);
    errdefer allocator.free(out);

    const replacements = [_]struct { needle: []const u8, value: ?[]const u8 }{
        .{ .needle = "${workspaceFolder}", .value = ctx.workspace_cwd },
        .{ .needle = "${userHome}", .value = ctx.home_dir },
    };
    for (replacements) |item| {
        const value = item.value orelse continue;
        const new_out = try replaceAll(allocator, out, item.needle, value);
        allocator.free(out);
        out = new_out;
    }

    while (std.mem.indexOf(u8, out, "${env:")) |start| {
        const rest = out[start + "${env:".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '}') orelse break;
        const var_name = rest[0..end];
        const value = if (ctx.environ_map) |map| map.get(var_name) else null;
        var needle_buf: [256]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "${{env:{s}}}", .{var_name}) catch break;
        const replacement = value orelse "";
        const new_out = try replaceAll(allocator, out, needle, replacement);
        allocator.free(out);
        out = new_out;
    }

    return out;
}

fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ConfigError![]u8 {
    if (needle.len == 0) return try allocator.dupe(u8, haystack);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |idx| {
        try result.appendSlice(allocator, haystack[i..idx]);
        try result.appendSlice(allocator, replacement);
        i = idx + needle.len;
    }
    try result.appendSlice(allocator, haystack[i..]);
    return try result.toOwnedSlice(allocator);
}

fn readFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    max_size: usize,
) ConfigError![]u8 {
    const stat = file.stat(io) catch return error.IoFailed;
    if (stat.size > max_size) return error.FileTooLarge;
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = file.readPositionalAll(io, content, 0) catch return error.IoFailed;
    if (read_len != size) return error.IoFailed;
    return content;
}

fn freeServerSpec(allocator: std.mem.Allocator, server: ServerSpec) void {
    allocator.free(server.name);
    if (server.command) |cmd| allocator.free(cmd);
    for (server.args) |arg| allocator.free(arg);
    allocator.free(server.args);
    if (server.cwd) |cwd| allocator.free(cwd);
    if (server.url) |url| allocator.free(url);
    for (server.headers) |hdr| {
        allocator.free(hdr.name);
        allocator.free(hdr.value);
    }
    allocator.free(server.headers);
    for (server.env) |item| {
        allocator.free(item.name);
        allocator.free(item.value);
    }
    allocator.free(server.env);
}

pub fn parseJson(allocator: std.mem.Allocator, source: []const u8, workspace_cwd: []const u8) ConfigError!Config {
    var merged: std.StringHashMap(ServerSpec) = .init(allocator);
    errdefer {
        var it = merged.iterator();
        while (it.next()) |entry| freeServerSpec(allocator, entry.value_ptr.*);
        merged.deinit();
    }
    var global_enabled: bool = true;
    try mergeJsonInto(allocator, std.testing.io, source, .{ .workspace_cwd = workspace_cwd, .io = std.testing.io }, &merged, &global_enabled);
    if (!global_enabled) {
        merged.deinit();
        return Config{ .allocator = allocator, .servers = &.{}, .enabled = false };
    }
    var list: std.ArrayList(ServerSpec) = .empty;
    errdefer {
        for (list.items) |server| freeServerSpec(allocator, server);
        list.deinit(allocator);
    }
    var it = merged.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    merged.deinit();
    return Config{
        .allocator = allocator,
        .servers = try list.toOwnedSlice(allocator),
        .enabled = true,
    };
}

test "parseJson reads mcpServers with env" {
    const allocator = std.testing.allocator;
    const src =
        \\{"mcpServers":{"demo":{"command":"echo","args":["hi"],"env":{"FOO":"bar"}}}}
    ;
    var cfg = try parseJson(allocator, src, "/tmp/ws");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.servers.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.servers[0].env.len);
    try std.testing.expectEqualStrings("FOO", cfg.servers[0].env[0].name);
}

test "expandTemplate replaces workspaceFolder" {
    const allocator = std.testing.allocator;
    const out = try expandTemplate(allocator, "${workspaceFolder}/x", .{ .workspace_cwd = "/ws", .io = std.testing.io });
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/ws/x", out);
}

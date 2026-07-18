const std = @import("std");

pub const api_version_major: u16 = 1;
pub const api_version_minor: u16 = 0;

pub const Runtime = enum {
    native,
    builtin,
    wasm,

    pub fn tomlValue(self: Runtime) []const u8 {
        return switch (self) {
            .native => "native",
            .builtin => "builtin",
            .wasm => "wasm",
        };
    }
};

pub const Command = struct {
    id: []const u8,
    title: []const u8,
};

pub const Theme = struct {
    id: []const u8,
    label: []const u8,
    path: []const u8,
};

pub const Keybinding = struct {
    key: []const u8,
    command: []const u8,
};

pub const Language = struct {
    id: []const u8,
    server: []const u8,
    args: []const u8 = "",
    file_pattern: []const u8,
    server_resolver: []const u8 = "",
};

pub const ManifestBuilder = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    version: []const u8 = "0.1.0",
    runtime: Runtime = .native,
    entry: []const u8 = "",
    commands: std.ArrayList(Command) = .empty,
    themes: std.ArrayList(Theme) = .empty,
    keybindings: std.ArrayList(Keybinding) = .empty,
    languages: std.ArrayList(Language) = .empty,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8) ManifestBuilder {
        return .{
            .allocator = allocator,
            .id = id,
            .name = name,
        };
    }

    pub fn deinit(self: *ManifestBuilder) void {
        self.commands.deinit(self.allocator);
        self.themes.deinit(self.allocator);
        self.keybindings.deinit(self.allocator);
        self.languages.deinit(self.allocator);
    }

    pub fn setVersion(self: *ManifestBuilder, version: []const u8) void {
        self.version = version;
    }

    pub fn setRuntime(self: *ManifestBuilder, runtime: Runtime, entry: []const u8) void {
        self.runtime = runtime;
        self.entry = entry;
    }

    pub fn command(self: *ManifestBuilder, id: []const u8, title: []const u8) !void {
        try self.commands.append(self.allocator, .{ .id = id, .title = title });
    }

    pub fn theme(self: *ManifestBuilder, id: []const u8, label: []const u8, path: []const u8) !void {
        try self.themes.append(self.allocator, .{ .id = id, .label = label, .path = path });
    }

    pub fn keybinding(self: *ManifestBuilder, key: []const u8, command_id: []const u8) !void {
        try self.keybindings.append(self.allocator, .{ .key = key, .command = command_id });
    }

    pub fn language(self: *ManifestBuilder, registration: Language) !void {
        try self.languages.append(self.allocator, registration);
    }

    pub fn writeToml(self: *const ManifestBuilder, writer: *std.Io.Writer) !void {
        try writer.print(
            \\[extension]
            \\id = "{s}"
            \\name = "{s}"
            \\version = "{s}"
            \\api_version = {d}
            \\runtime = "{s}"
            \\
        , .{ self.id, self.name, self.version, api_version_major, self.runtime.tomlValue() });
        if (self.entry.len > 0) try writer.print("entry = \"{s}\"\n\n", .{self.entry});

        for (self.commands.items) |item| {
            try writer.print(
                \\[[commands]]
                \\id = "{s}"
                \\title = "{s}"
                \\
            , .{ item.id, item.title });
        }

        for (self.themes.items) |item| {
            try writer.print(
                \\[[themes]]
                \\id = "{s}"
                \\label = "{s}"
                \\path = "{s}"
                \\
            , .{ item.id, item.label, item.path });
        }

        for (self.keybindings.items) |item| {
            try writer.print(
                \\[[keybindings]]
                \\key = "{s}"
                \\command = "{s}"
                \\
            , .{ item.key, item.command });
        }

        for (self.languages.items) |item| {
            try writer.print(
                \\[[languages]]
                \\id = "{s}"
                \\server = "{s}"
                \\args = "{s}"
                \\file_pattern = "{s}"
                \\
            , .{ item.id, item.server, item.args, item.file_pattern });
            if (item.server_resolver.len > 0) {
                try writer.print("server_resolver = \"{s}\"\n\n", .{item.server_resolver});
            }
        }
    }

    pub fn toTomlAlloc(self: *const ManifestBuilder, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try self.writeToml(&out.writer);
        return out.toOwnedSlice();
    }
};

pub const guest = struct {
    extern "forge_host" fn forge_host_log(ptr: u32, len: u32) void;
    extern "forge_host" fn forge_host_set_status(ptr: u32, len: u32) void;
    extern "forge_host" fn forge_host_read_file(path_ptr: u32, path_len: u32, buf_ptr: u32, buf_cap: u32) i32;
    extern "forge_host" fn forge_host_lsp_for_file(path_ptr: u32, path_len: u32, buf_ptr: u32, buf_cap: u32) i32;
    extern "forge_host" fn forge_host_lsp_request(lang_ptr: u32, lang_len: u32, req_ptr: u32, req_len: u32, resp_ptr: u32, resp_cap: u32) i32;

    pub fn log(message: []const u8) void {
        forge_host_log(@intCast(@intFromPtr(message.ptr)), @intCast(message.len));
    }

    pub fn setStatus(message: []const u8) void {
        forge_host_set_status(@intCast(@intFromPtr(message.ptr)), @intCast(message.len));
    }

    pub fn readFile(path: []const u8, out: []u8) ?[]const u8 {
        const len = forge_host_read_file(
            @intCast(@intFromPtr(path.ptr)),
            @intCast(path.len),
            @intCast(@intFromPtr(out.ptr)),
            @intCast(out.len),
        );
        if (len < 0) return null;
        return out[0..@intCast(len)];
    }

    pub fn languageForFile(path: []const u8, out: []u8) ?[]const u8 {
        const len = forge_host_lsp_for_file(
            @intCast(@intFromPtr(path.ptr)),
            @intCast(path.len),
            @intCast(@intFromPtr(out.ptr)),
            @intCast(out.len),
        );
        if (len < 0) return null;
        return out[0..@intCast(len)];
    }

    pub fn lspRequest(language_id: []const u8, request_json: []const u8, out: []u8) ?[]const u8 {
        const len = forge_host_lsp_request(
            @intCast(@intFromPtr(language_id.ptr)),
            @intCast(language_id.len),
            @intCast(@intFromPtr(request_json.ptr)),
            @intCast(request_json.len),
            @intCast(@intFromPtr(out.ptr)),
            @intCast(out.len),
        );
        if (len < 0) return null;
        return out[0..@intCast(len)];
    }
};

test "manifest builder renders commands and languages" {
    const allocator = std.testing.allocator;
    var builder = ManifestBuilder.init(allocator, "forge.test", "Forge Test");
    defer builder.deinit();

    builder.setRuntime(.wasm, "main.wasm");
    try builder.command("forge.test.hello", "Hello");
    try builder.language(.{
        .id = "zig",
        .server = "zls",
        .file_pattern = "*.zig",
        .server_resolver = "vscode-zig-zls",
    });

    const toml = try builder.toTomlAlloc(allocator);
    defer allocator.free(toml);

    try std.testing.expect(std.mem.indexOf(u8, toml, "id = \"forge.test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "runtime = \"wasm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toml, "server_resolver = \"vscode-zig-zls\"") != null);
}

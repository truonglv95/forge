const std = @import("std");
const manifest_mod = @import("manifest.zig");
const root_mod = @import("root.zig");
const workspace = @import("forge-workspace");
const contributions_mod = @import("contributions.zig");
const vscode_shim = @import("vscode_shim.zig");
const wasm_mod = @import("wasm_runtime.zig");

pub const ActivationContext = struct {
    allocator: std.mem.Allocator,
    extension_id: []const u8,
    host: *Host,
};

pub const CommandEntry = struct {
    id: []const u8,
    title: []const u8,
};

pub const BuiltinExtension = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    commands: []const CommandEntry,
    activate: *const fn (ctx: *ActivationContext) anyerror!void,
    deactivate: ?*const fn (ctx: *ActivationContext) void = null,
    executeCommand: ?*const fn (ctx: *ActivationContext, command_id: []const u8) anyerror!void = null,
};

pub const LoadedExtension = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    root_path: []const u8,
    manifest: ?manifest_mod.Manifest = null,
    builtin: ?*const BuiltinExtension = null,
    wasm: ?*wasm_mod.WasmInstance = null,
    active: bool = false,
    commands: std.ArrayList(CommandRegistration),

    pub const CommandRegistration = struct {
        id: []const u8,
        title: []const u8,
        extension_id: []const u8,
    };

    pub fn deinit(self: *LoadedExtension, allocator: std.mem.Allocator) void {
        if (self.wasm) |guest| {
            wasm_mod.WasmRuntime.deactivate(guest);
            guest.deinit(allocator);
        }
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.root_path);
        if (self.manifest) |*m| m.deinit(allocator);
        for (self.commands.items) |cmd| {
            allocator.free(cmd.id);
            allocator.free(cmd.title);
            allocator.free(cmd.extension_id);
        }
        self.commands.deinit(allocator);
        self.* = undefined;
    }
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    extensions: std.ArrayList(LoadedExtension),
    contributions: contributions_mod.Registry,
    host_api_version: root_mod.ApiVersion = .{ .major = 1, .minor = 0 },
    workspace_root: ?workspace.WorkspaceRoot = null,
    host_callbacks: ?wasm_mod.HostCallbacks = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Host {
        return .{
            .allocator = allocator,
            .io = io,
            .extensions = .empty,
            .contributions = contributions_mod.Registry.init(allocator),
        };
    }

    pub fn deinit(self: *Host) void {
        var i: usize = self.extensions.items.len;
        while (i > 0) {
            i -= 1;
            if (self.extensions.items[i].active) {
                self.deactivateExtension(self.extensions.items[i].id) catch {};
            }
            self.extensions.items[i].deinit(self.allocator);
        }
        self.extensions.deinit(self.allocator);
        self.contributions.deinit(self.allocator);
    }

    pub fn registerBuiltin(self: *Host, ext: *const BuiltinExtension) !void {
        var loaded = LoadedExtension{
            .id = try self.allocator.dupe(u8, ext.id),
            .name = try self.allocator.dupe(u8, ext.name),
            .version = try self.allocator.dupe(u8, ext.version),
            .root_path = try self.allocator.dupe(u8, "(builtin)"),
            .builtin = ext,
            .commands = .empty,
        };
        errdefer loaded.deinit(self.allocator);

        for (ext.commands) |cmd| {
            try loaded.commands.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, cmd.id),
                .title = try self.allocator.dupe(u8, cmd.title),
                .extension_id = try self.allocator.dupe(u8, ext.id),
            });
        }

        try self.extensions.append(self.allocator, loaded);
    }

    pub fn setHostCallbacks(self: *Host, callbacks: wasm_mod.HostCallbacks) void {
        self.host_callbacks = callbacks;
    }

    pub fn discoverWorkspace(self: *Host, root: workspace.WorkspaceRoot) !void {
        self.workspace_root = root;
        try self.discoverUnderRoot(root, "extensions");
        const global_store = @import("forge-workspace").global_store;
        if (global_store.getExtensionsDir(self.allocator)) |global_ext| {
            defer self.allocator.free(global_ext);
            self.discoverAbsolute(global_ext) catch {};
        } else |_| {}
    }

    fn discoverUnderRoot(self: *Host, root: workspace.WorkspaceRoot, parent_rel: []const u8) !void {
        var walker = root.dir.walk(self.allocator) catch return;
        defer walker.deinit();

        while (true) {
            const entry_opt = walker.next(self.io) catch break;
            const entry = entry_opt orelse break;

            if (entry.kind != .directory) continue;
            if (!std.mem.startsWith(u8, entry.path, parent_rel)) continue;
            if (entry.path.len <= parent_rel.len + 1) continue;
            if (entry.path[parent_rel.len] != '/') continue;
            const rel = entry.path[parent_rel.len + 1 ..];
            var slash_count: usize = 0;
            for (rel) |c| {
                if (c == '/') slash_count += 1;
            }
            if (slash_count > 1) continue;
            if (std.mem.startsWith(u8, rel, "catalog/")) continue;

            if (try self.tryLoadManifest(root, entry.path)) |loaded_value| {
                var loaded = loaded_value;
                if (self.findExtension(loaded.id) != null) {
                    loaded.deinit(self.allocator);
                    continue;
                }
                try self.extensions.append(self.allocator, loaded);
            }
        }
    }

    fn discoverAbsolute(self: *Host, parent_abs: []const u8) !void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, parent_abs, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;

            if (entry.kind != .directory) continue;
            if (std.mem.startsWith(u8, entry.name, "catalog")) continue;

            const entry_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent_abs, entry.name });
            defer self.allocator.free(entry_path);

            if (try self.tryLoadManifestAbsolute(entry_path)) |loaded_value| {
                var loaded = loaded_value;
                if (self.findExtension(loaded.id) != null) {
                    loaded.deinit(self.allocator);
                    continue;
                }
                try self.extensions.append(self.allocator, loaded);
            }
        }
    }

    fn tryLoadManifestAbsolute(self: *Host, entry_path: []const u8) !?LoadedExtension {
        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/forge.toml", .{entry_path});
        defer self.allocator.free(manifest_path);

        if (workspace.global_store.readAbsoluteFile(self.allocator, self.io, manifest_path)) |content| {
            defer self.allocator.free(content);
            return self.loadFromManifestSource(entry_path, content);
        } else |_| {}

        const package_path = try std.fmt.allocPrint(self.allocator, "{s}/package.json", .{entry_path});
        defer self.allocator.free(package_path);

        if (workspace.global_store.readAbsoluteFile(self.allocator, self.io, package_path)) |content| {
            defer self.allocator.free(content);
            return self.loadFromPackageJsonSource(entry_path, content);
        } else |_| {}

        return null;
    }

    fn tryLoadManifest(self: *Host, root: workspace.WorkspaceRoot, entry_path: []const u8) !?LoadedExtension {
        const manifest_rel = try std.fmt.allocPrint(self.allocator, "{s}/forge.toml", .{entry_path});
        defer self.allocator.free(manifest_rel);

        if (workspace.WorkspacePath.parse(manifest_rel)) |wp| {
            var snap = workspace.FileSnapshot.read(self.allocator, self.io, root, wp) catch return null;
            defer snap.deinit();
            return self.loadFromManifestSource(entry_path, snap.content);
        } else |_| {}

        const package_rel = try std.fmt.allocPrint(self.allocator, "{s}/package.json", .{entry_path});
        defer self.allocator.free(package_rel);
        const package_wp = workspace.WorkspacePath.parse(package_rel) catch return null;
        var package_snap = workspace.FileSnapshot.read(self.allocator, self.io, root, package_wp) catch return null;
        defer package_snap.deinit();
        return self.loadFromPackageJsonSource(entry_path, package_snap.content);
    }

    fn loadFromManifestSource(self: *Host, entry_path: []const u8, source: []const u8) !?LoadedExtension {
        var parsed = manifest_mod.parse(self.allocator, source) catch return null;
        errdefer parsed.deinit(self.allocator);

        if (!root_mod.ApiVersion.isCompatible(self.host_api_version, parsed.api_version)) {
            parsed.deinit(self.allocator);
            return null;
        }

        return try self.loadedFromManifest(entry_path, parsed);
    }

    fn loadFromPackageJsonSource(self: *Host, entry_path: []const u8, source: []const u8) !?LoadedExtension {
        var parsed = vscode_shim.importPackageJson(self.allocator, source) catch return null;
        errdefer parsed.deinit(self.allocator);
        return try self.loadedFromManifest(entry_path, parsed);
    }

    fn loadedFromManifest(self: *Host, entry_path: []const u8, parsed: manifest_mod.Manifest) !LoadedExtension {
        var loaded = LoadedExtension{
            .id = try self.allocator.dupe(u8, parsed.id),
            .name = try self.allocator.dupe(u8, parsed.name),
            .version = try self.allocator.dupe(u8, parsed.version),
            .root_path = try self.allocator.dupe(u8, entry_path),
            .manifest = parsed,
            .commands = .empty,
        };
        errdefer loaded.deinit(self.allocator);

        for (parsed.commands) |cmd| {
            try loaded.commands.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, cmd.id),
                .title = try self.allocator.dupe(u8, cmd.title),
                .extension_id = try self.allocator.dupe(u8, parsed.id),
            });
        }

        return loaded;
    }

    pub fn rebuildContributions(self: *Host) !void {
        self.contributions.clear(self.allocator);
        for (self.extensions.items) |*ext| {
            if (!ext.active) continue;
            if (ext.manifest) |*manifest| {
                try self.contributions.registerManifest(self.allocator, ext.id, ext.root_path, manifest);
            }
        }
    }

    pub fn activateAll(self: *Host) !void {
        for (self.extensions.items) |*ext| {
            try self.activateExtension(ext.id);
        }
        try self.rebuildContributions();
    }

    pub fn activateExtension(self: *Host, extension_id: []const u8) !void {
        const ext = self.findExtension(extension_id) orelse return error.ExtensionNotFound;
        if (ext.active) return;

        if (ext.builtin) |builtin| {
            var ctx = ActivationContext{
                .allocator = self.allocator,
                .extension_id = ext.id,
                .host = self,
            };
            try builtin.activate(&ctx);
        } else if (ext.manifest) |*manifest| {
            if (manifest.runtime == .wasm) {
                const root = self.workspace_root orelse return error.ExtensionNotFound;
                const callbacks = self.host_callbacks orelse wasm_mod.HostCallbacks{
                    .log = noopLog,
                    .set_status = noopSetStatus,
                };
                ext.wasm = try wasm_mod.WasmRuntime.loadAndActivate(
                    self.allocator,
                    self.io,
                    root,
                    ext.root_path,
                    manifest.entry,
                    callbacks,
                    wasm_mod.limitsFromManifest(manifest),
                );
            }
        }
        ext.active = true;
        try self.rebuildContributions();
    }

    pub fn deactivateExtension(self: *Host, extension_id: []const u8) !void {
        const ext = self.findExtension(extension_id) orelse return error.ExtensionNotFound;
        if (!ext.active) return;

        if (ext.builtin) |builtin| {
            if (builtin.deactivate) |deactivate| {
                var ctx = ActivationContext{
                    .allocator = self.allocator,
                    .extension_id = ext.id,
                    .host = self,
                };
                deactivate(&ctx);
            }
        } else if (ext.wasm) |guest| {
            wasm_mod.WasmRuntime.deactivate(guest);
            guest.deinit(self.allocator);
            ext.wasm = null;
        }
        ext.active = false;
        try self.rebuildContributions();
    }

    pub fn executeCommand(self: *Host, command_id: []const u8) !void {
        for (self.extensions.items) |*ext| {
            if (!ext.active) continue;
            for (ext.commands.items) |cmd| {
                if (!std.mem.eql(u8, cmd.id, command_id)) continue;
                if (ext.builtin) |builtin| {
                    if (builtin.executeCommand) |execute| {
                        var ctx = ActivationContext{
                            .allocator = self.allocator,
                            .extension_id = ext.id,
                            .host = self,
                        };
                        try execute(&ctx, command_id);
                    }
                } else if (ext.wasm) |guest| {
                    try wasm_mod.WasmRuntime.executeCommand(guest, command_id);
                }
                return;
            }
        }
        return error.CommandNotFound;
    }

    pub fn extensionCount(self: *const Host) usize {
        return self.extensions.items.len;
    }

    pub fn activeExtensionCount(self: *const Host) usize {
        var count: usize = 0;
        for (self.extensions.items) |ext| {
            if (ext.active) count += 1;
        }
        return count;
    }

    fn findExtension(self: *Host, extension_id: []const u8) ?*LoadedExtension {
        for (self.extensions.items) |*ext| {
            if (std.mem.eql(u8, ext.id, extension_id)) return ext;
        }
        return null;
    }
};

fn noopLog(_: []const u8) void {}
fn noopSetStatus(_: []const u8) void {}

test "host registers and activates builtin extension" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const TestExt = struct {
        var activated: bool = false;

        fn activate(ctx: *ActivationContext) !void {
            _ = ctx;
            activated = true;
        }

        fn execute(ctx: *ActivationContext, command_id: []const u8) !void {
            _ = ctx;
            try std.testing.expectEqualStrings("test.run", command_id);
        }
    };

    const cmd_table = [_]CommandEntry{
        .{ .id = "test.run", .title = "Run Test" },
    };

    const builtin = BuiltinExtension{
        .id = "forge.test",
        .name = "Test",
        .version = "0.0.1",
        .commands = &cmd_table,
        .activate = TestExt.activate,
        .executeCommand = TestExt.execute,
    };

    var host = Host.init(allocator, io);
    defer host.deinit();

    try host.registerBuiltin(&builtin);
    try host.activateAll();

    try std.testing.expect(TestExt.activated);
    try host.executeCommand("test.run");
}

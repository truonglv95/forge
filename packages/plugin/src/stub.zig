const std = @import("std");
const workspace = @import("forge-workspace");

pub const sdk = @import("sdk.zig");

pub const ApiVersion = struct { major: u32 = 0, minor: u32 = 0 };

pub const CommandEntry = struct {
    id: []const u8 = "",
    title: []const u8 = "",
};

pub const BuiltinExtension = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    commands: []const CommandEntry = &.{},
    activate: *const fn (ctx: *ActivationContext) anyerror!void = noopActivate,
    deactivate: ?*const fn (ctx: *ActivationContext) void = null,
    executeCommand: ?*const fn (ctx: *ActivationContext, command_id: []const u8) anyerror!void = null,
};

fn noopActivate(_: *ActivationContext) !void {}

pub const CommandRegistration = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    extension_id: []const u8 = "",
};

pub const LoadedExtension = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    root_path: []const u8 = "",
    builtin: ?*const BuiltinExtension = null,
    active: bool = false,
    commands: CommandList = .{},

    pub const CommandList = struct {
        items: []const CommandRegistration = &.{},
        pub fn append(self: *CommandList, allocator: std.mem.Allocator, item: CommandRegistration) !void {
            _ = self;
            _ = allocator;
            _ = item;
        }
        pub fn deinit(_: *CommandList, _: std.mem.Allocator) void {}
    };

    pub fn deinit(_: *LoadedExtension, _: std.mem.Allocator) void {}
};

pub const ThemeContribution = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    path: []const u8 = "",
    extension_id: []const u8 = "",
    extension_root: []const u8 = "",
};

pub const KeybindingContribution = struct {
    key: []const u8 = "",
    command: []const u8 = "",
    extension_id: []const u8 = "",
};

pub const LanguageContribution = struct {
    id: []const u8 = "",
    server: []const u8 = "",
    args: []const u8 = "",
    file_pattern: []const u8 = "",
    server_resolver: []const u8 = "",
    extension_id: []const u8 = "",
};

pub const Contributions = struct {
    themes: ThemeList = .{},
    keybindings: KeybindingList = .{},
    languages: LanguageList = .{},

    pub const ThemeList = struct {
        items: []const ThemeContribution = &.{},
        pub fn append(_: *ThemeList, _: std.mem.Allocator, _: ThemeContribution) !void {}
        pub fn deinit(_: *ThemeList, _: std.mem.Allocator) void {}
    };
    pub const KeybindingList = struct {
        items: []const KeybindingContribution = &.{},
        pub fn append(_: *KeybindingList, _: std.mem.Allocator, _: KeybindingContribution) !void {}
        pub fn deinit(_: *KeybindingList, _: std.mem.Allocator) void {}
    };
    pub const LanguageList = struct {
        items: []const LanguageContribution = &.{},
        pub fn append(_: *LanguageList, _: std.mem.Allocator, _: LanguageContribution) !void {}
        pub fn deinit(_: *LanguageList, _: std.mem.Allocator) void {}
    };

    pub fn findThemeByQualifiedId(_: *const Contributions, _: []const u8) ?ThemeContribution {
        return null;
    }
    pub fn deinit(_: *Contributions, _: std.mem.Allocator) void {}
};

pub const ActivationContext = struct {
    host: *Host = undefined,
    allocator: std.mem.Allocator = undefined,
    extension_id: []const u8 = "",

    pub fn registerCommand(_: *ActivationContext, _: []const u8, _: []const u8) !void {}
    pub fn registerTheme(_: *ActivationContext, _: []const u8, _: []const u8, _: []const u8) !void {}
    pub fn registerKeybinding(_: *ActivationContext, _: []const u8, _: []const u8) !void {}
    pub fn registerLanguage(_: *ActivationContext, _: LanguageRegistration) !void {}
};

pub const LanguageRegistration = struct {
    id: []const u8,
    server: []const u8,
    args: []const u8 = "",
    file_pattern: []const u8,
    server_resolver: []const u8 = "",
};

pub const Host = struct {
    contributions: Contributions = .{},
    extensions: ExtensionList = .{},

    pub const ExtensionList = struct {
        items: []const LoadedExtension = &.{},
        pub fn append(_: *ExtensionList, _: std.mem.Allocator, _: LoadedExtension) !void {}
        pub fn deinit(_: *ExtensionList, _: std.mem.Allocator) void {}
    };

    pub fn init(allocator: std.mem.Allocator, _: std.Io) Host {
        _ = allocator;
        return .{};
    }
    pub fn deinit(_: *Host) void {}
    pub fn registerBuiltin(_: *Host, _: *const BuiltinExtension) !void {}
    pub fn setHostCallbacks(_: *Host, _: WasmHostCallbacks) void {}
    pub fn discoverWorkspace(_: *Host, _: anytype) !void {}
    pub fn activateAll(_: *Host) !void {}
    pub fn activateExtension(_: *Host, _: []const u8) !void {}
    pub fn deactivateExtension(_: *Host, _: []const u8) !void {}
    pub fn executeCommand(_: *Host, _: []const u8) !void {}
    pub fn extensionCount(_: *const Host) usize {
        return 0;
    }
    pub fn activeExtensionCount(_: *const Host) usize {
        return 0;
    }
};

pub const WasmLimits = struct {
    max_memory_bytes: u32 = 1048576,
    max_lsp_request_bytes: u32 = 8192,
};

pub const WasmHostCallbacks = struct {
    log: *const fn (message: []const u8) void,
    set_status: *const fn (message: []const u8) void,
    lsp_language_for_file: ?*const fn (path: []const u8, out: []u8) ?usize = null,
    lsp_request: ?*const fn (language_id: []const u8, request_json: []const u8, response_out: []u8, limits: WasmLimits) ?usize = null,
    read_file: ?*const fn (path: []const u8, out: []u8) ?usize = null,
    search: ?*const fn (pattern: []const u8, out: []u8) ?usize = null,
    show_message: ?*const fn (message: []const u8) void = null,
    set_diagnostics: ?*const fn (path: []const u8, diagnostics_json: []const u8) void = null,
    execute_command: ?*const fn (command: []const u8) i32 = null,
};

pub const WasmRuntime = struct {
    pub fn init(_: anytype) !WasmRuntime {
        return error.PluginUnavailable;
    }
    pub fn deinit(_: *WasmRuntime) void {}
};

pub fn limitsFromManifest(_: anytype) WasmLimits {
    return .{};
}

pub const wasm_runtime = struct {
    pub const HostCallbacks = WasmHostCallbacks;
};

pub const MarketplaceEntry = struct {
    id: []const u8 = "",
    version: []const u8 = "",
    name: []const u8 = "",
    source: []const u8 = "",
    publisher: []const u8 = "",
    description: []const u8 = "",
};

pub const MarketplaceCatalog = struct {
    entries: []const MarketplaceEntry = &.{},
    pub fn deinit(_: *MarketplaceCatalog, _: anytype) void {}
};

pub const marketplace = struct {
    pub const CatalogEntry = MarketplaceEntry;
    pub const Catalog = MarketplaceCatalog;

    pub fn loadCatalog(_: anytype, _: anytype, _: anytype) !Catalog {
        return error.PluginUnavailable;
    }
    pub fn isInstalled(_: anytype, _: anytype, _: anytype, _: anytype) !bool {
        return false;
    }
    pub fn findEntry(_: *const Catalog, _: []const u8) ?CatalogEntry {
        return null;
    }
    pub fn install(_: anytype, _: anytype, _: anytype, _: CatalogEntry) ![]const u8 {
        return error.PluginUnavailable;
    }
    pub fn uninstall(_: anytype, _: anytype, _: anytype, _: []const u8) !void {
        return error.PluginUnavailable;
    }
};

pub const Manifest = struct {};
pub const vscode_shim = struct {};
pub const theme_contrib = struct {
    pub fn loadThemeOverrides(_: anytype, _: anytype, _: anytype, _: anytype) !workspace.ThemeOverrides {
        return error.PluginUnavailable;
    }
};
pub const manifest = struct {};
pub const host = struct {};
pub const contributions = struct {};

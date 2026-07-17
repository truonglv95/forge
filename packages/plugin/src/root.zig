//! Plugin compatibility contracts and extension host.

const std = @import("std");
const core = @import("forge-core");

pub const subsystem = core.Subsystem.plugin;

pub const ApiVersion = struct {
    major: u16,
    minor: u16,

    pub fn isCompatible(host_ver: ApiVersion, guest: ApiVersion) bool {
        return host_ver.major == guest.major and host_ver.minor >= guest.minor;
    }
};

pub const manifest = @import("manifest.zig");
pub const Manifest = manifest.Manifest;
pub const host = @import("host.zig");
pub const Host = host.Host;
pub const LoadedExtension = host.LoadedExtension;
pub const BuiltinExtension = host.BuiltinExtension;
pub const CommandEntry = host.CommandEntry;
pub const ActivationContext = host.ActivationContext;
pub const contributions = @import("contributions.zig");
pub const Contributions = contributions.Registry;
pub const marketplace = @import("marketplace.zig");
pub const MarketplaceCatalog = marketplace.Catalog;
pub const MarketplaceEntry = marketplace.CatalogEntry;
pub const vscode_shim = @import("vscode_shim.zig");
pub const wasm_runtime = @import("wasm_runtime.zig");
pub const WasmRuntime = wasm_runtime.WasmRuntime;
pub const wasi_sandbox = @import("wasi_sandbox.zig");
pub const WasiSandbox = wasi_sandbox.WasiSandbox;
pub const WasmHostCallbacks = wasm_runtime.HostCallbacks;
pub const WasmLimits = wasm_runtime.Limits;
pub const limitsFromManifest = wasm_runtime.limitsFromManifest;
pub const theme_contrib = @import("theme_contrib.zig");
pub const extension_settings = @import("extension_settings.zig");
pub const ExtensionSettings = extension_settings.Settings;
pub const hot_reload = @import("hot_reload.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(manifest);
    std.testing.refAllDecls(host);
    _ = @import("manifest_test.zig");
}

test "plugin API compatibility requires matching major versions" {
    const host_ver = ApiVersion{ .major = 1, .minor = 2 };
    try std.testing.expect(host_ver.isCompatible(.{ .major = 1, .minor = 1 }));
    try std.testing.expect(!host_ver.isCompatible(.{ .major = 2, .minor = 0 }));
}

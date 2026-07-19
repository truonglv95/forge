const std = @import("std");
const lsp = @import("forge-lsp");
const workspace = @import("forge-workspace");
const lsp_sync_mod = @import("lsp_sync.zig");
const diagnostics_store_mod = @import("diagnostics_store.zig");
const completion_store_mod = @import("completion_store.zig");
const hover_store_mod = @import("hover_store.zig");
const references_store_mod = @import("references_store.zig");
const rename_preview_mod = @import("rename_preview.zig");

pub const LspController = struct {
    allocator: std.mem.Allocator,
    registry: *lsp.Registry,
    proxy: *lsp.Proxy,
    sync: lsp_sync_mod.Store,
    diagnostics: diagnostics_store_mod.Store,
    completions: completion_store_mod.Store,
    hover: hover_store_mod.Store,
    references: references_store_mod.Store,
    rename_preview: rename_preview_mod.Store,

    // Outline state
    outline_symbols: []lsp.document_symbol.Symbol = &[_]lsp.document_symbol.Symbol{},
    outline_scroll_y: f32 = 0,
    outline_hover_index: ?usize = null,
    outline_refresh_cooldown: f32 = 0,
    outline_last_path: ?[]const u8 = null,
    outline_last_revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, workspace_root: workspace.WorkspaceRoot) !LspController {
        var self: LspController = undefined;
        self.allocator = allocator;
        self.registry = try allocator.create(lsp.Registry);
        self.registry.* = lsp.Registry.init(allocator);
        self.proxy = try allocator.create(lsp.Proxy);
        self.proxy.* = try lsp.Proxy.init(allocator, io, workspace_path);

        self.sync = lsp_sync_mod.Store.init(allocator, workspace_path, self.proxy, self.registry);
        self.diagnostics = diagnostics_store_mod.Store.init(allocator, io, workspace_path, workspace_root, self.proxy, self.registry);
        self.completions = completion_store_mod.Store.init(allocator, io, workspace_path, workspace_root, self.proxy, self.registry);
        self.hover = hover_store_mod.Store.init(allocator, workspace_path, self.proxy, self.registry);
        self.references = references_store_mod.Store.init(allocator);
        self.rename_preview = rename_preview_mod.Store.init(allocator);

        self.outline_symbols = &[_]lsp.document_symbol.Symbol{};
        self.outline_scroll_y = 0;
        self.outline_hover_index = null;
        self.outline_refresh_cooldown = 0;
        self.outline_last_path = null;
        self.outline_last_revision = 0;

        return self;
    }

    pub fn start(self: *LspController) !void {
        try self.proxy.start();
    }

    pub fn deinit(self: *LspController) void {
        for (self.outline_symbols) |*sym| sym.deinit(self.allocator);
        if (self.outline_symbols.len > 0) self.allocator.free(self.outline_symbols);

        self.rename_preview.deinit();
        self.references.deinit();
        self.hover.deinit();
        self.completions.deinit();
        self.diagnostics.deinit();
        self.sync.deinit();
        self.proxy.deinit();
        self.allocator.destroy(self.proxy);
        self.registry.deinit(self.allocator);
        self.allocator.destroy(self.registry);
    }
};

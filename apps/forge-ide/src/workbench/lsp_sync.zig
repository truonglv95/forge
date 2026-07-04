const std = @import("std");
const lsp = @import("forge-lsp");
const workspace = @import("forge-workspace");
const editor = @import("forge-editor");

pub const Store = struct {
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    proxy: *lsp.Proxy,
    registry: *lsp.Registry,
    entries: std.StringHashMap(Entry),
    pending: std.atomic.Value(bool) = .init(false),
    cooldown: f32 = 0,

    const Entry = struct {
        version: u32 = 0,
        opened: bool = false,
        last_hash: u64 = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        workspace_path: []const u8,
        proxy: *lsp.Proxy,
        registry: *lsp.Registry,
    ) Store {
        return .{
            .allocator = allocator,
            .workspace_path = workspace_path,
            .proxy = proxy,
            .registry = registry,
            .entries = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        self.entries.deinit();
    }

    pub fn resetEntries(self: *Store) void {
        self.entries.clearRetainingCapacity();
        self.pending.store(false, .release);
        self.cooldown = 0;
    }

    pub fn onDocumentClosed(self: *Store, path: []const u8) void {
        const owned = self.registry.copyMatchForPath(self.allocator, path) catch {
            _ = self.entries.remove(path);
            return;
        };
        const config = owned orelse {
            _ = self.entries.remove(path);
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

        const uri = lsp.diagnostics.fileUri(self.allocator, self.workspace_path, path) catch {
            _ = self.entries.remove(path);
            return;
        };
        defer self.allocator.free(uri);

        const msg = lsp.sync.buildDidCloseNotification(self.allocator, uri) catch {
            _ = self.entries.remove(path);
            return;
        };
        defer self.allocator.free(msg);

        var notify_buf: [4096]u8 = undefined;
        _ = self.proxy.request(config.language_id, msg, &notify_buf, notify_buf.len) catch {};
        _ = self.entries.remove(path);
    }

    pub fn tick(self: *Store, dt: f32, tabs: *editor.TabGroup) void {
        if (self.pending.load(.acquire)) return;
        self.cooldown -= dt;
        if (self.cooldown > 0) return;

        for (tabs.tabs.items) |*doc| {
            if (self.needsSync(doc)) {
                self.cooldown = 0.4;
                self.syncNow(doc);
                return;
            }
        }
    }

    pub fn ensureSyncedBlocking(self: *Store, doc: *editor.Document) ![]const u8 {
        const owned = try self.registry.copyMatchForPath(self.allocator, doc.path);
        const config = owned orelse return error.NoLanguageServer;
        defer lsp.Registry.freeConfig(self.allocator, config);

        const uri = try lsp.diagnostics.fileUri(self.allocator, self.workspace_path, doc.path);
        errdefer self.allocator.free(uri);

        const content = try doc.buffer.content();
        defer self.allocator.free(content);

        try self.pushSync(config.language_id, uri, content, doc.path);
        return uri;
    }

    fn needsSync(self: *Store, doc: *editor.Document) bool {
        const content = doc.buffer.content() catch return false;
        defer doc.buffer.allocator.free(content);
        const hash = workspace.edit.contentHash(content);

        const state = self.entries.get(doc.path);
        if (state == null) return true;
        if (!state.?.opened) return true;
        return hash != state.?.last_hash;
    }

    fn syncNow(self: *Store, doc: *editor.Document) void {
        const owned = self.registry.copyMatchForPath(self.allocator, doc.path) catch return;
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);

        const content = doc.buffer.content() catch return;
        defer doc.buffer.allocator.free(content);

        self.pending.store(true, .release);
        defer self.pending.store(false, .release);

        const uri = lsp.diagnostics.fileUri(self.allocator, self.workspace_path, doc.path) catch return;
        defer self.allocator.free(uri);

        self.pushSync(config.language_id, uri, content, doc.path) catch {};
    }

    fn pushSync(
        self: *Store,
        language_id: []const u8,
        uri: []const u8,
        content: []const u8,
        path: []const u8,
    ) !void {
        const hash = workspace.edit.contentHash(content);
        const gop = try self.entries.getOrPut(path);
        if (!gop.found_existing) gop.value_ptr.* = .{};

        const state = gop.value_ptr;
        var notify_buf: [65536]u8 = undefined;

        if (!state.opened) {
            state.version = 1;
            const msg = try lsp.sync.buildDidOpenNotification(
                self.allocator,
                uri,
                language_id,
                state.version,
                content,
            );
            defer self.allocator.free(msg);
            _ = self.proxy.request(language_id, msg, &notify_buf, notify_buf.len) catch {};
            state.opened = true;
        } else if (hash != state.last_hash) {
            state.version += 1;
            const msg = try lsp.sync.buildDidChangeNotification(
                self.allocator,
                uri,
                state.version,
                content,
            );
            defer self.allocator.free(msg);
            _ = self.proxy.request(language_id, msg, &notify_buf, notify_buf.len) catch {};
        }
        state.last_hash = hash;
    }
};

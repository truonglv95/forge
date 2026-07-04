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

    pub fn onDocumentClosed(self: *Store, path: []const u8) void {
        _ = self.entries.remove(path);
    }

    pub fn tick(self: *Store, dt: f32, tabs: *editor.TabGroup) void {
        if (self.pending.load(.acquire)) return;
        self.cooldown -= dt;
        if (self.cooldown > 0) return;

        for (tabs.tabs.items) |*doc| {
            if (self.needsSync(doc)) {
                self.cooldown = 0.4;
                self.syncAsync(doc);
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

        try self.pushSync(config.language_id, uri, content, doc.path, true);
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

    fn syncAsync(self: *Store, doc: *editor.Document) void {
        const owned = self.registry.copyMatchForPath(self.allocator, doc.path) catch return;
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);

        const content = doc.buffer.content() catch return;
        const ctx = self.allocator.create(SyncContext) catch {
            doc.buffer.allocator.free(content);
            return;
        };
        ctx.* = .{
            .store = self,
            .path = self.allocator.dupe(u8, doc.path) catch {
                doc.buffer.allocator.free(content);
                self.allocator.destroy(ctx);
                return;
            },
            .language_id = self.allocator.dupe(u8, config.language_id) catch {
                doc.buffer.allocator.free(content);
                self.allocator.free(ctx.path);
                self.allocator.destroy(ctx);
                return;
            },
            .content = content,
        };

        self.pending.store(true, .release);
        const thread = std.Thread.spawn(.{}, syncThread, .{ctx}) catch {
            ctx.deinit(self.allocator);
            self.pending.store(false, .release);
            return;
        };
        thread.detach();
    }

    fn pushSync(
        self: *Store,
        language_id: []const u8,
        uri: []const u8,
        content: []const u8,
        path: []const u8,
        blocking: bool,
    ) !void {
        const hash = workspace.edit.contentHash(content);
        const gop = try self.entries.getOrPut(path);
        if (!gop.foundExisting) gop.value_ptr.* = .{};

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
            if (blocking) {
                _ = self.proxy.request(language_id, msg, &notify_buf, notify_buf.len) catch {};
            } else {
                _ = self.proxy.request(language_id, msg, &notify_buf, notify_buf.len) catch {};
            }
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

const SyncContext = struct {
    store: *Store,
    path: []const u8,
    language_id: []const u8,
    content: []const u8,

    fn deinit(self: *SyncContext, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.language_id);
        allocator.free(self.content);
        allocator.destroy(self);
    }
};

fn syncThread(ctx: *SyncContext) void {
    defer ctx.store.pending.store(false, .release);
    const store = ctx.store;

    const uri = lsp.diagnostics.fileUri(store.allocator, store.workspace_path, ctx.path) catch {
        ctx.deinit(store.allocator);
        return;
    };
    defer store.allocator.free(uri);

    store.pushSync(ctx.language_id, uri, ctx.content, ctx.path, false) catch {};
    ctx.deinit(store.allocator);
}

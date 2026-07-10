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
    mutex: @import("forge-util").sync.Mutex = .{},

    const Entry = struct {
        version: u32 = 0,
        opened: bool = false,
        last_hash: u64 = 0,
        last_revision: u64 = 0,
        semantic_tokens: ?[]lsp.semantic_tokens.AbsoluteToken = null,

        pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            if (self.semantic_tokens) |st| allocator.free(st);
        }
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
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn resetEntries(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
        self.pending.store(false, .release);
        self.cooldown = 0;
    }

    pub fn onDocumentClosed(self: *Store, path: []const u8) void {
        const owned = self.registry.copyMatchForPath(self.allocator, path) catch {
            self.removeEntry(path);
            return;
        };
        const config = owned orelse {
            self.removeEntry(path);
            return;
        };
        defer lsp.Registry.freeConfig(self.allocator, config);

        const uri = lsp.diagnostics.fileUri(self.allocator, self.workspace_path, path) catch {
            self.removeEntry(path);
            return;
        };
        defer self.allocator.free(uri);

        const msg = lsp.sync.buildDidCloseNotification(self.allocator, uri) catch {
            self.removeEntry(path);
            return;
        };
        defer self.allocator.free(msg);

        var notify_buf: [4096]u8 = undefined;
        _ = self.proxy.request(config.language_id, msg, &notify_buf, notify_buf.len) catch {};
        self.removeEntry(path);
    }

    fn removeEntry(self: *Store, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(path)) |kv| {
            var entry = kv.value;
            entry.deinit(self.allocator);
        }
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

        try self.pushSync(config.language_id, uri, content, doc.path, doc.buffer.revision);
        return uri;
    }

    fn needsSync(self: *Store, doc: *editor.Document) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const state = self.entries.get(doc.path);
        if (state == null) return true;
        if (!state.?.opened) return true;
        return doc.buffer.revision != state.?.last_revision;
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

        self.pushSync(config.language_id, uri, content, doc.path, doc.buffer.revision) catch {};
    }

    fn pushSync(
        self: *Store,
        language_id: []const u8,
        uri: []const u8,
        content: []const u8,
        path: []const u8,
        revision: u64,
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
        state.last_revision = revision;
        const version_copy = state.version;
        self.mutex.unlock(); // Unlock before semantic tokens

        // Fetch Semantic Tokens async
        const req_id = @as(i32, @intCast(version_copy)) + 10000;
        const sem_msg = lsp.sync.buildSemanticTokensFullRequest(self.allocator, req_id, uri) catch null;
        if (sem_msg != null) {
            const path_copy = self.allocator.dupe(u8, path) catch return;
            const lang_copy = self.allocator.dupe(u8, language_id) catch {
                self.allocator.free(path_copy);
                return;
            };
            const FetchContext = struct {
                store: *Store,
                path: []const u8,
                language_id: []const u8,
                sem_msg: []const u8,
            };
            const ctx = FetchContext{
                .store = self,
                .path = path_copy,
                .language_id = lang_copy,
                .sem_msg = sem_msg.?,
            };

            const thread = std.Thread.spawn(.{}, fetchSemanticWorker, .{ctx}) catch {
                self.allocator.free(path_copy);
                self.allocator.free(lang_copy);
                self.allocator.free(sem_msg.?);
                return;
            };
            thread.detach();
        }
    }

    fn fetchSemanticWorker(ctx: anytype) void {
        const self = ctx.store;
        defer self.allocator.free(ctx.path);
        defer self.allocator.free(ctx.language_id);
        defer self.allocator.free(ctx.sem_msg);

        const response_buf = self.allocator.alloc(u8, 1024 * 1024) catch return;
        defer self.allocator.free(response_buf);

        const len = self.proxy.request(ctx.language_id, ctx.sem_msg, response_buf, response_buf.len) catch return;
        if (len == 0) return;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_buf[0..len], .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;
        const result = root.object.get("result") orelse return;
        if (result != .object) return;
        const data = result.object.get("data") orelse return;
        if (data != .array) return;

        const items = data.array.items;
        const token_count = items.len / 5;
        var data_arr = self.allocator.alloc(lsp.semantic_tokens.AbsoluteToken, token_count) catch return;

        var current_line: u32 = 0;
        var current_start: u32 = 0;
        var i: usize = 0;
        while (i < token_count) : (i += 1) {
            const delta_line: u32 = @intCast(items[i * 5].integer);
            const delta_start: u32 = @intCast(items[i * 5 + 1].integer);

            if (delta_line > 0) {
                current_line += delta_line;
                current_start = delta_start;
            } else {
                current_start += delta_start;
            }

            data_arr[i] = .{
                .line = current_line,
                .start = current_start,
                .length = @intCast(items[i * 5 + 2].integer),
                .token_type = @intCast(items[i * 5 + 3].integer),
                .modifiers = @intCast(items[i * 5 + 4].integer),
            };
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.getPtr(ctx.path)) |state| {
            if (state.semantic_tokens) |st| self.allocator.free(st);
            state.semantic_tokens = data_arr;
        } else {
            self.allocator.free(data_arr);
        }
    }
};

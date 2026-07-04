const std = @import("std");
const lsp = @import("forge-lsp");
const workspace = @import("forge-workspace");
const editor = @import("forge-editor");

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    workspace_root: workspace.WorkspaceRoot,
    proxy: *lsp.Proxy,
    registry: *lsp.Registry,
    list: lsp.completion.List = .{ .items = &.{} },
    pending: std.atomic.Value(bool) = .init(false),
    visible: bool = false,
    selected: usize = 0,
    request_generation: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        workspace_path: []const u8,
        workspace_root: workspace.WorkspaceRoot,
        proxy: *lsp.Proxy,
        registry: *lsp.Registry,
    ) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace_path = workspace_path,
            .workspace_root = workspace_root,
            .proxy = proxy,
            .registry = registry,
        };
    }

    pub fn deinit(self: *Store) void {
        self.clearList();
    }

    pub fn clearList(self: *Store) void {
        self.list.deinit(self.allocator);
        self.list = .{ .items = &.{} };
        self.visible = false;
        self.selected = 0;
    }

    pub fn dismiss(self: *Store) void {
        self.clearList();
    }

    pub fn requestForDocument(self: *Store, doc: *editor.Document) void {
        const owned = self.registry.copyMatchForPath(self.allocator, doc.path) catch return;
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);
        if (self.pending.load(.acquire)) return;

        self.request_generation += 1;
        const generation = self.request_generation;
        self.pending.store(true, .release);

        const ctx = self.allocator.create(FetchContext) catch {
            self.pending.store(false, .release);
            return;
        };
        ctx.* = .{
            .store = self,
            .generation = generation,
            .path = self.allocator.dupe(u8, doc.path) catch {
                self.allocator.destroy(ctx);
                self.pending.store(false, .release);
                return;
            },
            .language_id = self.allocator.dupe(u8, config.language_id) catch {
                self.allocator.free(ctx.path);
                self.allocator.destroy(ctx);
                self.pending.store(false, .release);
                return;
            },
            .line = @intCast(doc.buffer.cursor.row),
            .character = @intCast(doc.buffer.cursor.col),
            .content = doc.buffer.content() catch {
                self.allocator.free(ctx.path);
                self.allocator.free(ctx.language_id);
                self.allocator.destroy(ctx);
                self.pending.store(false, .release);
                return;
            },
        };

        const thread = std.Thread.spawn(.{}, fetchThread, .{ctx}) catch {
            ctx.deinit(self.allocator);
            self.pending.store(false, .release);
            return;
        };
        thread.detach();
    }

    pub fn moveSelection(self: *Store, delta: i32) void {
        if (!self.visible or self.list.items.len == 0) return;
        if (delta < 0) {
            if (self.selected > 0) self.selected -= 1;
        } else if (self.selected + 1 < self.list.items.len) {
            self.selected += 1;
        }
    }

    pub fn acceptSelected(self: *Store, doc: *editor.Document) !void {
        if (!self.visible or self.list.items.len == 0) return;
        if (self.selected >= self.list.items.len) return;
        const item = self.list.items[self.selected];
        try doc.buffer.insertString(item.label);
        self.dismiss();
    }
};

const FetchContext = struct {
    store: *Store,
    generation: u64,
    path: []const u8,
    language_id: []const u8,
    line: u32,
    character: u32,
    content: []const u8,

    fn deinit(self: *FetchContext, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.language_id);
        allocator.free(self.content);
        allocator.destroy(self);
    }
};

fn fetchThread(ctx: *FetchContext) void {
    defer ctx.store.pending.store(false, .release);
    const store = ctx.store;

    const uri = lsp.diagnostics.fileUri(store.allocator, store.workspace_path, ctx.path) catch {
        ctx.deinit(store.allocator);
        return;
    };
    defer store.allocator.free(uri);

    const wp = workspace.WorkspacePath.parse(ctx.path) catch {
        ctx.deinit(store.allocator);
        return;
    };
    _ = wp;
    const snap_content = ctx.content;

    const did_open = lsp.completion.buildDidOpenNotification(store.allocator, uri, ctx.language_id, snap_content) catch {
        ctx.deinit(store.allocator);
        return;
    };
    defer store.allocator.free(did_open);

    var notify_buf: [65536]u8 = undefined;
    _ = store.proxy.request(ctx.language_id, did_open, &notify_buf, 65536) catch {};

    const req = lsp.completion.buildCompletionRequest(store.allocator, 77, uri, ctx.line, ctx.character) catch {
        ctx.deinit(store.allocator);
        return;
    };
    defer store.allocator.free(req);

    var response_buf: [65536]u8 = undefined;
    const len = store.proxy.request(ctx.language_id, req, &response_buf, 65536) catch {
        ctx.deinit(store.allocator);
        return;
    };

    const list = lsp.completion.parseCompletionResponse(store.allocator, response_buf[0..len]) catch lsp.completion.List{ .items = &.{} };

    if (store.request_generation != ctx.generation) {
        var discard = list;
        discard.deinit(store.allocator);
        ctx.deinit(store.allocator);
        return;
    }

    store.clearList();
    store.list = list;
    store.visible = list.items.len > 0;
    store.selected = 0;
    ctx.deinit(store.allocator);
}

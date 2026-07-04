const std = @import("std");
const lsp = @import("forge-lsp");

pub const Store = struct {
    allocator: std.mem.Allocator,
    workspace_path: []const u8,
    proxy: *lsp.Proxy,
    registry: *lsp.Registry,
    text: ?[]const u8 = null,
    anchor_x: f32 = 0,
    anchor_y: f32 = 0,
    pending: std.atomic.Value(bool) = .init(false),
    cooldown: f32 = 0,
    last_line: u32 = std.math.maxInt(u32),
    last_col: u32 = std.math.maxInt(u32),
    last_path: ?[]const u8 = null,

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
        };
    }

    pub fn deinit(self: *Store) void {
        self.clearText();
        if (self.last_path) |path| self.allocator.free(path);
    }

    pub fn clear(self: *Store) void {
        self.clearText();
        self.last_line = std.math.maxInt(u32);
        self.last_col = std.math.maxInt(u32);
        if (self.last_path) |path| {
            self.allocator.free(path);
            self.last_path = null;
        }
    }

    fn clearText(self: *Store) void {
        if (self.text) |text| self.allocator.free(text);
        self.text = null;
    }

    pub fn tick(self: *Store, dt: f32) void {
        self.cooldown -= dt;
    }

    pub fn requestAt(
        self: *Store,
        doc_path: []const u8,
        line: u32,
        col: u32,
        anchor_x: f32,
        anchor_y: f32,
    ) void {
        if (self.pending.load(.acquire)) return;
        if (self.cooldown > 0) return;

        if (self.last_path) |path| {
            if (std.mem.eql(u8, path, doc_path) and self.last_line == line and self.last_col == col) return;
        }

        self.cooldown = 0.35;
        self.anchor_x = anchor_x;
        self.anchor_y = anchor_y;

        const owned = self.registry.copyMatchForPath(self.allocator, doc_path) catch return;
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);

        self.pending.store(true, .release);

        const ctx = self.allocator.create(FetchContext) catch {
            self.pending.store(false, .release);
            return;
        };
        ctx.* = .{
            .store = self,
            .path = self.allocator.dupe(u8, doc_path) catch {
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
            .line = line,
            .character = col,
            .anchor_x = anchor_x,
            .anchor_y = anchor_y,
        };

        const thread = std.Thread.spawn(.{}, fetchThread, .{ctx}) catch {
            ctx.deinit(self.allocator);
            self.pending.store(false, .release);
            return;
        };
        thread.detach();
    }
};

const FetchContext = struct {
    store: *Store,
    path: []const u8,
    language_id: []const u8,
    line: u32,
    character: u32,
    anchor_x: f32,
    anchor_y: f32,

    fn deinit(self: *FetchContext, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.language_id);
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

    const hover_req = lsp.hover.buildHoverRequest(store.allocator, 91, uri, ctx.line, ctx.character) catch {
        ctx.deinit(store.allocator);
        return;
    };
    defer store.allocator.free(hover_req);

    var response_buf: [65536]u8 = undefined;
    const len = store.proxy.request(ctx.language_id, hover_req, &response_buf, response_buf.len) catch {
        ctx.deinit(store.allocator);
        return;
    };

    const parsed = lsp.hover.parseHoverResponse(store.allocator, response_buf[0..len]) catch null;

    store.clearText();
    store.text = parsed;
    store.anchor_x = ctx.anchor_x;
    store.anchor_y = ctx.anchor_y;
    store.last_line = ctx.line;
    store.last_col = ctx.character;
    if (store.last_path) |old| store.allocator.free(old);
    store.last_path = store.allocator.dupe(u8, ctx.path) catch null;

    ctx.deinit(store.allocator);
}

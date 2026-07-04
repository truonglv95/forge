const std = @import("std");
const lsp = @import("forge-lsp");
const workspace = @import("forge-workspace");

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    workspace_root: workspace.WorkspaceRoot,
    proxy: *lsp.Proxy,
    registry: *lsp.Registry,
    active_path: ?[]const u8 = null,
    list: lsp.diagnostics.List = .{ .items = &.{} },
    pending: std.atomic.Value(bool) = .init(false),
    cooldown: f32 = 0,

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
        if (self.active_path) |path| self.allocator.free(path);
        self.clearList();
    }

    pub fn clearList(self: *Store) void {
        self.list.deinit(self.allocator);
        self.list = .{ .items = &.{} };
    }

    pub fn setActivePath(self: *Store, path: ?[]const u8) !void {
        if (self.active_path) |existing| {
            if (path != null and std.mem.eql(u8, existing, path.?)) return;
            self.allocator.free(existing);
        }
        self.active_path = if (path) |p| try self.allocator.dupe(u8, p) else null;
        self.cooldown = 0;
    }

    pub fn tick(self: *Store, dt: f32, doc: ?*@import("forge-editor").Document) void {
        if (doc == null) return;
        if (self.pending.load(.acquire)) return;
        self.cooldown -= dt;
        if (self.cooldown > 0) return;
        self.cooldown = 1.5;
        self.requestAsync(doc.?);
    }

    fn requestAsync(self: *Store, doc: *@import("forge-editor").Document) void {
        const owned = self.registry.copyMatchForPath(self.allocator, doc.path) catch return;
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);

        self.pending.store(true, .release);

        const content = doc.buffer.content() catch {
            self.pending.store(false, .release);
            return;
        };

        const ctx = self.allocator.create(FetchContext) catch {
            self.allocator.free(content);
            self.pending.store(false, .release);
            return;
        };
        ctx.* = .{
            .store = self,
            .path = self.allocator.dupe(u8, doc.path) catch {
                self.allocator.free(content);
                self.allocator.destroy(ctx);
                self.pending.store(false, .release);
                return;
            },
            .language_id = self.allocator.dupe(u8, config.language_id) catch {
                self.allocator.free(content);
                self.allocator.free(ctx.path);
                self.allocator.destroy(ctx);
                self.pending.store(false, .release);
                return;
            },
            .content = content,
        };

        const thread = std.Thread.spawn(.{}, fetchThread, .{ctx}) catch {
            ctx.deinit(self.allocator);
            self.pending.store(false, .release);
            return;
        };
        thread.detach();
    }

    fn applyResult(self: *Store, path: []const u8, list: lsp.diagnostics.List) void {
        if (self.active_path == null or !std.mem.eql(u8, self.active_path.?, path)) {
            var discard = list;
            discard.deinit(self.allocator);
            return;
        }
        self.clearList();
        self.list = list;
    }
};

const FetchContext = struct {
    store: *Store,
    path: []const u8,
    language_id: []const u8,
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

    const did_open = lsp.diagnostics.buildDidOpenNotification(store.allocator, uri, ctx.language_id, ctx.content) catch {
        ctx.deinit(store.allocator);
        return;
    };
    defer store.allocator.free(did_open);

    var notify_buf: [65536]u8 = undefined;
    _ = store.proxy.request(ctx.language_id, did_open, &notify_buf, 65536) catch {};

    const diag_req = lsp.diagnostics.buildDiagnosticRequest(store.allocator, 42, uri) catch {
        ctx.deinit(store.allocator);
        return;
    };
    defer store.allocator.free(diag_req);

    var response_buf: [65536]u8 = undefined;
    const len = store.proxy.request(ctx.language_id, diag_req, &response_buf, 65536) catch {
        ctx.deinit(store.allocator);
        return;
    };

    const list = lsp.diagnostics.parseDiagnosticResponse(store.allocator, response_buf[0..len]) catch lsp.diagnostics.List{ .items = &.{} };
    store.applyResult(ctx.path, list);
    ctx.deinit(store.allocator);
}

pub fn countForLine(list: lsp.diagnostics.List, line_index: usize) usize {
    var count: usize = 0;
    for (list.items) |item| {
        if (item.line == line_index) count += 1;
    }
    return count;
}

pub fn worstSeverityOnLine(list: lsp.diagnostics.List, line_index: usize) ?lsp.diagnostics.Severity {
    var found: ?lsp.diagnostics.Severity = null;
    for (list.items) |item| {
        if (item.line != line_index) continue;
        if (found == null or @intFromEnum(item.severity) < @intFromEnum(found.?)) {
            found = item.severity;
        }
    }
    return found;
}

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
    mutex: @import("forge-util").sync.Mutex = .{},

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
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_path) |path| self.allocator.free(path);
        self.clearListUnlocked();
    }

    pub fn clearList(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearListUnlocked();
    }

    fn clearListUnlocked(self: *Store) void {
        self.list.deinit(self.allocator);
        self.list = .{ .items = &.{} };
    }

    pub fn setActivePath(self: *Store, path: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_path) |existing| {
            if (path != null and std.mem.eql(u8, existing, path.?)) return;
            self.allocator.free(existing);
        }
        self.active_path = if (path) |p| try self.allocator.dupe(u8, p) else null;
        self.cooldown = 0;
    }

    pub fn tick(self: *Store, dt: f32, doc: ?*@import("forge-editor").Document, agent_busy: bool) void {
        if (doc == null or agent_busy) return;
        if (self.pending.load(.acquire)) return;
        self.cooldown -= dt;
        if (self.cooldown > 0) return;
        self.cooldown = 1.5;
        self.requestAsync(doc.?);
    }

    fn requestAsync(self: *Store, doc: *@import("forge-editor").Document) void {
        self.pending.store(true, .release);
        const path = self.allocator.dupe(u8, doc.path) catch {
            self.pending.store(false, .release);
            return;
        };
        const thread = std.Thread.spawn(.{}, fetchWorker, .{ self, path }) catch {
            self.allocator.free(path);
            self.pending.store(false, .release);
            return;
        };
        thread.detach();
    }

    fn fetchWorker(self: *Store, path: []const u8) void {
        defer self.pending.store(false, .release);
        defer self.allocator.free(path);

        const owned = self.registry.copyMatchForPath(self.allocator, path) catch return;
        const config = owned orelse return;
        defer lsp.Registry.freeConfig(self.allocator, config);

        const uri = lsp.diagnostics.fileUri(self.allocator, self.workspace_path, path) catch return;
        defer self.allocator.free(uri);

        const diag_req = lsp.diagnostics.buildDiagnosticRequest(self.allocator, 42, uri) catch return;
        defer self.allocator.free(diag_req);

        const response_buf = self.allocator.alloc(u8, 1024 * 1024) catch return;
        defer self.allocator.free(response_buf);

        const len = self.proxy.request(config.language_id, diag_req, response_buf, response_buf.len) catch return;

        const list = lsp.diagnostics.parseDiagnosticResponse(self.allocator, response_buf[0..len]) catch lsp.diagnostics.List{ .items = &.{} };
        self.applyResult(path, list);
    }

    fn applyResult(self: *Store, path: []const u8, list: lsp.diagnostics.List) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_path == null or !std.mem.eql(u8, self.active_path.?, path)) {
            var discard = list;
            discard.deinit(self.allocator);
            return;
        }
        self.clearListUnlocked();

        // Sort diagnostics by line then character for binary search later
        std.sort.pdq(lsp.diagnostics.Diagnostic, list.items, {}, struct {
            pub fn less(_: void, a: lsp.diagnostics.Diagnostic, b: lsp.diagnostics.Diagnostic) bool {
                if (a.line != b.line) return a.line < b.line;
                return a.character < b.character;
            }
        }.less);

        self.list = list;
    }
};

const LineLookupCache = struct {
    items_ptr: usize = 0,
    len: usize = 0,
    line: usize = 0,
    index: usize = 0,
};

var line_lookup_cache: LineLookupCache = .{};

fn findFirstForLine(items: []lsp.diagnostics.Diagnostic, line_index: usize) usize {
    var l: usize = 0;
    var r: usize = items.len;
    while (l < r) {
        const m = l + (r - l) / 2;
        if (items[m].line < line_index) {
            l = m + 1;
        } else {
            r = m;
        }
    }
    return l;
}

fn findFirstForLineCached(items: []lsp.diagnostics.Diagnostic, line_index: usize) usize {
    if (items.len == 0) return 0;

    const ptr = @intFromPtr(items.ptr);
    if (line_lookup_cache.items_ptr == ptr and
        line_lookup_cache.len == items.len and
        line_lookup_cache.index <= items.len and
        line_index >= line_lookup_cache.line)
    {
        var i = line_lookup_cache.index;
        while (i < items.len and items[i].line < line_index) : (i += 1) {}
        line_lookup_cache = .{ .items_ptr = ptr, .len = items.len, .line = line_index, .index = i };
        return i;
    }

    const i = findFirstForLine(items, line_index);
    line_lookup_cache = .{ .items_ptr = ptr, .len = items.len, .line = line_index, .index = i };
    return i;
}

pub fn countForLine(list: lsp.diagnostics.List, line_index: usize) usize {
    const start_idx = findFirstForLineCached(list.items, line_index);
    var count: usize = 0;
    for (list.items[start_idx..]) |item| {
        if (item.line != line_index) break;
        count += 1;
    }
    return count;
}

pub fn worstSeverityOnLine(list: lsp.diagnostics.List, line_index: usize) ?lsp.diagnostics.Severity {
    const start_idx = findFirstForLineCached(list.items, line_index);
    var found: ?lsp.diagnostics.Severity = null;
    for (list.items[start_idx..]) |item| {
        if (item.line != line_index) break;
        if (found == null or @intFromEnum(item.severity) < @intFromEnum(found.?)) {
            found = item.severity;
        }
    }
    return found;
}

pub fn firstForLine(list: lsp.diagnostics.List, line_index: usize) usize {
    return findFirstForLineCached(list.items, line_index);
}

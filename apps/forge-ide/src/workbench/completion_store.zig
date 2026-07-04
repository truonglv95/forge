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
        defer self.pending.store(false, .release);

        const content = doc.buffer.content() catch return;
        defer self.allocator.free(content);

        self.fetchCompletions(
            doc.path,
            config.language_id,
            @intCast(doc.buffer.cursor.row),
            @intCast(doc.buffer.cursor.col),
            generation,
        );
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

    fn fetchCompletions(
        self: *Store,
        path: []const u8,
        language_id: []const u8,
        line: u32,
        character: u32,
        generation: u64,
    ) void {
        const uri = lsp.diagnostics.fileUri(self.allocator, self.workspace_path, path) catch return;
        defer self.allocator.free(uri);

        const req = lsp.completion.buildCompletionRequest(self.allocator, 77, uri, line, character) catch return;
        defer self.allocator.free(req);

        var response_buf: [65536]u8 = undefined;
        const len = self.proxy.request(language_id, req, &response_buf, 65536) catch return;

        const list = lsp.completion.parseCompletionResponse(self.allocator, response_buf[0..len]) catch lsp.completion.List{ .items = &.{} };

        if (self.request_generation != generation) {
            var discard = list;
            discard.deinit(self.allocator);
            return;
        }

        self.clearList();
        self.list = list;
        self.visible = list.items.len > 0;
        self.selected = 0;
    }
};

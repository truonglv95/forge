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
        defer self.pending.store(false, .release);

        self.fetchHover(doc_path, config.language_id, line, col, anchor_x, anchor_y);
    }

    fn fetchHover(
        self: *Store,
        doc_path: []const u8,
        language_id: []const u8,
        line: u32,
        col: u32,
        anchor_x: f32,
        anchor_y: f32,
    ) void {
        const uri = lsp.diagnostics.fileUri(self.allocator, self.workspace_path, doc_path) catch return;
        defer self.allocator.free(uri);

        const hover_req = lsp.hover.buildHoverRequest(self.allocator, 91, uri, line, col) catch return;
        defer self.allocator.free(hover_req);

        var response_buf: [65536]u8 = undefined;
        const len = self.proxy.request(language_id, hover_req, &response_buf, response_buf.len) catch return;

        const parsed = lsp.hover.parseHoverResponse(self.allocator, response_buf[0..len]) catch null;

        self.clearText();
        self.text = parsed;
        self.anchor_x = anchor_x;
        self.anchor_y = anchor_y;
        self.last_line = line;
        self.last_col = col;
        if (self.last_path) |old| self.allocator.free(old);
        self.last_path = self.allocator.dupe(u8, doc_path) catch null;
    }
};

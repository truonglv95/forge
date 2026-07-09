const std = @import("std");
const lsp = @import("forge-lsp");

pub const Entry = struct {
    name: []const u8,
    kind: lsp.workspace_symbol.SymbolKind,
    location: lsp.navigation.Location,
    container_name: ?[]const u8,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.container_name) |c| allocator.free(c);
        allocator.free(self.location.uri);
    }
};

pub const Picker = struct {
    allocator: std.mem.Allocator,
    query: []u8,
    query_len: usize,
    open: bool = false,
    selected: usize = 0,
    entries: std.ArrayList(Entry),
    proxy: *lsp.Proxy,
    cooldown: f32 = 0,
    request_pending: std.atomic.Value(bool) = .init(false),

    // We keep a secondary list to hold results from a background thread
    // then swap them in on the main thread
    background_results: ?std.ArrayList(Entry) = null,
    background_ready: std.atomic.Value(bool) = .init(false),
    background_mtx: @import("forge-util").sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, proxy: *lsp.Proxy) !Picker {
        return .{
            .allocator = allocator,
            .query = try allocator.alloc(u8, 256),
            .query_len = 0,
            .entries = .empty,
            .proxy = proxy,
        };
    }

    pub fn deinit(self: *Picker) void {
        self.clearEntries();
        self.entries.deinit(self.allocator);
        if (self.background_results) |*res| {
            for (res.items) |*entry| {
                entry.deinit(self.allocator);
            }
            res.deinit(self.allocator);
        }
        self.allocator.free(self.query);
    }

    pub fn clearEntries(self: *Picker) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn openPicker(self: *Picker) !void {
        self.open = true;
        self.query_len = 0;
        self.selected = 0;
        self.clearEntries();
        self.cooldown = 0;
        self.triggerSearch();
    }

    pub fn close(self: *Picker) void {
        self.open = false;
        self.query_len = 0;
    }

    pub fn insertChar(self: *Picker, chars: []const u8) !void {
        for (chars) |c| {
            if (self.query_len < self.query.len) {
                self.query[self.query_len] = c;
                self.query_len += 1;
            }
        }
        self.selected = 0;
        self.cooldown = 0.2; // Debounce requests
    }

    pub fn backspace(self: *Picker) !void {
        if (self.query_len > 0) {
            self.query_len -= 1;
            self.selected = 0;
            self.cooldown = 0.2;
        }
    }

    pub fn moveSelection(self: *Picker, delta: i32) void {
        if (self.entries.items.len == 0) return;
        const total = @as(i32, @intCast(self.entries.items.len));
        var next = @as(i32, @intCast(self.selected)) + delta;
        if (next < 0) next = total - 1;
        if (next >= total) next = 0;
        self.selected = @intCast(next);
    }

    pub fn tick(self: *Picker, dt: f32) void {
        if (!self.open) return;

        if (self.background_ready.load(.acquire)) {
            self.background_mtx.lock();
            if (self.background_results) |res| {
                self.clearEntries();
                self.entries = res;
                self.background_results = null;
            }
            self.background_ready.store(false, .release);
            self.background_mtx.unlock();

            // Re-clamp selected
            if (self.entries.items.len > 0 and self.selected >= self.entries.items.len) {
                self.selected = self.entries.items.len - 1;
            } else if (self.entries.items.len == 0) {
                self.selected = 0;
            }
        }

        if (self.cooldown > 0) {
            self.cooldown -= dt;
            if (self.cooldown <= 0) {
                self.triggerSearch();
            }
        }
    }

    fn triggerSearch(self: *Picker) void {
        if (self.request_pending.load(.acquire)) return;
        self.request_pending.store(true, .release);

        const query_str = self.allocator.dupe(u8, self.query[0..self.query_len]) catch {
            self.request_pending.store(false, .release);
            return;
        };

        const thread = std.Thread.spawn(.{}, searchWorker, .{ self, query_str }) catch {
            self.allocator.free(query_str);
            self.request_pending.store(false, .release);
            return;
        };
        thread.detach();
    }

    fn searchWorker(picker: *Picker, query_str: []const u8) void {
        defer {
            picker.allocator.free(query_str);
            picker.request_pending.store(false, .release);
        }

        var results: std.ArrayList(Entry) = .empty;

        // Let's broadcast this request to all languages
        // For simplicity, we just send it to one language in a real app,
        // but here we can send it to "zig", "rust", "go", etc?
        // Wait, proxy.request needs a language_id.
        // We will just send it to all active language servers?
        // For now, let's just assume we query the first one, or "zig" if hardcoded.
        // Wait, the Proxy has a list of active servers, or we can just send it to all of them.
        // Actually, we can fetch all servers from Proxy? Proxy doesn't expose it.
        // Let's just pass `zig` as a placeholder, or maybe we can iterate.
        // A better way is to add `requestAll` to proxy, but let's just query `zig` for now to get it working, then improve.
        const req_id = 9999;
        const req = lsp.sync.buildWorkspaceSymbolRequest(picker.allocator, req_id, query_str) catch return;
        defer picker.allocator.free(req);

        var response_buf: [2 * 1024 * 1024]u8 = undefined;
        // In a real app we need to track what languages are active. For now we use "zig".
        const len = picker.proxy.request("zig", req, &response_buf, response_buf.len) catch 0;
        if (len > 0) {
            var parsed = std.json.parseFromSlice(std.json.Value, picker.allocator, response_buf[0..len], .{}) catch null;
            if (parsed != null) {
                defer parsed.?.deinit();
                const root = parsed.?.value;
                if (root == .object) {
                    if (root.object.get("result")) |result| {
                        if (result == .array) {
                            for (result.array.items) |item| {
                                if (item == .object) {
                                    const name = item.object.get("name").?.string;
                                    const kind_int = @as(u32, @intCast(item.object.get("kind").?.integer));
                                    const container = if (item.object.get("containerName")) |c| c.string else null;
                                    const loc = item.object.get("location").?.object;
                                    const uri = loc.get("uri").?.string;
                                    const range = loc.get("range").?.object;
                                    const start = range.get("start").?.object;
                                    const start_line = @as(u32, @intCast(start.get("line").?.integer));
                                    const start_char = @as(u32, @intCast(start.get("character").?.integer));

                                    results.append(picker.allocator, .{
                                        .name = picker.allocator.dupe(u8, name) catch continue,
                                        .kind = @enumFromInt(kind_int),
                                        .container_name = if (container) |c| picker.allocator.dupe(u8, c) catch null else null,
                                        .location = .{
                                            .uri = picker.allocator.dupe(u8, uri) catch continue,
                                            .line = start_line,
                                            .character = start_char,
                                        },
                                    }) catch continue;
                                }
                            }
                        }
                    }
                }
            }
        }

        picker.background_mtx.lock();
        if (picker.background_results) |*old_res| {
            for (old_res.items) |*entry| {
                entry.deinit(picker.allocator);
            }
            old_res.deinit(picker.allocator);
        }
        picker.background_results = results;
        picker.background_ready.store(true, .release);
        picker.background_mtx.unlock();
    }
};

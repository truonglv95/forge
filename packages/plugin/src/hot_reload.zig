const std = @import("std");

/// Extension hot-reload support.
///
/// Watches the extensions directory for changes to forge.toml files.
/// When a manifest is added, modified, or removed, the watch fires
/// a callback that lets the host reload extensions.
///
/// Implementation: uses a polling approach (check file mtimes every
/// `poll_interval_ms`). This is portable across macOS/Linux/Windows
/// without requiring platform-specific file-watcher APIs (inotify,
/// FSEvents, ReadDirectoryChangesW).

pub const WatchEvent = enum {
    manifest_added,
    manifest_changed,
    manifest_removed,
};

pub const WatchCallback = *const fn (context: ?*anyopaque, event: WatchEvent, extension_id: []const u8) void;

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    extensions_dir: []const u8,
    poll_interval_ms: u64,
    callback: WatchCallback,
    callback_context: ?*anyopaque,
    /// Known manifests: extension_id → last_known_mtime_ms.
    known: std.StringHashMap(i64),
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        extensions_dir: []const u8,
        callback: WatchCallback,
        callback_context: ?*anyopaque,
    ) !Watcher {
        return .{
            .allocator = allocator,
            .io = io,
            .extensions_dir = try allocator.dupe(u8, extensions_dir),
            .poll_interval_ms = 2000,
            .callback = callback,
            .callback_context = callback_context,
            .known = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        var it = self.known.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.known.deinit();
        self.allocator.free(self.extensions_dir);
    }

    /// Start watching in a background thread.
    pub fn start(self: *Watcher) !void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, watchLoop, .{self});
    }

    /// Stop watching and join the thread.
    pub fn stop(self: *Watcher) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn watchLoop(self: *Watcher) void {
        // Initial scan.
        self.scan() catch {};

        while (self.running.load(.acquire)) {
            // Sleep for poll interval.
            const ts = std.c.timespec{
                .tv_sec = @intCast(self.poll_interval_ms / 1000),
                .tv_nsec = @intCast((self.poll_interval_ms % 1000) * 1_000_000),
            };
            _ = std.c.nanosleep(&ts, null);

            if (!self.running.load(.acquire)) break;
            self.scan() catch {};
        }
    }

    fn scan(self: *Watcher) !void {
        // Open extensions directory and iterate.
        var dir = std.Io.Dir.openDirAbsolute(self.io, self.extensions_dir, .{
            .iterate = true,
            .access_sub_paths = true,
        }) catch return;

        defer dir.close(self.io);

        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            seen.deinit();
        }

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            // Check for forge.toml in the extension directory.
            var ext_dir = dir.openDir(self.io, entry.name, .{}) catch continue;
            defer ext_dir.close(self.io);

            const stat = ext_dir.statFile(self.io, "forge.toml", .{}) catch continue;
            const mtime_ms: i64 = @intCast(stat.mtime.toMilliseconds());

            const id_owned = try self.allocator.dupe(u8, entry.name);
            try seen.put(id_owned, {});

            if (self.known.get(entry.name)) |old_mtime| {
                if (old_mtime != mtime_ms) {
                    // Changed.
                    self.callback(self.callback_context, .manifest_changed, entry.name);
                    try self.known.put(entry.name, mtime_ms);
                }
            } else {
                // New.
                self.callback(self.callback_context, .manifest_added, entry.name);
                const key_owned = try self.allocator.dupe(u8, entry.name);
                try self.known.put(key_owned, mtime_ms);
            }
        }

        // Check for removed extensions.
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);
        var known_it = self.known.iterator();
        while (known_it.next()) |entry| {
            if (!seen.contains(entry.key_ptr.*)) {
                self.callback(self.callback_context, .manifest_removed, entry.key_ptr.*);
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |key| {
            if (self.known.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
        }
    }
};

test "Watcher init/deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var watcher = try Watcher.init(allocator, io, "/tmp/test-ext", struct {
        fn cb(_: ?*anyopaque, _: WatchEvent, _: []const u8) void {}
    }.cb, null);
    defer watcher.deinit();
    try std.testing.expect(!watcher.running.load(.acquire));
}

const std = @import("std");

const pthread = @cImport({
    @cInclude("pthread.h");
});

/// Thread-safe mutex for background workers that must not use std.Io.Mutex.
pub const Mutex = struct {
    inner: pthread.pthread_mutex_t = undefined,
    initialized: bool = false,

    pub fn init(self: *Mutex) void {
        if (self.initialized) return;
        _ = pthread.pthread_mutex_init(&self.inner, null);
        self.initialized = true;
    }

    pub fn deinit(self: *Mutex) void {
        if (!self.initialized) return;
        _ = pthread.pthread_mutex_destroy(&self.inner);
        self.initialized = false;
    }

    pub fn lock(self: *Mutex) void {
        self.init();
        _ = pthread.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = pthread.pthread_mutex_unlock(&self.inner);
    }
};

test "mutex serializes counter updates" {
    const Counter = struct {
        value: usize = 0,
        mutex: Mutex = .{},

        fn inc(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value += 1;
        }
    };

    var counter = Counter{};
    const ctx = &counter;
    const threads = try std.testing.allocator.alloc(std.Thread, 8);
    defer std.testing.allocator.free(threads);

    for (threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn worker(target: *Counter) void {
                var i: usize = 0;
                while (i < 100) : (i += 1) target.inc();
            }
        }.worker, .{ctx});
    }
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 800), counter.value);
    counter.mutex.deinit();
}

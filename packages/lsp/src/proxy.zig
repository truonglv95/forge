const std = @import("std");
const registry = @import("registry.zig");
const session_mod = @import("session.zig");

const c = @cImport({
    @cInclude("pthread.h");
});

const PthreadMutex = struct {
    inner: c.pthread_mutex_t = undefined,

    fn init(self: *PthreadMutex) void {
        _ = c.pthread_mutex_init(&self.inner, null);
    }

    fn deinit(self: *PthreadMutex) void {
        _ = c.pthread_mutex_destroy(&self.inner);
    }

    fn lock(self: *PthreadMutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    fn unlock(self: *PthreadMutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

const PthreadCond = struct {
    inner: c.pthread_cond_t = undefined,

    fn init(self: *PthreadCond) void {
        _ = c.pthread_cond_init(&self.inner, null);
    }

    fn deinit(self: *PthreadCond) void {
        _ = c.pthread_cond_destroy(&self.inner);
    }

    fn signal(self: *PthreadCond) void {
        _ = c.pthread_cond_signal(&self.inner);
    }

    fn wait(self: *PthreadCond, mutex: *PthreadMutex) void {
        _ = c.pthread_cond_wait(&self.inner, &mutex.inner);
    }
};

pub const ProxyError = error{
    LanguageNotConfigured,
    RequestTooLarge,
    SessionFailed,
    OutOfMemory,
    ProxyStopped,
};

const JobKind = enum {
    request,
    sync_registry,
    warm,
    shutdown,
};

const Job = struct {
    kind: JobKind,
    language_id: []const u8 = "",
    request_json: []const u8 = "",
    response_out: []u8 = &.{},
    max_request_bytes: usize = 0,
    registry_snapshot: []registry.ServerConfig = &.{},
    server: []const u8 = "",
    args: []const u8 = "",
    file_pattern: []const u8 = "",
    extension_id: []const u8 = "",
    done_mutex: PthreadMutex = .{},
    done_cond: PthreadCond = .{},
    sync_ready: bool = false,
    done_flag: bool = false,
    wait: bool = true,
    result: union(enum) {
        none,
        ok: usize,
        err: ProxyError,
    } = .none,

    fn initSync(self: *Job) void {
        if (self.sync_ready) return;
        self.done_mutex.init();
        self.done_cond.init();
        self.sync_ready = true;
    }

    fn deinitSync(self: *Job) void {
        if (!self.sync_ready) return;
        self.done_cond.deinit();
        self.done_mutex.deinit();
        self.sync_ready = false;
    }

    fn waitDone(self: *Job) void {
        self.done_mutex.lock();
        defer self.done_mutex.unlock();
        while (!self.done_flag) self.done_cond.wait(&self.done_mutex);
    }

    fn signalDone(self: *Job) void {
        self.done_mutex.lock();
        self.done_flag = true;
        self.done_cond.signal();
        self.done_mutex.unlock();
    }

    fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        self.deinitSync();
        if (self.language_id.len > 0) allocator.free(self.language_id);
        if (self.request_json.len > 0) allocator.free(self.request_json);
        if (self.server.len > 0) allocator.free(self.server);
        if (self.args.len > 0) allocator.free(self.args);
        if (self.file_pattern.len > 0) allocator.free(self.file_pattern);
        if (self.extension_id.len > 0) allocator.free(self.extension_id);
        for (self.registry_snapshot) |entry| {
            allocator.free(entry.language_id);
            allocator.free(entry.server);
            allocator.free(entry.args);
            allocator.free(entry.file_pattern);
            allocator.free(entry.extension_id);
        }
        if (self.registry_snapshot.len > 0) allocator.free(self.registry_snapshot);
        allocator.destroy(self);
    }
};

const WorkerState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    registry: registry.Registry,
    sessions: std.StringHashMap(*session_mod.Session),
};

pub const Proxy = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    worker: std.Thread,
    worker_started: bool = false,
    shutdown: std.atomic.Value(bool) = .init(false),
    queue_mutex: PthreadMutex = .{},
    queue_ready: PthreadCond = .{},
    queue: std.ArrayList(*Job),
    state: *WorkerState,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8) !Proxy {
        const owned_path = try allocator.dupe(u8, workspace_path);
        errdefer allocator.free(owned_path);

        const state = try allocator.create(WorkerState);
        state.* = .{
            .allocator = allocator,
            .io = io,
            .workspace_path = owned_path,
            .registry = registry.Registry.init(allocator),
            .sessions = std.StringHashMap(*session_mod.Session).init(allocator),
        };
        errdefer {
            state.sessions.deinit();
            state.registry.deinit(allocator);
            allocator.free(state.workspace_path);
            allocator.destroy(state);
        }

        var proxy = Proxy{
            .allocator = allocator,
            .io = io,
            .worker = undefined,
            .queue = .empty,
            .state = state,
        };
        proxy.queue_mutex.init();
        proxy.queue_ready.init();

        return proxy;
    }

    pub fn start(self: *Proxy) !void {
        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
        self.worker_started = true;
    }

    pub fn deinit(self: *Proxy) void {
        if (!self.worker_started) {
            self.finishDeinit();
            return;
        }
        self.shutdown.store(true, .release);
        const job = self.allocator.create(Job) catch {
            self.worker.join();
            self.finishDeinit();
            return;
        };
        job.* = .{ .kind = .shutdown, .wait = false };
        self.enqueue(job) catch {
            job.deinit(self.allocator);
            self.worker.join();
            self.finishDeinit();
            return;
        };
        self.worker.join();
        self.finishDeinit();
    }

    fn finishDeinit(self: *Proxy) void {
        self.queue_ready.deinit();
        self.queue_mutex.deinit();
        self.queue.deinit(self.allocator);
        var it = self.state.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.io);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.state.sessions.deinit();
        self.state.registry.deinit(self.allocator);
        self.allocator.free(self.state.workspace_path);
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn syncRegistry(self: *Proxy, source: *registry.Registry) !void {
        const job = try self.allocator.create(Job);

        job.* = .{
            .kind = .sync_registry,
            .registry_snapshot = try cloneRegistryEntries(self.allocator, source),
            .wait = true,
        };

        _ = try self.runJob(job);
    }

    pub fn request(
        self: *Proxy,
        language_id: []const u8,
        request_json: []const u8,
        response_out: []u8,
        max_request_bytes: usize,
    ) ProxyError!usize {
        if (request_json.len > max_request_bytes) return error.RequestTooLarge;

        const job = self.allocator.create(Job) catch return error.OutOfMemory;

        job.* = .{
            .kind = .request,
            .language_id = try self.allocator.dupe(u8, language_id),
            .request_json = try self.allocator.dupe(u8, request_json),
            .response_out = response_out,
            .max_request_bytes = max_request_bytes,
            .wait = true,
        };

        return self.runJob(job);
    }

    pub fn warmLanguage(self: *Proxy, config: registry.ServerConfig) void {
        if (self.shutdown.load(.acquire)) return;

        const job = self.allocator.create(Job) catch return;
        job.* = .{
            .kind = .warm,
            .language_id = self.allocator.dupe(u8, config.language_id) catch {
                job.deinit(self.allocator);
                return;
            },
            .server = self.allocator.dupe(u8, config.server) catch {
                job.deinit(self.allocator);
                return;
            },
            .args = self.allocator.dupe(u8, config.args) catch {
                job.deinit(self.allocator);
                return;
            },
            .file_pattern = self.allocator.dupe(u8, config.file_pattern) catch {
                job.deinit(self.allocator);
                return;
            },
            .extension_id = self.allocator.dupe(u8, config.extension_id) catch {
                job.deinit(self.allocator);
                return;
            },
            .wait = false,
        };

        self.enqueue(job) catch {
            job.deinit(self.allocator);
        };
    }

    fn runJob(self: *Proxy, job: *Job) ProxyError!usize {
        self.enqueue(job) catch |err| {
            job.deinit(self.allocator);
            return err;
        };
        if (!job.wait) return 0;

        job.waitDone();
        defer job.deinit(self.allocator);

        return switch (job.result) {
            .ok => |len| len,
            .err => |proxy_err| proxy_err,
            .none => error.SessionFailed,
        };
    }

    fn enqueue(self: *Proxy, job: *Job) ProxyError!void {
        if (self.shutdown.load(.acquire)) return error.ProxyStopped;

        job.initSync();
        errdefer job.deinitSync();

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        try self.queue.append(self.allocator, job);
        self.queue_ready.signal();
    }

    fn workerMain(proxy: *Proxy) void {
        while (true) {
            const job = proxy.popJob() orelse break;
            proxy.handleJob(job);
        }
    }

    fn popJob(self: *Proxy) ?*Job {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        while (self.queue.items.len == 0) {
            if (self.shutdown.load(.acquire)) return null;
            self.queue_ready.wait(&self.queue_mutex);
            if (self.shutdown.load(.acquire) and self.queue.items.len == 0) return null;
        }

        return self.queue.pop();
    }

    fn handleJob(self: *Proxy, job: *Job) void {
        switch (job.kind) {
            .request => {
                if (self.handleRequest(job)) |len| {
                    job.result = .{ .ok = len };
                } else |err| {
                    job.result = .{ .err = err };
                }
            },
            .sync_registry => {
                self.applyRegistrySnapshot(job.registry_snapshot);
                for (job.registry_snapshot) |entry| {
                    self.allocator.free(entry.language_id);
                    self.allocator.free(entry.server);
                    self.allocator.free(entry.args);
                    self.allocator.free(entry.file_pattern);
                    self.allocator.free(entry.extension_id);
                }
                self.allocator.free(job.registry_snapshot);
                job.registry_snapshot = &.{};
                job.result = .{ .ok = 0 };
            },
            .warm => {
                const config = registry.ServerConfig{
                    .language_id = job.language_id,
                    .server = job.server,
                    .args = job.args,
                    .file_pattern = job.file_pattern,
                    .extension_id = job.extension_id,
                    .state = .configured,
                };
                _ = ensureSession(self.state, config) catch {};
                job.result = .{ .ok = 0 };
            },
            .shutdown => {
                job.result = .{ .ok = 0 };
            },
        }

        if (job.wait) {
            job.signalDone();
        } else {
            job.deinit(self.allocator);
        }
    }

    fn handleRequest(self: *Proxy, job: *Job) ProxyError!usize {
        if (job.request_json.len > job.max_request_bytes) return error.RequestTooLarge;
        const config = self.state.registry.findByLanguageId(job.language_id) orelse return error.LanguageNotConfigured;
        const session = try ensureSession(self.state, config);
        return session.sendRawRequest(job.request_json, job.response_out) catch error.SessionFailed;
    }

    fn applyRegistrySnapshot(self: *Proxy, snapshot: []registry.ServerConfig) void {
        var it = self.state.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.io);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.state.sessions.clearRetainingCapacity();
        self.state.registry.clear(self.allocator);
        for (snapshot) |item| {
            self.state.registry.add(self.allocator, item) catch {};
        }
    }

    fn ensureSession(state: *WorkerState, config: registry.ServerConfig) ProxyError!*session_mod.Session {
        if (state.sessions.get(config.language_id)) |existing| return existing;

        const owned = state.allocator.create(session_mod.Session) catch return error.OutOfMemory;
        owned.* = session_mod.Session.start(state.allocator, state.io, config, state.workspace_path) catch {
            state.allocator.destroy(owned);
            return error.SessionFailed;
        };

        const key = state.allocator.dupe(u8, config.language_id) catch {
            owned.deinit(state.io);
            state.allocator.destroy(owned);
            return error.OutOfMemory;
        };
        errdefer state.allocator.free(key);
        state.sessions.put(key, owned) catch {
            state.allocator.free(key);
            owned.deinit(state.io);
            state.allocator.destroy(owned);
            return error.OutOfMemory;
        };
        return owned;
    }
};

fn cloneRegistryEntries(allocator: std.mem.Allocator, source: *registry.Registry) ![]registry.ServerConfig {
    source.mutex.lock();
    defer source.mutex.unlock();

    var out = try allocator.alloc(registry.ServerConfig, source.servers.items.len);
    errdefer allocator.free(out);

    for (source.servers.items, 0..) |item, i| {
        out[i] = .{
            .language_id = try allocator.dupe(u8, item.language_id),
            .server = try allocator.dupe(u8, item.server),
            .args = try allocator.dupe(u8, item.args),
            .file_pattern = try allocator.dupe(u8, item.file_pattern),
            .extension_id = try allocator.dupe(u8, item.extension_id),
            .state = item.state,
        };
    }
    return out;
}

test "async proxy starts and stops cleanly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var proxy = try Proxy.init(allocator, io, ".");
    defer proxy.deinit();
    try proxy.start();
}

test "request cleans up job on language-not-configured" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var proxy = try Proxy.init(allocator, io, ".");
    defer proxy.deinit();
    try proxy.start();

    var response: [128]u8 = undefined;
    const result = proxy.request("zig", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", &response, response.len);
    try std.testing.expectError(error.LanguageNotConfigured, result);
}

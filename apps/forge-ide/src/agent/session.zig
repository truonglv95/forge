const std = @import("std");
const forge_util = @import("forge-util");

pub const Mode = enum { ask, plan };

pub const Phase = enum {
    idle,
    building_context,
    sending,
    streaming,
    parsing,
    proposal_ready,
    reviewing,
    applying,
    done,
    failed,
    cancelled,
};

pub const RunEntry = struct {
    run_id: []const u8,
    state: []const u8,
    timestamp_ms: i64,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: forge_util.sync.Mutex = .{},
    mode: Mode = .ask,
    phase: Phase = .idle,
    run_id: ?[]const u8 = null,
    proposal_rel: ?[]const u8 = null,
    intent: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    status_line: []const u8 = "",
    context_lines: std.ArrayList([]const u8),
    diff_lines: std.ArrayList([]const u8),
    run_history: std.ArrayList(RunEntry),
    scope_files: std.ArrayList([]const u8),
    scope_picker_open: bool = false,
    scope_query: [256]u8 = undefined,
    scope_query_len: usize = 0,
    scope_picker_selected: usize = 0,
    selected_run_index: usize = 0,
    show_review: bool = false,
    review_scroll_y: f32 = 0,
    worker_running: bool = false,
    last_transaction_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Session {
        return .{
            .allocator = allocator,
            .io = io,
            .context_lines = .empty,
            .diff_lines = .empty,
            .run_history = .empty,
            .scope_files = .empty,
        };
    }

    pub fn lock(self: *Session) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *Session) void {
        self.mutex.unlock();
    }

    pub fn deinit(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.clearProposalStateUnlocked();
        self.freeLinesUnlocked(&self.context_lines);
        self.freeLinesUnlocked(&self.diff_lines);
        self.context_lines.deinit(self.allocator);
        self.diff_lines.deinit(self.allocator);
        for (self.run_history.items) |entry| {
            self.allocator.free(entry.run_id);
            self.allocator.free(entry.state);
        }
        self.run_history.deinit(self.allocator);
        for (self.scope_files.items) |path| self.allocator.free(path);
        self.scope_files.deinit(self.allocator);
        if (self.status_line.len > 0) self.allocator.free(self.status_line);
        self.mutex.deinit();
    }

    pub fn addScopeFile(self: *Session, path: []const u8) !void {
        self.lock();
        defer self.unlock();
        for (self.scope_files.items) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
        }
        try self.scope_files.append(self.allocator, try self.allocator.dupe(u8, path));
    }

    pub fn removeScopeFile(self: *Session, path: []const u8) void {
        self.lock();
        defer self.unlock();
        var index: usize = 0;
        while (index < self.scope_files.items.len) {
            if (std.mem.eql(u8, self.scope_files.items[index], path)) {
                self.allocator.free(self.scope_files.items[index]);
                _ = self.scope_files.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn clearScope(self: *Session) void {
        self.lock();
        defer self.unlock();
        for (self.scope_files.items) |path| self.allocator.free(path);
        self.scope_files.clearRetainingCapacity();
    }

    pub fn effectiveScope(self: *Session, active_file: ?[]const u8) []const []const u8 {
        self.lock();
        defer self.unlock();
        if (self.scope_files.items.len > 0) return self.scope_files.items;
        if (active_file) |path| return &[_][]const u8{path};
        return &[_][]const u8{};
    }

    pub fn openScopePicker(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.scope_picker_open = true;
        self.scope_query_len = 0;
        self.scope_picker_selected = 0;
    }

    pub fn closeScopePicker(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.scope_picker_open = false;
        self.scope_query_len = 0;
    }

    fn freeLinesUnlocked(self: *Session, list: *std.ArrayList([]const u8)) void {
        for (list.items) |line| self.allocator.free(line);
        list.clearRetainingCapacity();
    }

    fn clearProposalStateUnlocked(self: *Session) void {
        if (self.run_id) |id| self.allocator.free(id);
        if (self.proposal_rel) |path| self.allocator.free(path);
        if (self.intent) |text| self.allocator.free(text);
        if (self.summary) |text| self.allocator.free(text);
        self.run_id = null;
        self.proposal_rel = null;
        self.intent = null;
        self.summary = null;
        self.show_review = false;
        self.review_scroll_y = 0;
        self.last_transaction_id = null;
        self.freeLinesUnlocked(&self.diff_lines);
    }

    pub fn resetForNewRun(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.clearProposalStateUnlocked();
        self.freeLinesUnlocked(&self.context_lines);
        self.phase = .idle;
        self.worker_running = false;
    }

    pub fn setPhase(self: *Session, phase: Phase, status: []const u8) !void {
        const owned = try self.allocator.dupe(u8, status);
        self.lock();
        defer self.unlock();
        if (self.status_line.len > 0) self.allocator.free(self.status_line);
        self.phase = phase;
        self.status_line = owned;
    }

    pub fn snapshot(self: *Session) struct {
        mode: Mode,
        phase: Phase,
        status_line: []const u8,
        show_review: bool,
        worker_running: bool,
        summary: ?[]const u8,
        run_count: usize,
        selected_run_index: usize,
        scope_count: usize,
        scope_picker_open: bool,
    } {
        self.lock();
        defer self.unlock();
        return .{
            .mode = self.mode,
            .phase = self.phase,
            .status_line = self.status_line,
            .show_review = self.show_review,
            .worker_running = self.worker_running,
            .summary = self.summary,
            .run_count = self.run_history.items.len,
            .selected_run_index = self.selected_run_index,
            .scope_count = self.scope_files.items.len,
            .scope_picker_open = self.scope_picker_open,
        };
    }
};

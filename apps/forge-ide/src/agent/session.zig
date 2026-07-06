const std = @import("std");
const forge_util = @import("forge-util");
const review_store = @import("review_store.zig");

pub const Mode = enum { ask, plan, agent };

pub const AttachmentKind = enum { text_snippet, image };

pub const Attachment = struct {
    kind: AttachmentKind,
    label: []const u8,
    stored_path: ?[]const u8 = null,
    text_preview: ?[]const u8 = null,
};

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

pub const ContextEntryStatus = enum {
    included,
    truncated,
    rejected,
};

pub const ContextEntry = struct {
    kind: []const u8,
    name: []const u8,
    status: ContextEntryStatus,
    bytes: usize,
    reason: ?[]const u8 = null,
};

pub const AgentStep = struct {
    index: u32,
    kind: []const u8,
    summary: []const u8,
    expanded: bool = false,
    parent_index: ?usize = null,
    child_count: usize = 0,
    is_thought: bool = false,
    content: ?[]const u8 = null,
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
    provider_label: []const u8 = "",
    context_lines: std.ArrayList([]const u8),
    context_entries: std.ArrayList(ContextEntry),
    context_used_bytes: usize = 0,
    context_max_bytes: usize = 1024 * 1024,
    context_inspector_expanded: bool = true,
    diff_lines: std.ArrayList([]const u8),
    review: review_store.Store = .{},
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
    stream_text: std.ArrayList(u8) = .empty,
    thinking_text: std.ArrayList(u8) = .empty,
    stream_live: bool = false,
    last_transaction_id: ?u64 = null,
    last_checkpoint_id: ?u64 = null,
    spec_run_id: ?[]const u8 = null,
    spec_pending: bool = false,
    proposal_only_run_id: ?[]const u8 = null,
    run_active_file: ?[]const u8 = null,
    agent_steps: std.ArrayList(AgentStep),
    attachments: std.ArrayList(Attachment),
    mode_menu_open: bool = false,
    model_menu_open: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Session {
        return .{
            .allocator = allocator,
            .io = io,
            .context_lines = .empty,
            .context_entries = .empty,
            .diff_lines = .empty,
            .run_history = .empty,
            .scope_files = .empty,
            .agent_steps = .empty,
            .attachments = .empty,
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
        self.clearContextEntriesUnlocked();
        self.context_entries.deinit(self.allocator);
        self.freeLinesUnlocked(&self.diff_lines);
        self.context_lines.deinit(self.allocator);
        self.diff_lines.deinit(self.allocator);
        self.stream_text.deinit(self.allocator);
        self.thinking_text.deinit(self.allocator);
        for (self.run_history.items) |entry| {
            self.allocator.free(entry.run_id);
            self.allocator.free(entry.state);
        }
        self.run_history.deinit(self.allocator);
        for (self.scope_files.items) |path| self.allocator.free(path);
        self.scope_files.deinit(self.allocator);
        self.clearAttachmentsUnlocked();
        self.attachments.deinit(self.allocator);
        self.clearAgentStepsUnlocked();
        self.agent_steps.deinit(self.allocator);
        if (self.status_line.len > 0) self.allocator.free(self.status_line);
        if (self.provider_label.len > 0) self.allocator.free(self.provider_label);
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
        _ = active_file;
        self.lock();
        defer self.unlock();
        return self.scope_files.items;
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

    fn clearAgentStepsUnlocked(self: *Session) void {
        for (self.agent_steps.items) |step| {
            self.allocator.free(step.kind);
            self.allocator.free(step.summary);
            if (step.content) |c| self.allocator.free(c);
        }
        self.agent_steps.clearRetainingCapacity();
    }

    pub fn appendAgentStep(self: *Session, index: u32, kind: []const u8, summary: []const u8) !void {
        self.lock();

        // Convert accumulated thinking text to a step
        if (self.thinking_text.items.len > 0) {
            const thought_content = try self.allocator.dupe(u8, self.thinking_text.items);
            const parent_kind = try self.allocator.dupe(u8, "thought");
            try self.agent_steps.append(self.allocator, .{
                .index = index, // or some other counter
                .kind = parent_kind,
                .summary = try self.allocator.dupe(u8, ""),
                .content = thought_content,
                .is_thought = true,
                .child_count = 0,
            });
            self.thinking_text.clearRetainingCapacity();
        }

        self.unlock();

        const owned_kind = try self.allocator.dupe(u8, kind);
        errdefer self.allocator.free(owned_kind);
        const owned_summary = try self.allocator.dupe(u8, summary);
        errdefer self.allocator.free(owned_summary);

        self.lock();
        defer self.unlock();

        var parent_idx: ?usize = null;
        if (self.agent_steps.items.len > 0) {
            var i = self.agent_steps.items.len;
            while (i > 0) : (i -= 1) {
                const step = &self.agent_steps.items[i - 1];
                if (step.parent_index == null and !step.is_thought) {
                    if (std.mem.eql(u8, step.kind, kind)) {
                        parent_idx = i - 1;
                    }
                    break;
                }
            }
        }

        if (parent_idx) |p_idx| {
            // Add as child to existing parent
            const p_step = &self.agent_steps.items[p_idx];
            p_step.child_count += 1;
            try self.agent_steps.append(self.allocator, .{
                .index = index,
                .kind = owned_kind,
                .summary = owned_summary,
                .parent_index = p_idx,
            });
        } else {
            // Create a new parent step
            const new_p_idx = self.agent_steps.items.len;
            const parent_kind = try self.allocator.dupe(u8, kind);
            try self.agent_steps.append(self.allocator, .{
                .index = index,
                .kind = parent_kind,
                .summary = try self.allocator.dupe(u8, ""),
                .child_count = 1,
            });
            // And add the actual step as its child
            try self.agent_steps.append(self.allocator, .{
                .index = index,
                .kind = owned_kind,
                .summary = owned_summary,
                .parent_index = new_p_idx,
            });
        }
    }

    fn clearAttachmentsUnlocked(self: *Session) void {
        for (self.attachments.items) |attachment| {
            self.allocator.free(attachment.label);
            if (attachment.stored_path) |path| self.allocator.free(path);
            if (attachment.text_preview) |text| self.allocator.free(text);
        }
        self.attachments.clearRetainingCapacity();
    }

    pub fn closeMenus(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.mode_menu_open = false;
        self.model_menu_open = false;
    }

    pub fn toggleModeMenu(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.mode_menu_open = !self.mode_menu_open;
        self.model_menu_open = false;
    }

    pub fn toggleModelMenu(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.model_menu_open = !self.model_menu_open;
        self.mode_menu_open = false;
    }

    pub fn addAttachment(self: *Session, attachment: Attachment) !void {
        self.lock();
        defer self.unlock();
        try self.attachments.append(self.allocator, attachment);
    }

    pub fn removeAttachment(self: *Session, index: usize) void {
        self.lock();
        defer self.unlock();
        if (index >= self.attachments.items.len) return;
        const attachment = self.attachments.items[index];
        self.allocator.free(attachment.label);
        if (attachment.stored_path) |path| self.allocator.free(path);
        if (attachment.text_preview) |text| self.allocator.free(text);
        _ = self.attachments.orderedRemove(index);
    }

    fn clearContextEntriesUnlocked(self: *Session) void {
        for (self.context_entries.items) |entry| {
            self.allocator.free(entry.kind);
            self.allocator.free(entry.name);
            if (entry.reason) |reason| self.allocator.free(reason);
        }
        self.context_entries.clearRetainingCapacity();
        self.context_used_bytes = 0;
    }

    pub fn replaceContextManifest(
        self: *Session,
        used_bytes: usize,
        max_bytes: usize,
        entries: std.ArrayList(ContextEntry),
    ) void {
        self.lock();
        defer self.unlock();
        self.clearContextEntriesUnlocked();
        self.context_used_bytes = used_bytes;
        self.context_max_bytes = max_bytes;
        self.context_entries = entries;
    }

    pub fn toggleContextInspector(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.context_inspector_expanded = !self.context_inspector_expanded;
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
        if (self.run_active_file) |path| self.allocator.free(path);
        self.run_active_file = null;
        self.show_review = false;
        self.review_scroll_y = 0;
        self.last_transaction_id = null;
        self.stream_text.clearRetainingCapacity();
        self.thinking_text.clearRetainingCapacity();
        self.stream_live = false;
        self.clearAgentStepsUnlocked();
        self.freeLinesUnlocked(&self.diff_lines);
        self.review.clear(self.allocator);
    }

    pub fn clearStreamText(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.stream_text.clearRetainingCapacity();
        self.thinking_text.clearRetainingCapacity();
        self.stream_live = false;
    }

    pub fn appendStreamChunk(self: *Session, chunk: []const u8) !void {
        if (chunk.len == 0) return;
        self.lock();
        defer self.unlock();
        const cap: usize = 64 * 1024;
        if (self.stream_text.items.len + chunk.len > cap) return;
        try self.stream_text.appendSlice(self.allocator, chunk);
    }

    pub fn appendThinkingChunk(self: *Session, chunk: []const u8) !void {
        if (chunk.len == 0) return;
        self.lock();
        defer self.unlock();
        const cap: usize = 64 * 1024;
        if (self.thinking_text.items.len + chunk.len > cap) return;
        try self.thinking_text.appendSlice(self.allocator, chunk);
    }

    pub fn resetForNewRun(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.clearProposalStateUnlocked();
        self.freeLinesUnlocked(&self.context_lines);
        self.clearContextEntriesUnlocked();
        self.phase = .idle;
        self.worker_running = false;
        if (self.provider_label.len > 0) {
            self.allocator.free(self.provider_label);
            self.provider_label = "";
        }
    }

    pub fn setProviderLabel(self: *Session, label: []const u8) !void {
        const owned = try self.allocator.dupe(u8, label);
        self.lock();
        defer self.unlock();
        if (self.provider_label.len > 0) self.allocator.free(self.provider_label);
        self.provider_label = owned;
    }

    pub fn setPhase(self: *Session, phase: Phase, status: []const u8) !void {
        const owned = try self.allocator.dupe(u8, status);
        self.lock();
        defer self.unlock();
        if (self.status_line.len > 0) self.allocator.free(self.status_line);
        self.phase = phase;
        self.status_line = owned;
    }

    pub fn snapshot(
        self: *Session,
        status_out: []u8,
        provider_out: []u8,
    ) struct {
        mode: Mode,
        phase: Phase,
        status_line: []const u8,
        provider_label: []const u8,
        show_review: bool,
        worker_running: bool,
        stream_len: usize,
        thinking_len: usize,
        summary: ?[]const u8,
        run_count: usize,
        selected_run_index: usize,
        scope_count: usize,
        scope_picker_open: bool,
        attachment_count: usize,
        context_entry_count: usize,
        context_used_bytes: usize,
        context_max_bytes: usize,
        context_inspector_expanded: bool,
        spec_pending: bool,
        last_checkpoint_id: ?u64,
    } {
        self.lock();
        defer self.unlock();
        const status_len = @min(self.status_line.len, if (status_out.len > 0) status_out.len - 1 else 0);
        if (status_len > 0) @memcpy(status_out[0..status_len], self.status_line[0..status_len]);
        if (status_out.len > 0) status_out[status_len] = 0;
        const provider_len = @min(self.provider_label.len, if (provider_out.len > 0) provider_out.len - 1 else 0);
        if (provider_len > 0) @memcpy(provider_out[0..provider_len], self.provider_label[0..provider_len]);
        if (provider_out.len > 0) provider_out[provider_len] = 0;
        return .{
            .mode = self.mode,
            .phase = self.phase,
            .status_line = status_out[0..status_len],
            .provider_label = provider_out[0..provider_len],
            .show_review = self.show_review,
            .worker_running = self.worker_running,
            .stream_len = self.stream_text.items.len,
            .thinking_len = self.thinking_text.items.len,
            .summary = self.summary,
            .run_count = self.run_history.items.len,
            .selected_run_index = self.selected_run_index,
            .scope_count = self.scope_files.items.len,
            .scope_picker_open = self.scope_picker_open,
            .attachment_count = self.attachments.items.len,
            .context_entry_count = self.context_entries.items.len,
            .context_used_bytes = self.context_used_bytes,
            .context_max_bytes = self.context_max_bytes,
            .context_inspector_expanded = self.context_inspector_expanded,
            .spec_pending = self.spec_pending,
            .last_checkpoint_id = self.last_checkpoint_id,
        };
    }
};

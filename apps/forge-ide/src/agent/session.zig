const std = @import("std");
const forge_util = @import("forge-util");
const kernel = @import("forge-kernel");
const workspace = @import("forge-workspace");
const review_store = @import("review_store.zig");
const ai = @import("forge-ai");
const core = @import("forge-core");
const telemetry = core.telemetry;

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
    waiting_approval,
    proposal_ready,
    reviewing,
    applying,
    verifying,
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

pub const ValidationResult = struct {
    task: []const u8,
    exit_code: i32,
    output: []const u8,
    skipped: bool = false,
};

pub const ApprovalDecision = enum { none, pending, approved, rejected };

pub const ResumeOfferKind = enum { continue_run, review_proposal };

pub const AgentStep = struct {
    index: u32,
    kind: []const u8,
    summary: []const u8,
    expanded: bool = false,
    parent_index: ?usize = null,
    child_count: usize = 0,
    is_thought: bool = false,
    content: ?[]const u8 = null,
    running: bool = false,
};

pub fn shouldAutoExpandStep(kind: []const u8, content: ?[]const u8) bool {
    if (content == null) return false;
    return std.mem.eql(u8, kind, "propose") or
        std.mem.eql(u8, kind, "write") or
        std.mem.eql(u8, kind, "edit");
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: forge_util.sync.Mutex = .{},
    mode: Mode = .agent,
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
    context_max_bytes: usize = 8 * 1024 * 1024,
    context_inspector_expanded: bool = true,
    context_inspector_scroll_y: f32 = 0,
    context_selected_index: ?usize = null,
    validation_results: std.ArrayList(ValidationResult),
    post_apply_visible: bool = false,
    diff_lines: std.ArrayList([]const u8),
    review: review_store.Store = .{},
    ephemeral_proposal: ?workspace.OwnedProposal = null,
    run_history: std.ArrayList(RunEntry),
    scope_files: std.ArrayList([]const u8),
    excluded_entries: std.ArrayList([]const u8),
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
    generation_start_ts: ?i64 = null,
    first_token_ts: ?i64 = null,
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
    approval_condition: forge_util.sync.Condition = .{},
    approval_decision: ApprovalDecision = .none,
    approval_tool: ?[]const u8 = null,
    approval_args: ?[]const u8 = null,
    approval_risk: ?[]const u8 = null,

    context_cache: ai.context_cache.ContextCache,
    approval_kind: ?ai.tool_registry.Approval = null,
    resume_offer_visible: bool = false,
    resume_offer_kind: ResumeOfferKind = .continue_run,
    resume_session_id: ?[]const u8 = null,
    resume_intent: ?[]const u8 = null,
    resume_state: ?[]const u8 = null,
    resume_proposal_path: ?[]const u8 = null,

    routing_task_intent: []const u8 = "",
    routing_profile: []const u8 = "",
    routing_tools: []const u8 = "",

    max_steps: u32 = 16,
    always_approve_tools: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Session {
        return .{
            .allocator = allocator,
            .io = io,
            .context_lines = .empty,
            .context_entries = .empty,
            .validation_results = .empty,
            .diff_lines = .empty,
            .run_history = .empty,
            .scope_files = .empty,
            .excluded_entries = .empty,
            .agent_steps = .empty,
            .attachments = .empty,
            .context_cache = ai.context_cache.ContextCache.init(allocator),
        };
    }

    pub fn lock(self: *Session) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *Session) void {
        self.mutex.unlock();
    }

    pub fn deinit(self: *Session) void {
        self.context_cache.deinit();
        self.lock();
        self.clearProposalStateUnlocked();
        self.freeLinesUnlocked(&self.context_lines);
        self.clearContextEntriesUnlocked();
        self.clearValidationResultsUnlocked();
        self.context_entries.deinit(self.allocator);
        self.validation_results.deinit(self.allocator);
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
        for (self.excluded_entries.items) |name| self.allocator.free(name);
        self.excluded_entries.deinit(self.allocator);
        self.clearAttachmentsUnlocked();
        self.attachments.deinit(self.allocator);
        if (self.approval_tool) |text| self.allocator.free(text);
        if (self.approval_args) |text| self.allocator.free(text);
        if (self.approval_risk) |text| self.allocator.free(text);
        if (self.resume_session_id) |text| self.allocator.free(text);
        if (self.resume_intent) |text| self.allocator.free(text);
        if (self.resume_state) |text| self.allocator.free(text);
        if (self.resume_proposal_path) |text| self.allocator.free(text);
        self.clearAgentStepsUnlocked();
        self.agent_steps.deinit(self.allocator);
        if (self.status_line.len > 0) self.allocator.free(self.status_line);
        if (self.provider_label.len > 0) self.allocator.free(self.provider_label);
        self.clearRoutingPreviewUnlocked();
        self.unlock();
        self.approval_condition.deinit();
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

    pub fn addExcludedEntry(self: *Session, name: []const u8) !void {
        self.lock();
        defer self.unlock();
        for (self.excluded_entries.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        try self.excluded_entries.append(self.allocator, try self.allocator.dupe(u8, name));
    }

    pub fn removeExcludedEntry(self: *Session, name: []const u8) void {
        self.lock();
        defer self.unlock();
        var index: usize = 0;
        while (index < self.excluded_entries.items.len) {
            if (std.mem.eql(u8, self.excluded_entries.items[index], name)) {
                self.allocator.free(self.excluded_entries.items[index]);
                _ = self.excluded_entries.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn isExcluded(self: *Session, name: []const u8) bool {
        self.lock();
        defer self.unlock();
        for (self.excluded_entries.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
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

    pub fn clearAgentSteps(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.clearAgentStepsUnlocked();
    }

    pub fn beginAgentStep(self: *Session, index: u32, kind: []const u8, label: []const u8, content: ?[]const u8) !void {
        const owned_kind = try self.allocator.dupe(u8, kind);
        errdefer self.allocator.free(owned_kind);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        var owned_content: ?[]const u8 = null;
        if (content) |c| {
            owned_content = try self.allocator.dupe(u8, c);
        }
        errdefer if (owned_content) |c| self.allocator.free(c);

        self.lock();
        defer self.unlock();
        try self.agent_steps.append(self.allocator, .{
            .index = index,
            .kind = owned_kind,
            .summary = owned_label,
            .expanded = shouldAutoExpandStep(owned_kind, owned_content),
            .content = owned_content,
            .running = true,
        });
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

        for (self.agent_steps.items) |*step| {
            if (step.running and step.index == index and step.parent_index == null) {
                self.allocator.free(step.kind);
                self.allocator.free(step.summary);
                step.kind = owned_kind;
                step.summary = owned_summary;
                step.running = false;
                return;
            }
        }

        var parent_idx: ?usize = null;
        if (self.agent_steps.items.len > 0) {
            var i = self.agent_steps.items.len;
            while (i > 0) : (i -= 1) {
                const step = &self.agent_steps.items[i - 1];
                if (step.parent_index == null and !step.is_thought and !step.running) {
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

    fn clearRoutingPreviewUnlocked(self: *Session) void {
        if (self.routing_task_intent.len > 0) self.allocator.free(self.routing_task_intent);
        if (self.routing_profile.len > 0) self.allocator.free(self.routing_profile);
        if (self.routing_tools.len > 0) self.allocator.free(self.routing_tools);
        self.routing_task_intent = "";
        self.routing_profile = "";
        self.routing_tools = "";
    }

    pub fn setRoutingPreview(
        self: *Session,
        task_intent: []const u8,
        profile: []const u8,
        tools_summary: []const u8,
    ) !void {
        const task_owned = try self.allocator.dupe(u8, task_intent);
        errdefer self.allocator.free(task_owned);
        const profile_owned = try self.allocator.dupe(u8, profile);
        errdefer self.allocator.free(profile_owned);
        const tools_owned = try self.allocator.dupe(u8, tools_summary);
        errdefer self.allocator.free(tools_owned);

        self.lock();
        defer self.unlock();
        self.clearRoutingPreviewUnlocked();
        self.routing_task_intent = task_owned;
        self.routing_profile = profile_owned;
        self.routing_tools = tools_owned;
    }

    pub fn hasRoutingPreview(self: *Session) bool {
        self.lock();
        defer self.unlock();
        return self.routing_task_intent.len > 0;
    }

    pub fn toggleContextInspector(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.context_inspector_expanded = !self.context_inspector_expanded;
        if (!self.context_inspector_expanded) self.context_selected_index = null;
    }

    pub fn clearValidationResultsUnlocked(self: *Session) void {
        for (self.validation_results.items) |item| {
            self.allocator.free(item.task);
            self.allocator.free(item.output);
        }
        self.validation_results.clearRetainingCapacity();
    }

    pub fn setValidationResults(self: *Session, results: []ValidationResult) !void {
        self.lock();
        defer self.unlock();
        self.clearValidationResultsUnlocked();
        for (results) |item| {
            try self.validation_results.append(self.allocator, .{
                .task = try self.allocator.dupe(u8, item.task),
                .exit_code = item.exit_code,
                .output = try self.allocator.dupe(u8, item.output),
                .skipped = item.skipped,
            });
        }
    }

    pub fn dismissPostApplyBanner(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.post_apply_visible = false;
    }

    pub fn setResumeOffer(
        self: *Session,
        kind: ResumeOfferKind,
        session_id: []const u8,
        intent: []const u8,
        state: []const u8,
        proposal_path: ?[]const u8,
    ) !void {
        const id_owned = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(id_owned);
        const intent_owned = try self.allocator.dupe(u8, intent);
        errdefer self.allocator.free(intent_owned);
        const state_owned = try self.allocator.dupe(u8, state);
        errdefer self.allocator.free(state_owned);
        const proposal_owned = if (proposal_path) |path| try self.allocator.dupe(u8, path) else null;
        errdefer if (proposal_owned) |owned| self.allocator.free(owned);

        self.lock();
        defer self.unlock();
        if (self.resume_session_id) |old| self.allocator.free(old);
        if (self.resume_intent) |old| self.allocator.free(old);
        if (self.resume_state) |old| self.allocator.free(old);
        if (self.resume_proposal_path) |old| self.allocator.free(old);
        self.resume_session_id = id_owned;
        self.resume_intent = intent_owned;
        self.resume_state = state_owned;
        self.resume_proposal_path = proposal_owned;
        self.resume_offer_kind = kind;
        self.resume_offer_visible = true;
    }

    pub fn clearResumeOffer(self: *Session) void {
        self.lock();
        defer self.unlock();
        if (self.resume_session_id) |text| self.allocator.free(text);
        if (self.resume_intent) |text| self.allocator.free(text);
        if (self.resume_state) |text| self.allocator.free(text);
        if (self.resume_proposal_path) |text| self.allocator.free(text);
        self.resume_session_id = null;
        self.resume_intent = null;
        self.resume_state = null;
        self.resume_proposal_path = null;
        self.resume_offer_kind = .continue_run;
        self.resume_offer_visible = false;
    }

    pub fn requestToolApproval(
        self: *Session,
        tool: []const u8,
        args: []const u8,
        risk: []const u8,
        kind: ai.tool_registry.Approval,
    ) bool {
        const tool_copy = self.allocator.dupe(u8, tool) catch return false;
        const args_copy = self.allocator.dupe(u8, args) catch {
            self.allocator.free(tool_copy);
            return false;
        };
        const risk_copy = self.allocator.dupe(u8, risk) catch {
            self.allocator.free(tool_copy);
            self.allocator.free(args_copy);
            return false;
        };

        self.lock();
        if (self.approval_tool) |text| self.allocator.free(text);
        if (self.approval_args) |text| self.allocator.free(text);
        if (self.approval_risk) |text| self.allocator.free(text);
        self.approval_tool = tool_copy;
        self.approval_args = args_copy;
        self.approval_risk = risk_copy;
        self.approval_kind = kind;
        self.approval_decision = .pending;
        self.phase = .waiting_approval;
        while (self.approval_decision == .pending) self.approval_condition.wait(&self.mutex);
        const approved = self.approval_decision == .approved;
        self.approval_decision = .none;
        self.approval_tool = null;
        self.approval_args = null;
        self.approval_risk = null;
        self.approval_kind = null;
        self.allocator.free(tool_copy);
        self.allocator.free(args_copy);
        self.allocator.free(risk_copy);
        self.unlock();
        return approved;
    }

    pub fn resolveToolApproval(self: *Session, approved: bool) void {
        self.lock();
        defer self.unlock();
        if (self.approval_decision != .pending) return;
        self.approval_decision = if (approved) .approved else .rejected;
        self.approval_condition.signal();
    }

    pub fn showPostApplyBanner(self: *Session) void {
        self.lock();
        defer self.unlock();
        self.post_apply_visible = true;
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
        if (self.ephemeral_proposal) |*p| p.deinit();
        self.ephemeral_proposal = null;
        self.show_review = false;
        self.review_scroll_y = 0;
        self.post_apply_visible = false;
        self.last_transaction_id = null;
        self.stream_text.clearRetainingCapacity();
        self.thinking_text.clearRetainingCapacity();
        if (self.generation_start_ts) |start_ts| {
            if (self.first_token_ts) |first_ts| {
                telemetry.recordEvent("ai", "agent_ttft", start_ts, first_ts);
                var end_span = telemetry.startSpan("ai", "agent_generation");
                telemetry.recordEvent("ai", "agent_generation", start_ts, end_span.start_ts);
                end_span.end();
            }
            self.generation_start_ts = null;
            self.first_token_ts = null;
        }
        self.stream_live = false;
        self.freeLinesUnlocked(&self.diff_lines);
        self.clearValidationResultsUnlocked();
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
        if (self.first_token_ts == null) {
            const span = telemetry.startSpan("", "");
            self.first_token_ts = span.start_ts;
        }
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
        if (phase == .sending and self.phase != .sending) {
            const span = telemetry.startSpan("", "");
            self.generation_start_ts = span.start_ts;
            self.first_token_ts = null;
        }
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
        post_apply_visible: bool,
        validation_count: usize,
        spec_pending: bool,
        last_checkpoint_id: ?u64,
        approval_pending: bool,
        approval_kind: ?ai.tool_registry.Approval,
        resume_offer_visible: bool,
        resume_offer_kind: ResumeOfferKind,
        resume_intent: ?[]const u8,
        resume_state: ?[]const u8,
        validation_failed: bool,
        routing_task_intent: []const u8,
        routing_profile: []const u8,
        routing_tools: []const u8,
        has_routing_preview: bool,
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
            .post_apply_visible = self.post_apply_visible,
            .validation_count = self.validation_results.items.len,
            .spec_pending = self.spec_pending,
            .last_checkpoint_id = self.last_checkpoint_id,
            .approval_pending = self.approval_decision == .pending,
            .approval_kind = self.approval_kind,
            .resume_offer_visible = self.resume_offer_visible,
            .resume_offer_kind = self.resume_offer_kind,
            .resume_intent = self.resume_intent,
            .resume_state = self.resume_state,
            .validation_failed = self.phase == .failed and self.post_apply_visible,
            .routing_task_intent = self.routing_task_intent,
            .routing_profile = self.routing_profile,
            .routing_tools = self.routing_tools,
            .has_routing_preview = self.routing_task_intent.len > 0,
        };
    }
};

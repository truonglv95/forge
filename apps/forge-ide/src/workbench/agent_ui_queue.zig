const std = @import("std");
const forge_util = @import("forge-util");
const agent_session = @import("../agent/session.zig");
const agent_workflow = @import("../agent/workflow.zig");

pub const Op = union(enum) {
    append_chat: struct { role: agent_workflow.ChatRole, text: []const u8 },
    set_status: []const u8,
    set_phase: struct { phase: agent_session.Phase, label: []const u8 },
    append_thinking: []const u8,
    append_stream: []const u8,
    begin_step: struct { index: u32, kind: []const u8, label: []const u8 },
    append_step: struct { index: u32, kind: []const u8, summary: []const u8 },
    run_finished: struct {
        run_id: []const u8,
        proposal_rel: []const u8,
        chat_text: []const u8,
        manifest_text: []const u8,
        plan_text: ?[]const u8 = null,
    },
    run_failed: struct {
        phase: agent_session.Phase,
        message: []const u8,
    },
    refresh_context_preview,
    propose_edit: struct {
        path: []const u8,
        start_line: usize,
        end_line: usize,
        replacement: []const u8,
    },

    pub fn deinit(self: *Op, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .append_chat => |*payload| allocator.free(payload.text),
            .set_status => |text| allocator.free(text),
            .set_phase => |*payload| allocator.free(payload.label),
            .append_thinking, .append_stream => |text| allocator.free(text),
            .begin_step => |*payload| {
                allocator.free(payload.kind);
                allocator.free(payload.label);
            },
            .append_step => |*payload| {
                allocator.free(payload.kind);
                allocator.free(payload.summary);
            },
            .run_finished => |*payload| {
                allocator.free(payload.run_id);
                allocator.free(payload.proposal_rel);
                allocator.free(payload.chat_text);
                allocator.free(payload.manifest_text);
                if (payload.plan_text) |text| allocator.free(text);
            },
            .run_failed => |*payload| allocator.free(payload.message),
            .refresh_context_preview => {},
            .propose_edit => |*payload| {
                allocator.free(payload.path);
                allocator.free(payload.replacement);
            },
        }
    }
};

pub const Queue = struct {
    mutex: forge_util.sync.Mutex = .{},
    items: std.ArrayList(Op) = .empty,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |*op| op.deinit(allocator);
        self.items.deinit(allocator);
        self.mutex.deinit();
    }

    pub fn push(self: *Queue, allocator: std.mem.Allocator, op: Op) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, op);
    }

    pub fn takeAll(self: *Queue, allocator: std.mem.Allocator) ![]Op {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return &.{};
        const out = try self.items.toOwnedSlice(allocator);
        self.items = .empty;
        return out;
    }
};

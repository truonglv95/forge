const std = @import("std");
const forge_util = @import("forge-util");
const renderer = @import("forge-renderer");
const agent_session = @import("../agent/session.zig");
const agent_workflow = @import("../agent/workflow.zig");
const workspace = @import("forge-workspace");

pub const Op = union(enum) {
    append_chat: struct { role: agent_workflow.ChatRole, text: []const u8 },
    set_status: []const u8,
    set_phase: struct { phase: agent_session.Phase, label: []const u8 },
    append_thinking: []const u8,
    append_stream: []const u8,
    begin_step: struct { index: u32, kind: []const u8, label: []const u8, content: ?[]const u8 = null },
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
    propose_edit: workspace.edit.WorkspaceEdit,

    pub fn deinit(self: *Op, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .append_chat => |*payload| allocator.free(payload.text),
            .set_status => |text| allocator.free(text),
            .set_phase => |*payload| allocator.free(payload.label),
            .append_thinking, .append_stream => |text| allocator.free(text),
            .begin_step => |*payload| {
                allocator.free(payload.kind);
                allocator.free(payload.label);
                if (payload.content) |content| allocator.free(content);
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
                if (payload.plan_text) |plan| allocator.free(plan);
            },
            .run_failed => |*payload| allocator.free(payload.message),
            .propose_edit => |*edit| edit.deinit(allocator),
            .refresh_context_preview => {},
        }
    }
};

pub const Queue = struct {
    mutex: forge_util.sync.Mutex = .{},
    items: std.ArrayList(Op) = .empty,
    coalesced_ops: u64 = 0,

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
        if (try self.coalesceLast(allocator, op)) {
            renderer.Renderer.requestRedraw();
            return;
        }
        try self.items.append(allocator, op);
        renderer.Renderer.requestRedraw();
    }

    fn coalesceLast(self: *Queue, allocator: std.mem.Allocator, op: Op) !bool {
        if (self.items.items.len == 0) return false;
        const last_i = self.items.items.len - 1;
        switch (op) {
            .append_stream => |text| switch (self.items.items[last_i]) {
                .append_stream => |old| {
                    const joined = try allocator.alloc(u8, old.len + text.len);
                    @memcpy(joined[0..old.len], old);
                    @memcpy(joined[old.len..], text);
                    allocator.free(old);
                    allocator.free(text);
                    self.items.items[last_i] = .{ .append_stream = joined };
                    self.coalesced_ops += 1;
                    return true;
                },
                else => return false,
            },
            .append_thinking => |text| switch (self.items.items[last_i]) {
                .append_thinking => |old| {
                    const joined = try allocator.alloc(u8, old.len + text.len);
                    @memcpy(joined[0..old.len], old);
                    @memcpy(joined[old.len..], text);
                    allocator.free(old);
                    allocator.free(text);
                    self.items.items[last_i] = .{ .append_thinking = joined };
                    self.coalesced_ops += 1;
                    return true;
                },
                else => return false,
            },
            .set_status => |text| switch (self.items.items[last_i]) {
                .set_status => |old| {
                    allocator.free(old);
                    self.items.items[last_i] = .{ .set_status = text };
                    self.coalesced_ops += 1;
                    return true;
                },
                else => return false,
            },
            else => return false,
        }
    }

    pub fn coalescedCount(self: *Queue) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.coalesced_ops;
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

const std = @import("std");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");
const global_store = @import("global_store.zig");

pub const sessions_dir = global_store.sessions_subdir;
pub const sessions_index = "sessions/index.jsonl";
pub const session_events_suffix = ".events.jsonl";

// Legacy per-workspace layout (read-only fallback for migration).
const legacy_sessions_dir = ".forge/sessions";

pub const SessionStep = struct {
    index: u32,
    kind: []const u8,
    summary: []const u8,
    run_id: []const u8,
};

pub const SessionDoc = struct {
    schema_version: u32 = 1,
    session_id: []const u8,
    intent: []const u8,
    workspace_path: []const u8 = "",
    run_ids: [][]const u8 = &.{},
    proposal_path: []const u8 = "",
    steps: []SessionStep = &.{},
    execution_state: []const u8 = "completed",
    next_step_index: u32 = 1,
    pending_tool: []const u8 = "",
    pending_tool_args: []const u8 = "",
    conversation_json: []const u8 = "",
    compact_summary: []const u8 = "",
    task_ledger_json: []const u8 = "",
    provider_kind: []const u8 = "",
    capability_profile: []const u8 = "propose",
    max_steps: u32 = 8,
};

pub const IndexEntry = struct {
    session_id: []const u8,
    intent: []const u8,
    timestamp_ms: i64,
    workspace_path: []const u8 = "",
};

pub const ResumableSession = struct {
    session_id: []const u8,
    intent: []const u8,
    execution_state: []const u8,
};

pub const ProposalReadySession = struct {
    session_id: []const u8,
    intent: []const u8,
    proposal_path: []const u8,
};

pub fn isResumableExecutionState(state: []const u8) bool {
    return std.mem.eql(u8, state, "exploring") or std.mem.eql(u8, state, "tool_pending");
}

pub fn isProposalReadyExecutionState(state: []const u8) bool {
    return std.mem.eql(u8, state, "proposal_ready");
}

pub fn deinitProposalReady(allocator: std.mem.Allocator, offer: *ProposalReadySession) void {
    allocator.free(offer.session_id);
    allocator.free(offer.intent);
    allocator.free(offer.proposal_path);
    offer.* = undefined;
}

pub fn deinitResumable(allocator: std.mem.Allocator, offer: *ResumableSession) void {
    allocator.free(offer.session_id);
    allocator.free(offer.intent);
    allocator.free(offer.execution_state);
    offer.* = undefined;
}

pub fn findLatestResumable(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
) !?ResumableSession {
    var list = try listEntries(allocator, io, workspace_path);
    defer list.deinit();

    var index = list.items.len;
    while (index > 0) : (index -= 1) {
        const entry = list.items[index - 1];
        var doc = loadSession(allocator, io, entry.session_id) catch continue;
        defer deinitSession(allocator, &doc);
        if (!isResumableExecutionState(doc.execution_state)) continue;
        return ResumableSession{
            .session_id = try allocator.dupe(u8, doc.session_id),
            .intent = try allocator.dupe(u8, doc.intent),
            .execution_state = try allocator.dupe(u8, doc.execution_state),
        };
    }
    return null;
}

pub fn findLatestProposalReady(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
) !?ProposalReadySession {
    var list = try listEntries(allocator, io, workspace_path);
    defer list.deinit();

    var index = list.items.len;
    while (index > 0) : (index -= 1) {
        const entry = list.items[index - 1];
        var doc = loadSession(allocator, io, entry.session_id) catch continue;
        defer deinitSession(allocator, &doc);
        if (!isProposalReadyExecutionState(doc.execution_state)) continue;
        if (doc.proposal_path.len == 0) continue;
        return ProposalReadySession{
            .session_id = try allocator.dupe(u8, doc.session_id),
            .intent = try allocator.dupe(u8, doc.intent),
            .proposal_path = try allocator.dupe(u8, doc.proposal_path),
        };
    }
    return null;
}

pub const IndexList = struct {
    allocator: std.mem.Allocator,
    items: []IndexEntry,

    pub fn deinit(self: *IndexList) void {
        for (self.items) |entry| {
            self.allocator.free(entry.session_id);
            self.allocator.free(entry.intent);
            self.allocator.free(entry.workspace_path);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

fn sessionFilePath(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var rel_buf: [192]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, "{s}/{s}.json", .{ sessions_dir, session_id });
    return global_store.joinHome(allocator, rel);
}

fn sessionEventsPath(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    var rel_buf: [192]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, "{s}/{s}{s}", .{ sessions_dir, session_id, session_events_suffix });
    return global_store.joinHome(allocator, rel);
}

fn indexFilePath(allocator: std.mem.Allocator) ![]u8 {
    return global_store.joinHome(allocator, sessions_index);
}

fn readLegacyRelativeFile(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, rel_path: []const u8) ![]u8 {
    var file = try root.dir.openFile(io, rel_path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const content = try allocator.alloc(u8, size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);
    if (read_len != size) return error.UnexpectedEof;
    return content;
}

pub fn formatIndexLine(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    intent: []const u8,
    timestamp_ms: i64,
    workspace_path: []const u8,
) ![]u8 {
    const Json = struct {
        session_id: []const u8,
        intent: []const u8,
        timestamp_ms: i64,
        workspace_path: []const u8,
    };
    const line = try std.json.Stringify.valueAlloc(allocator, Json{
        .session_id = session_id,
        .intent = intent,
        .timestamp_ms = timestamp_ms,
        .workspace_path = workspace_path,
    }, .{});
    defer allocator.free(line);
    return try std.fmt.allocPrint(allocator, "{s}\n", .{line});
}

pub fn appendIndex(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, line: []const u8) !void {
    _ = workspace_path;
    try global_store.ensureLayout(io);

    const index_path = try indexFilePath(allocator);
    defer allocator.free(index_path);

    const line_with_nl = if (line.len > 0 and line[line.len - 1] == '\n')
        try allocator.dupe(u8, line)
    else
        try std.fmt.allocPrint(allocator, "{s}\n", .{line});
    defer allocator.free(line_with_nl);
    try global_store.appendAbsoluteFile(io, index_path, line_with_nl);
}

pub fn listEntries(allocator: std.mem.Allocator, io: std.Io, workspace_path: ?[]const u8) !IndexList {
    var items: std.ArrayList(IndexEntry) = .empty;
    errdefer {
        for (items.items) |entry| {
            allocator.free(entry.session_id);
            allocator.free(entry.intent);
        }
        items.deinit(allocator);
    }

    const index_path = try indexFilePath(allocator);
    defer allocator.free(index_path);

    const content = global_store.readAbsoluteFile(allocator, io, index_path) catch |err| switch (err) {
        error.FileNotFound => return IndexList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) },
        else => return err,
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const JsonEntry = struct {
            session_id: []const u8,
            intent: []const u8,
            timestamp_ms: i64,
            workspace_path: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(JsonEntry, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (workspace_path) |filter| {
            if (parsed.value.workspace_path) |stored| {
                if (!std.mem.eql(u8, stored, filter)) continue;
            }
        }
        try items.append(allocator, .{
            .session_id = try allocator.dupe(u8, parsed.value.session_id),
            .intent = try allocator.dupe(u8, parsed.value.intent),
            .timestamp_ms = parsed.value.timestamp_ms,
            .workspace_path = try allocator.dupe(u8, parsed.value.workspace_path orelse ""),
        });
    }

    return IndexList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub fn ensureLayout(io: std.Io) !void {
    try global_store.ensureLayout(io);
}

pub fn persistSession(io: std.Io, workspace_path: []const u8, session_id: []const u8, json_body: []const u8) !void {
    _ = workspace_path;
    try global_store.ensureLayout(io);
    const path = sessionFilePath(std.heap.page_allocator, session_id) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(path);
    try global_store.replaceAbsoluteFile(io, path, json_body);
}

pub fn appendEvent(allocator: std.mem.Allocator, io: std.Io, session_id: []const u8, line: []const u8) !void {
    try global_store.ensureLayout(io);
    const path = try sessionEventsPath(allocator, session_id);
    defer allocator.free(path);

    const line_with_nl = if (line.len > 0 and line[line.len - 1] == '\n')
        try allocator.dupe(u8, line)
    else
        try std.fmt.allocPrint(allocator, "{s}\n", .{line});
    defer allocator.free(line_with_nl);
    try global_store.appendAbsoluteFile(io, path, line_with_nl);
}

pub fn readEvents(allocator: std.mem.Allocator, io: std.Io, session_id: []const u8) ![]u8 {
    const path = try sessionEventsPath(allocator, session_id);
    defer allocator.free(path);
    return global_store.readAbsoluteFile(allocator, io, path);
}

pub fn readEventsLegacy(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    session_id: []const u8,
) ![]u8 {
    var path_buf: [160]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ legacy_sessions_dir, session_id, session_events_suffix });
    return readLegacyRelativeFile(allocator, io, root, rel);
}

test "sessions append events under global sessions dir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try withTestForgeHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer global_store.clearForgeHomeOverride();

    try appendEvent(allocator, io, "sess_events", "{\"schema_version\":1,\"type\":\"run_started\"}");
    try appendEvent(allocator, io, "sess_events", "{\"schema_version\":1,\"type\":\"run_completed\"}");

    const body = try readEvents(allocator, io, "sess_events");
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "run_started") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "run_completed") != null);
}

pub fn makeSessionId(allocator: std.mem.Allocator, timestamp_ms: i64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "sess_{d}_{d}", .{ timestamp_ms, std.Thread.getCurrentId() });
}

pub fn deinitSession(allocator: std.mem.Allocator, doc: *SessionDoc) void {
    allocator.free(doc.session_id);
    allocator.free(doc.intent);
    allocator.free(doc.workspace_path);
    allocator.free(doc.proposal_path);
    allocator.free(doc.execution_state);
    allocator.free(doc.pending_tool);
    allocator.free(doc.pending_tool_args);
    allocator.free(doc.conversation_json);
    allocator.free(doc.compact_summary);
    allocator.free(doc.task_ledger_json);
    allocator.free(doc.provider_kind);
    allocator.free(doc.capability_profile);
    for (doc.run_ids) |run_id| allocator.free(run_id);
    allocator.free(doc.run_ids);
    for (doc.steps) |step| {
        allocator.free(step.kind);
        allocator.free(step.summary);
        allocator.free(step.run_id);
    }
    allocator.free(doc.steps);
    doc.* = undefined;
}

pub fn loadSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,
) !SessionDoc {
    const path = sessionFilePath(allocator, session_id) catch return error.OutOfMemory;
    defer allocator.free(path);

    const json_body = global_store.readAbsoluteFile(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    defer allocator.free(json_body);

    return try parseSessionDoc(allocator, json_body);
}

pub fn loadSessionLegacy(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: path_mod.WorkspaceRoot,
    session_id: []const u8,
) !SessionDoc {
    var path_buf: [128]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ legacy_sessions_dir, session_id });
    const json_body = try readLegacyRelativeFile(allocator, io, root, rel);
    defer allocator.free(json_body);
    return try parseSessionDoc(allocator, json_body);
}

fn parseSessionDoc(allocator: std.mem.Allocator, json_body: []const u8) !SessionDoc {
    var parsed = try std.json.parseFromSlice(SessionDoc, allocator, json_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const value = parsed.value;
    const owned_steps = try allocator.alloc(SessionStep, value.steps.len);
    errdefer allocator.free(owned_steps);
    for (value.steps, 0..) |step, index| {
        owned_steps[index] = .{
            .index = step.index,
            .kind = try allocator.dupe(u8, step.kind),
            .summary = try allocator.dupe(u8, step.summary),
            .run_id = try allocator.dupe(u8, step.run_id),
        };
    }

    const owned_run_ids = try allocator.alloc([]const u8, value.run_ids.len);
    errdefer {
        for (owned_run_ids) |id| allocator.free(id);
        allocator.free(owned_run_ids);
    }
    for (value.run_ids, 0..) |run_id, index| {
        owned_run_ids[index] = try allocator.dupe(u8, run_id);
    }

    return .{
        .schema_version = value.schema_version,
        .session_id = try allocator.dupe(u8, value.session_id),
        .intent = try allocator.dupe(u8, value.intent),
        .workspace_path = try allocator.dupe(u8, value.workspace_path),
        .run_ids = owned_run_ids,
        .proposal_path = try allocator.dupe(u8, value.proposal_path),
        .steps = owned_steps,
        .execution_state = try allocator.dupe(u8, value.execution_state),
        .next_step_index = value.next_step_index,
        .pending_tool = try allocator.dupe(u8, value.pending_tool),
        .pending_tool_args = try allocator.dupe(u8, value.pending_tool_args),
        .conversation_json = try allocator.dupe(u8, value.conversation_json),
        .compact_summary = try allocator.dupe(u8, value.compact_summary),
        .task_ledger_json = try allocator.dupe(u8, value.task_ledger_json),
        .provider_kind = try allocator.dupe(u8, value.provider_kind),
        .capability_profile = try allocator.dupe(u8, value.capability_profile),
        .max_steps = value.max_steps,
    };
}

fn withTestForgeHome(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/forge-test-{s}", .{tmp.sub_path});
    try global_store.setForgeHomeOverride(path);
    return path;
}

test "sessions persist globally under FORGE_HOME" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try withTestForgeHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer global_store.clearForgeHomeOverride();

    try persistSession(io, "/tmp/project", "sess_1", "{\"session_id\":\"sess_1\"}\n");

    const path = try sessionFilePath(allocator, "sess_1");
    defer allocator.free(path);
    const body = try global_store.readAbsoluteFile(allocator, io, path);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "sess_1") != null);
}

test "sessions index list parses jsonl" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try withTestForgeHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer global_store.clearForgeHomeOverride();

    const line = try formatIndexLine(allocator, "sess_1", "test", 100, "/tmp/project");
    defer allocator.free(line);
    try appendIndex(allocator, io, "/tmp/project", line);

    var list = try listEntries(allocator, io, "/tmp/project");
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("sess_1", list.items[0].session_id);
}

test "findLatestResumable prefers interrupted sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try withTestForgeHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer global_store.clearForgeHomeOverride();

    const workspace_path = "/tmp/project";
    const completed =
        \\{"schema_version":3,"session_id":"sess_done","intent":"done","execution_state":"completed","conversation_json":"[]","steps":[]}
    ;
    const pending =
        \\{"schema_version":3,"session_id":"sess_pending","intent":"resume me","execution_state":"tool_pending","pending_tool":"search","pending_tool_args":"{}","conversation_json":"[]","steps":[]}
    ;
    try persistSession(io, workspace_path, "sess_done", completed);
    try persistSession(io, workspace_path, "sess_pending", pending);
    const line_done = try formatIndexLine(allocator, "sess_done", "done", 1, workspace_path);
    defer allocator.free(line_done);
    const line_pending = try formatIndexLine(allocator, "sess_pending", "resume me", 2, workspace_path);
    defer allocator.free(line_pending);
    try appendIndex(allocator, io, workspace_path, line_done);
    try appendIndex(allocator, io, workspace_path, line_pending);

    const offer_opt = try findLatestResumable(allocator, io, workspace_path);
    try std.testing.expect(offer_opt != null);
    if (offer_opt) |value| {
        var owned = value;
        defer deinitResumable(allocator, &owned);
        try std.testing.expectEqualStrings("sess_pending", owned.session_id);
        try std.testing.expectEqualStrings("tool_pending", owned.execution_state);
    }
}

test "findLatestProposalReady prefers latest proposal_ready session" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try withTestForgeHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer global_store.clearForgeHomeOverride();

    const workspace_path = "/tmp/project";
    const older =
        \\{"schema_version":3,"session_id":"sess_old","intent":"old","execution_state":"proposal_ready","proposal_path":".forge/proposals/run_old.json","conversation_json":"[]","steps":[]}
    ;
    const newer =
        \\{"schema_version":3,"session_id":"sess_new","intent":"review me","execution_state":"proposal_ready","proposal_path":".forge/proposals/run_new.json","conversation_json":"[]","steps":[]}
    ;
    try persistSession(io, workspace_path, "sess_old", older);
    try persistSession(io, workspace_path, "sess_new", newer);
    const line_old = try formatIndexLine(allocator, "sess_old", "old", 1, workspace_path);
    defer allocator.free(line_old);
    const line_new = try formatIndexLine(allocator, "sess_new", "review me", 2, workspace_path);
    defer allocator.free(line_new);
    try appendIndex(allocator, io, workspace_path, line_old);
    try appendIndex(allocator, io, workspace_path, line_new);

    const offer_opt = try findLatestProposalReady(allocator, io, workspace_path);
    try std.testing.expect(offer_opt != null);
    if (offer_opt) |value| {
        var owned = value;
        defer deinitProposalReady(allocator, &owned);
        try std.testing.expectEqualStrings("sess_new", owned.session_id);
        try std.testing.expectEqualStrings(".forge/proposals/run_new.json", owned.proposal_path);
    }
}

test "loadSession reads persisted session" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const forge_home = try withTestForgeHome(allocator, &tmp);
    defer allocator.free(forge_home);
    defer global_store.clearForgeHomeOverride();

    const body =
        \\{"schema_version":1,"session_id":"sess_2","intent":"search sample","run_ids":["run_1"],"proposal_path":".forge/proposals/run_1.json","steps":[{"index":1,"kind":"search","summary":"ok","run_id":""}]}
    ;
    try persistSession(io, "/tmp/project", "sess_2", body);

    var doc = try loadSession(allocator, io, "sess_2");
    defer deinitSession(allocator, &doc);
    try std.testing.expectEqualStrings("sess_2", doc.session_id);
    try std.testing.expectEqualStrings("search sample", doc.intent);
    try std.testing.expectEqual(@as(usize, 1), doc.steps.len);
}

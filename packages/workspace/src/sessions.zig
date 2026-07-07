const std = @import("std");
const path_mod = @import("path.zig");
const atomic = @import("atomic.zig");

pub const sessions_dir = ".forge/sessions";
pub const sessions_index = ".forge/sessions/index.jsonl";
pub const session_events_suffix = ".events.jsonl";

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
    run_ids: [][]const u8 = &.{},
    proposal_path: []const u8 = "",
    steps: []SessionStep = &.{},
    execution_state: []const u8 = "completed",
    next_step_index: u32 = 1,
    pending_tool: []const u8 = "",
    pending_tool_args: []const u8 = "",
    conversation_json: []const u8 = "",
    provider_kind: []const u8 = "",
    capability_profile: []const u8 = "propose",
    max_steps: u32 = 8,
};

pub const IndexEntry = struct {
    session_id: []const u8,
    intent: []const u8,
    timestamp_ms: i64,
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
    root: path_mod.WorkspaceRoot,
) !?ResumableSession {
    var list = try listEntries(allocator, io, root);
    defer list.deinit();

    var index = list.items.len;
    while (index > 0) : (index -= 1) {
        const entry = list.items[index - 1];
        var doc = loadSession(allocator, io, root, entry.session_id) catch continue;
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
    root: path_mod.WorkspaceRoot,
) !?ProposalReadySession {
    var list = try listEntries(allocator, io, root);
    defer list.deinit();

    var index = list.items.len;
    while (index > 0) : (index -= 1) {
        const entry = list.items[index - 1];
        var doc = loadSession(allocator, io, root, entry.session_id) catch continue;
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
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

fn readRelativeFile(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, rel_path: []const u8) ![]u8 {
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

pub fn formatIndexLine(allocator: std.mem.Allocator, session_id: []const u8, intent: []const u8, timestamp_ms: i64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\",\"intent\":\"{s}\",\"timestamp_ms\":{d}}}\n", .{
        session_id,
        intent,
        timestamp_ms,
    });
}

pub fn appendIndex(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, line: []const u8) !void {
    try ensureLayout(io, root);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const existing = readRelativeFile(allocator, io, root, sessions_index) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        try buffer.appendSlice(allocator, bytes);
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try buffer.append(allocator, '\n');
    }

    try buffer.appendSlice(allocator, line);
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(sessions_index), buffer.items);
}

pub fn listEntries(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot) !IndexList {
    var items: std.ArrayList(IndexEntry) = .empty;
    errdefer {
        for (items.items) |entry| {
            allocator.free(entry.session_id);
            allocator.free(entry.intent);
        }
        items.deinit(allocator);
    }

    const content = readRelativeFile(allocator, io, root, sessions_index) catch |err| switch (err) {
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
        };
        var parsed = try std.json.parseFromSlice(JsonEntry, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try items.append(allocator, .{
            .session_id = try allocator.dupe(u8, parsed.value.session_id),
            .intent = try allocator.dupe(u8, parsed.value.intent),
            .timestamp_ms = parsed.value.timestamp_ms,
        });
    }

    return IndexList{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub fn ensureLayout(io: std.Io, root: path_mod.WorkspaceRoot) !void {
    try root.dir.createDirPath(io, ".forge");
    try root.dir.createDirPath(io, sessions_dir);
}

pub fn persistSession(io: std.Io, root: path_mod.WorkspaceRoot, session_id: []const u8, json_body: []const u8) !void {
    try ensureLayout(io, root);

    var path_buf: [128]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ sessions_dir, session_id });
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(rel), json_body);
}

pub fn appendEvent(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, session_id: []const u8, line: []const u8) !void {
    try ensureLayout(io, root);

    var path_buf: [160]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ sessions_dir, session_id, session_events_suffix });

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const existing = readRelativeFile(allocator, io, root, rel) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |bytes| {
        defer allocator.free(bytes);
        try buffer.appendSlice(allocator, bytes);
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try buffer.append(allocator, '\n');
    }

    try buffer.appendSlice(allocator, line);
    if (line.len > 0 and line[line.len - 1] != '\n') try buffer.append(allocator, '\n');
    try atomic.replaceFile(io, root, try path_mod.WorkspacePath.parse(rel), buffer.items);
}

pub fn readEvents(allocator: std.mem.Allocator, io: std.Io, root: path_mod.WorkspaceRoot, session_id: []const u8) ![]u8 {
    var path_buf: [160]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ sessions_dir, session_id, session_events_suffix });
    return try readRelativeFile(allocator, io, root, rel);
}

test "sessions append events under .forge/sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    try appendEvent(allocator, io, root, "sess_events", "{\"schema_version\":1,\"type\":\"run_started\"}");
    try appendEvent(allocator, io, root, "sess_events", "{\"schema_version\":1,\"type\":\"run_completed\"}");

    const body = try readEvents(allocator, io, root, "sess_events");
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "run_started") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "run_completed") != null);
}

pub fn makeSessionId(allocator: std.mem.Allocator, timestamp_ms: i64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "sess_{d}", .{timestamp_ms});
}

pub fn deinitSession(allocator: std.mem.Allocator, doc: *SessionDoc) void {
    allocator.free(doc.session_id);
    allocator.free(doc.intent);
    allocator.free(doc.proposal_path);
    allocator.free(doc.execution_state);
    allocator.free(doc.pending_tool);
    allocator.free(doc.pending_tool_args);
    allocator.free(doc.conversation_json);
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
    root: path_mod.WorkspaceRoot,
    session_id: []const u8,
) !SessionDoc {
    var path_buf: [128]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ sessions_dir, session_id });

    var file = root.dir.openFile(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SessionNotFound,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const json_body = try allocator.alloc(u8, size);
    errdefer allocator.free(json_body);
    const read_len = try file.readPositionalAll(io, json_body, 0);
    if (read_len != size) return error.UnexpectedEof;

    var parsed = try std.json.parseFromSlice(SessionDoc, allocator, json_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    defer allocator.free(json_body);

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
        .run_ids = owned_run_ids,
        .proposal_path = try allocator.dupe(u8, value.proposal_path),
        .steps = owned_steps,
        .execution_state = try allocator.dupe(u8, value.execution_state),
        .next_step_index = value.next_step_index,
        .pending_tool = try allocator.dupe(u8, value.pending_tool),
        .pending_tool_args = try allocator.dupe(u8, value.pending_tool_args),
        .conversation_json = try allocator.dupe(u8, value.conversation_json),
        .provider_kind = try allocator.dupe(u8, value.provider_kind),
        .capability_profile = try allocator.dupe(u8, value.capability_profile),
        .max_steps = value.max_steps,
    };
}

test "sessions persist under .forge/sessions" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    try persistSession(io, root, "sess_1", "{\"session_id\":\"sess_1\"}\n");

    var file = try root.dir.openFile(io, ".forge/sessions/sess_1.json", .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    const n = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..n], "sess_1") != null);
}

test "sessions index list parses jsonl" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    try appendIndex(allocator, io, root, "{\"session_id\":\"sess_1\",\"intent\":\"test\",\"timestamp_ms\":100}\n");

    var list = try listEntries(allocator, io, root);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("sess_1", list.items[0].session_id);
}

test "findLatestResumable prefers interrupted sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    const completed =
        \\{"schema_version":3,"session_id":"sess_done","intent":"done","execution_state":"completed","conversation_json":"[]","steps":[]}
    ;
    const pending =
        \\{"schema_version":3,"session_id":"sess_pending","intent":"resume me","execution_state":"tool_pending","pending_tool":"search","pending_tool_args":"{}","conversation_json":"[]","steps":[]}
    ;
    try persistSession(io, root, "sess_done", completed);
    try persistSession(io, root, "sess_pending", pending);
    try appendIndex(allocator, io, root, "{\"session_id\":\"sess_done\",\"intent\":\"done\",\"timestamp_ms\":1}\n");
    try appendIndex(allocator, io, root, "{\"session_id\":\"sess_pending\",\"intent\":\"resume me\",\"timestamp_ms\":2}\n");

    const offer_opt = try findLatestResumable(allocator, io, root);
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
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    const older =
        \\{"schema_version":3,"session_id":"sess_old","intent":"old","execution_state":"proposal_ready","proposal_path":".forge/proposals/run_old.json","conversation_json":"[]","steps":[]}
    ;
    const newer =
        \\{"schema_version":3,"session_id":"sess_new","intent":"review me","execution_state":"proposal_ready","proposal_path":".forge/proposals/run_new.json","conversation_json":"[]","steps":[]}
    ;
    try persistSession(io, root, "sess_old", older);
    try persistSession(io, root, "sess_new", newer);
    try appendIndex(allocator, io, root, "{\"session_id\":\"sess_old\",\"intent\":\"old\",\"timestamp_ms\":1}\n");
    try appendIndex(allocator, io, root, "{\"session_id\":\"sess_new\",\"intent\":\"review me\",\"timestamp_ms\":2}\n");

    const offer_opt = try findLatestProposalReady(allocator, io, root);
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
    const root = path_mod.WorkspaceRoot.init(tmp.dir);

    const body =
        \\{"schema_version":1,"session_id":"sess_2","intent":"search sample","run_ids":["run_1"],"proposal_path":".forge/proposals/run_1.json","steps":[{"index":1,"kind":"search","summary":"ok","run_id":""}]}
    ;
    try persistSession(io, root, "sess_2", body);

    var doc = try loadSession(allocator, io, root, "sess_2");
    defer deinitSession(allocator, &doc);
    try std.testing.expectEqualStrings("sess_2", doc.session_id);
    try std.testing.expectEqualStrings("search sample", doc.intent);
    try std.testing.expectEqual(@as(usize, 1), doc.steps.len);
}

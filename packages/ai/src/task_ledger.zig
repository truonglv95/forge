const std = @import("std");

pub const Phase = enum {
    planning,
    gathering,
    editing,
    validating,
    repairing,
    summarizing,
    completed,
    blocked,
};

pub const EntryKind = enum {
    goal,
    assumption,
    file_read,
    file_edited,
    search,
    command,
    validation,
    blocker,
    decision,
    context_compaction,
};

pub const StepInput = struct {
    index: u32,
    kind: []const u8,
    summary: []const u8,
};

pub const Entry = struct {
    kind: EntryKind,
    step_index: u32 = 0,
    path: []const u8 = "",
    text: []const u8,
};

pub const Snapshot = struct {
    phase: Phase,
    goal: []const u8,
    entries: []Entry,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.goal);
        for (self.entries) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.text);
        }
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const Stats = struct {
    phase: Phase = .planning,
    entries: usize = 0,
    file_reads: usize = 0,
    file_edits: usize = 0,
    blockers: usize = 0,
    validations: usize = 0,
    searches: usize = 0,

    pub fn longTask(self: Stats) bool {
        return self.entries >= 16 or self.file_reads >= 8 or self.searches >= 8;
    }

    pub fn needsFreshEvidence(self: Stats) bool {
        return self.phase == .repairing or self.phase == .blocked or self.blockers > 0 or self.validations > 0;
    }
};

pub const EvidenceItem = struct {
    path: []const u8,
    hash: ?u64 = null,
    start_line: usize = 0,
    end_line: usize = 0,
    step_index: u32 = 0,

    pub fn deinit(self: *EvidenceItem, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const WorkingState = struct {
    phase: Phase,
    goal: []const u8,
    entries: usize = 0,
    evidence: []EvidenceItem = &.{},
    blockers: usize = 0,
    validations: usize = 0,
    edits: usize = 0,

    pub fn deinit(self: *WorkingState, allocator: std.mem.Allocator) void {
        allocator.free(self.goal);
        freeEvidence(allocator, self.evidence);
        self.* = undefined;
    }
};

pub const StateText = struct {
    text: []const u8,
    step_index: u32 = 0,

    pub fn deinit(self: *StateText, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const FileRecord = struct {
    path: []const u8,
    last_read_hash: ?u64 = null,
    last_read_step: u32 = 0,
    last_edit_step: u32 = 0,
    edited: bool = false,

    pub fn deinit(self: *FileRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const ValidationStatus = enum {
    unknown,
    not_run,
    passed,
    failed,
};

pub const ValidationRecord = struct {
    status: ValidationStatus = .not_run,
    command: []const u8 = "",
    step_index: u32 = 0,
    output: []const u8 = "",

    pub fn deinit(self: *ValidationRecord, allocator: std.mem.Allocator) void {
        if (self.command.len > 0) allocator.free(self.command);
        if (self.output.len > 0) allocator.free(self.output);
        self.* = undefined;
    }
};

pub const AgentState = struct {
    phase: Phase = .planning,
    goal: []const u8,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    todos: std.ArrayListUnmanaged(StateText) = .empty,
    facts: std.ArrayListUnmanaged(StateText) = .empty,
    files: std.ArrayListUnmanaged(FileRecord) = .empty,
    validation: ValidationRecord = .{},

    pub fn init(allocator: std.mem.Allocator, goal: []const u8) !AgentState {
        var state = AgentState{ .goal = try allocator.dupe(u8, goal) };
        errdefer state.deinit(allocator);
        try state.appendEntry(allocator, .goal, 0, "", goal);
        try state.appendTodo(allocator, "Satisfy the user goal", 0);
        return state;
    }

    pub fn initFromJsonOrGoal(allocator: std.mem.Allocator, json: []const u8, goal: []const u8) !AgentState {
        if (json.len == 0) return init(allocator, goal);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return init(allocator, goal);
        defer parsed.deinit();
        if (parsed.value != .object) return init(allocator, goal);
        const obj = parsed.value.object;

        const goal_text = if (obj.get("goal")) |value| if (value == .string) value.string else goal else goal;
        var state = AgentState{
            .phase = if (obj.get("phase")) |value| if (value == .string) parsePhase(value.string) else .planning else .planning,
            .goal = try allocator.dupe(u8, goal_text),
        };
        errdefer state.deinit(allocator);

        if (obj.get("todos")) |value| try state.loadStateTextArray(allocator, value, .todo);
        if (obj.get("facts")) |value| try state.loadStateTextArray(allocator, value, .fact);
        if (obj.get("entries")) |value| try state.loadEntriesArray(allocator, value);
        if (obj.get("files")) |value| try state.loadFilesArray(allocator, value);
        if (obj.get("validation")) |value| try state.loadValidation(allocator, value);

        if (state.entries.items.len == 0) try state.appendEntry(allocator, .goal, 0, "", state.goal);
        if (state.todos.items.len == 0) try state.appendTodo(allocator, "Satisfy the user goal", 0);
        try state.rebuildDerivedFromEntries(allocator);
        return state;
    }

    pub fn deinit(self: *AgentState, allocator: std.mem.Allocator) void {
        allocator.free(self.goal);
        for (self.entries.items) |*entry| {
            allocator.free(entry.path);
            allocator.free(entry.text);
        }
        self.entries.deinit(allocator);
        for (self.todos.items) |*item| item.deinit(allocator);
        self.todos.deinit(allocator);
        for (self.facts.items) |*item| item.deinit(allocator);
        self.facts.deinit(allocator);
        for (self.files.items) |*file| file.deinit(allocator);
        self.files.deinit(allocator);
        self.validation.deinit(allocator);
        self.* = undefined;
    }

    pub fn recordToolResult(self: *AgentState, allocator: std.mem.Allocator, step_index: u32, tool_name: []const u8, result: []const u8) !void {
        const kind = classifyStep(tool_name, result);
        const path = extractBacktickValue(allocator, result) catch try allocator.dupe(u8, "");
        defer allocator.free(path);
        try self.appendEntry(allocator, kind, step_index, path, trimWhitespace(result));

        switch (kind) {
            .file_read => {
                const evidence = parseReadEvidence(allocator, .{ .index = step_index, .kind = tool_name, .summary = result }) catch return;
                defer {
                    var owned = evidence;
                    owned.deinit(allocator);
                }
                try self.noteFileRead(allocator, evidence.path, evidence.hash, step_index);
                try self.appendFact(allocator, result, step_index);
                self.phase = .gathering;
            },
            .file_edited => {
                const edit_path = if (path.len > 0) path else pathFromEditArgs(allocator, result) catch "";
                defer if (edit_path.ptr != path.ptr and edit_path.len > 0) allocator.free(edit_path);
                if (edit_path.len > 0) try self.noteFileEdit(allocator, edit_path, step_index);
                self.phase = .editing;
                self.validation.status = .not_run;
            },
            .validation => {
                try self.setValidation(allocator, result, step_index);
                self.phase = .validating;
            },
            .command => {
                if (looksLikeValidationResult(result)) {
                    try self.setValidation(allocator, result, step_index);
                    self.phase = .validating;
                }
            },
            .blocker => {
                self.phase = .blocked;
            },
            .search => {
                self.phase = .gathering;
                try self.appendFact(allocator, result, step_index);
            },
            else => {},
        }
    }

    pub fn hasFreshFileEvidence(self: AgentState, path: []const u8, hash: u64) bool {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.path, path) and file.last_read_hash != null and file.last_read_hash.? == hash) return true;
        }
        return false;
    }

    pub fn hasEdits(self: AgentState) bool {
        for (self.files.items) |file| {
            if (file.edited) return true;
        }
        return false;
    }

    pub fn lastEditStep(self: AgentState) u32 {
        var latest: u32 = 0;
        for (self.files.items) |file| latest = @max(latest, file.last_edit_step);
        return latest;
    }

    pub fn validationAfterLastEdit(self: AgentState) bool {
        const edit_step = self.lastEditStep();
        if (edit_step == 0) return true;
        return self.validation.step_index > edit_step and (self.validation.status == .passed or self.validation.status == .failed);
    }

    pub fn finalGateIssue(self: AgentState, allocator: std.mem.Allocator, final_text: []const u8) !?[]const u8 {
        if (std.mem.trim(u8, final_text, &std.ascii.whitespace).len == 0) {
            return try allocator.dupe(u8, "Final answer blocked: missing summary text.");
        }
        if (self.hasEdits() and !self.validationAfterLastEdit()) {
            return try allocator.dupe(u8, "Final answer blocked: edits were made but no validation command has run after the latest edit. Run an allowlisted validation command or explain a failed validation result.");
        }
        if (self.hasEdits() and self.validation.status == .not_run) {
            return try allocator.dupe(u8, "Final answer blocked: missing verification status after edits.");
        }
        return null;
    }

    pub fn toJsonAlloc(self: AgentState, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        const writer = &out.writer;
        try writer.writeAll("{\"schema_version\":2");
        try writer.print(",\"phase\":\"{s}\"", .{@tagName(self.phase)});
        try writer.writeAll(",\"goal\":");
        try std.json.Stringify.value(self.goal, .{}, writer);

        try writer.writeAll(",\"todos\":[");
        for (self.todos.items, 0..) |item, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{{\"step_index\":{d},\"text\":", .{item.step_index});
            try std.json.Stringify.value(item.text, .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"facts\":[");
        for (self.facts.items, 0..) |item, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{{\"step_index\":{d},\"text\":", .{item.step_index});
            try std.json.Stringify.value(trimTail(item.text, 512), .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"files\":[");
        for (self.files.items, 0..) |file, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"path\":");
            try std.json.Stringify.value(file.path, .{}, writer);
            if (file.last_read_hash) |hash| {
                try writer.print(",\"last_read_hash\":{d}", .{hash});
            } else {
                try writer.writeAll(",\"last_read_hash\":null");
            }
            try writer.print(",\"last_read_step\":{d},\"last_edit_step\":{d},\"edited\":{}}}", .{ file.last_read_step, file.last_edit_step, file.edited });
        }
        try writer.writeAll("],\"validation\":{");
        try writer.print("\"status\":\"{s}\",\"step_index\":{d},\"command\":", .{ @tagName(self.validation.status), self.validation.step_index });
        try std.json.Stringify.value(self.validation.command, .{}, writer);
        try writer.writeAll(",\"output\":");
        try std.json.Stringify.value(trimTail(self.validation.output, 512), .{}, writer);
        try writer.writeByte('}');

        try writer.writeAll(",\"entries\":[");
        for (self.entries.items, 0..) |entry, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print("{{\"kind\":\"{s}\",\"step_index\":{d},\"path\":", .{ @tagName(entry.kind), entry.step_index });
            try std.json.Stringify.value(entry.path, .{}, writer);
            try writer.writeAll(",\"text\":");
            try std.json.Stringify.value(trimTail(entry.text, 512), .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
        return try out.toOwnedSlice();
    }

    fn appendEntry(self: *AgentState, allocator: std.mem.Allocator, kind: EntryKind, step_index: u32, path: []const u8, text: []const u8) !void {
        try self.entries.append(allocator, .{
            .kind = kind,
            .step_index = step_index,
            .path = try allocator.dupe(u8, path),
            .text = try allocator.dupe(u8, text),
        });
    }

    fn appendTodo(self: *AgentState, allocator: std.mem.Allocator, text: []const u8, step_index: u32) !void {
        try self.todos.append(allocator, .{ .text = try allocator.dupe(u8, text), .step_index = step_index });
    }

    fn appendFact(self: *AgentState, allocator: std.mem.Allocator, text: []const u8, step_index: u32) !void {
        try self.facts.append(allocator, .{ .text = try allocator.dupe(u8, trimTail(trimWhitespace(text), 512)), .step_index = step_index });
        if (self.facts.items.len > 32) {
            self.facts.items[0].deinit(allocator);
            _ = self.facts.orderedRemove(0);
        }
    }

    fn noteFileRead(self: *AgentState, allocator: std.mem.Allocator, path: []const u8, hash: ?u64, step_index: u32) !void {
        const rec = try self.fileRecord(allocator, path);
        rec.last_read_hash = hash;
        rec.last_read_step = step_index;
    }

    fn noteFileEdit(self: *AgentState, allocator: std.mem.Allocator, path: []const u8, step_index: u32) !void {
        const rec = try self.fileRecord(allocator, path);
        rec.edited = true;
        rec.last_edit_step = step_index;
    }

    fn fileRecord(self: *AgentState, allocator: std.mem.Allocator, path: []const u8) !*FileRecord {
        for (self.files.items) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        try self.files.append(allocator, .{ .path = try allocator.dupe(u8, path) });
        return &self.files.items[self.files.items.len - 1];
    }

    fn setValidation(self: *AgentState, allocator: std.mem.Allocator, output: []const u8, step_index: u32) !void {
        self.validation.deinit(allocator);
        self.validation = .{
            .status = if (validationPassed(output)) .passed else .failed,
            .command = try allocator.dupe(u8, firstLineAfterPrefix(output, "run_command") orelse "run_command"),
            .step_index = step_index,
            .output = try allocator.dupe(u8, trimTail(output, 2048)),
        };
    }

    fn loadStateTextArray(self: *AgentState, allocator: std.mem.Allocator, value: std.json.Value, bucket: enum { todo, fact }) !void {
        if (value != .array) return;
        for (value.array.items) |item| {
            if (item != .object) continue;
            const text_value = item.object.get("text") orelse continue;
            if (text_value != .string) continue;
            const step_value = item.object.get("step_index") orelse null;
            const step_index: u32 = if (step_value != null and step_value.? == .integer) @intCast(step_value.?.integer) else 0;
            switch (bucket) {
                .todo => try self.appendTodo(allocator, text_value.string, step_index),
                .fact => try self.appendFact(allocator, text_value.string, step_index),
            }
        }
    }

    fn loadEntriesArray(self: *AgentState, allocator: std.mem.Allocator, value: std.json.Value) !void {
        if (value != .array) return;
        for (value.array.items) |item| {
            if (item != .object) continue;
            const kind_value = item.object.get("kind") orelse continue;
            const text_value = item.object.get("text") orelse null;
            const path_value = item.object.get("path") orelse null;
            const step_value = item.object.get("step_index") orelse null;
            const kind = if (kind_value == .string) parseEntryKind(kind_value.string) else EntryKind.decision;
            const text = if (text_value != null and text_value.? == .string) text_value.?.string else "";
            const path = if (path_value != null and path_value.? == .string) path_value.?.string else "";
            const step_index: u32 = if (step_value != null and step_value.? == .integer) @intCast(step_value.?.integer) else 0;
            try self.appendEntry(allocator, kind, step_index, path, text);
        }
    }

    fn loadFilesArray(self: *AgentState, allocator: std.mem.Allocator, value: std.json.Value) !void {
        if (value != .array) return;
        for (value.array.items) |item| {
            if (item != .object) continue;
            const path_value = item.object.get("path") orelse continue;
            if (path_value != .string) continue;
            const rec = try self.fileRecord(allocator, path_value.string);
            if (item.object.get("last_read_hash")) |hash_value| {
                if (hash_value == .integer) rec.last_read_hash = @intCast(hash_value.integer);
            }
            if (item.object.get("last_read_step")) |step_value| {
                if (step_value == .integer) rec.last_read_step = @intCast(step_value.integer);
            }
            if (item.object.get("last_edit_step")) |step_value| {
                if (step_value == .integer) rec.last_edit_step = @intCast(step_value.integer);
            }
            if (item.object.get("edited")) |edited_value| {
                if (edited_value == .bool) rec.edited = edited_value.bool;
            }
        }
    }

    fn loadValidation(self: *AgentState, allocator: std.mem.Allocator, value: std.json.Value) !void {
        if (value != .object) return;
        self.validation.deinit(allocator);
        const status_value = value.object.get("status") orelse null;
        const command_value = value.object.get("command") orelse null;
        const output_value = value.object.get("output") orelse null;
        const step_value = value.object.get("step_index") orelse null;
        self.validation = .{
            .status = if (status_value != null and status_value.? == .string) parseValidationStatus(status_value.?.string) else .unknown,
            .command = try allocator.dupe(u8, if (command_value != null and command_value.? == .string) command_value.?.string else ""),
            .output = try allocator.dupe(u8, if (output_value != null and output_value.? == .string) output_value.?.string else ""),
            .step_index = if (step_value != null and step_value.? == .integer) @intCast(step_value.?.integer) else 0,
        };
    }

    fn rebuildDerivedFromEntries(self: *AgentState, allocator: std.mem.Allocator) !void {
        for (self.entries.items) |entry| {
            switch (entry.kind) {
                .file_read => {
                    const parsed = parseReadEvidence(allocator, .{ .index = entry.step_index, .kind = "read_file", .summary = entry.text }) catch continue;
                    defer {
                        var owned = parsed;
                        owned.deinit(allocator);
                    }
                    try self.noteFileRead(allocator, parsed.path, parsed.hash, parsed.step_index);
                },
                .file_edited => if (entry.path.len > 0) try self.noteFileEdit(allocator, entry.path, entry.step_index),
                .validation => if (self.validation.step_index < entry.step_index) try self.setValidation(allocator, entry.text, entry.step_index),
                else => {},
            }
        }
    }
};

const ProposalEdit = struct {
    start: u64,
    end: u64,
    replacement: []const u8,
};

const ProposalFile = struct {
    path: []const u8,
    operation: []const u8,
    expected_hash: ?u64 = null,
    edits: []ProposalEdit = &.{},
};

const ProposalRoot = struct {
    schema_version: ?u32 = null,
    summary: ?[]const u8 = null,
    assumptions: ?[]const []const u8 = null,
    validation_tasks: ?[]const []const u8 = null,
    workspace_edit: ?struct { files: []ProposalFile = &.{} } = null,
    files: ?[]ProposalFile = null,
};

pub fn freeEvidence(allocator: std.mem.Allocator, items: []EvidenceItem) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn fromSteps(
    allocator: std.mem.Allocator,
    goal: []const u8,
    steps: []const StepInput,
    phase: Phase,
) !Snapshot {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.text);
        }
        entries.deinit(allocator);
    }

    try entries.append(allocator, .{
        .kind = .goal,
        .text = try allocator.dupe(u8, goal),
    });

    for (steps) |step| {
        const classified = classifyStep(step.kind, step.summary);
        const path = extractBacktickValue(allocator, step.summary) catch try allocator.dupe(u8, "");
        errdefer allocator.free(path);
        try entries.append(allocator, .{
            .kind = classified,
            .step_index = step.index,
            .path = path,
            .text = try allocator.dupe(u8, trimWhitespace(step.summary)),
        });
    }

    return .{
        .phase = phase,
        .goal = try allocator.dupe(u8, goal),
        .entries = try entries.toOwnedSlice(allocator),
    };
}

pub fn statsFromJson(allocator: std.mem.Allocator, json: []const u8) !Stats {
    if (json.len == 0) return .{};
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTaskLedger;
    const obj = parsed.value.object;

    var stats = Stats{};
    if (obj.get("phase")) |phase_value| {
        if (phase_value == .string) stats.phase = parsePhase(phase_value.string);
    }
    if (obj.get("entries")) |entries_value| {
        if (entries_value == .array) {
            stats.entries = entries_value.array.items.len;
            for (entries_value.array.items) |entry_value| {
                if (entry_value != .object) continue;
                const kind_value = entry_value.object.get("kind") orelse continue;
                if (kind_value != .string) continue;
                const kind = parseEntryKind(kind_value.string);
                switch (kind) {
                    .file_read => stats.file_reads += 1,
                    .file_edited => stats.file_edits += 1,
                    .blocker => stats.blockers += 1,
                    .validation => stats.validations += 1,
                    .search => stats.searches += 1,
                    else => {},
                }
            }
        }
    }
    return stats;
}

pub fn formatTimelineFromJson(allocator: std.mem.Allocator, json: []const u8, max_entries: usize) ![]const u8 {
    var snapshot = try parseSnapshotJson(allocator, json);
    defer snapshot.deinit(allocator);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.print("Task timeline\nPhase: {s}\nGoal: {s}\n", .{ @tagName(snapshot.phase), snapshot.goal });
    const start = if (snapshot.entries.len > max_entries) snapshot.entries.len - max_entries else 0;
    if (start > 0) try writer.print("- ... {d} older entrie(s)\n", .{start});
    for (snapshot.entries[start..]) |entry| {
        const path_suffix = if (entry.path.len > 0) entry.path else "";
        if (path_suffix.len > 0) {
            try writer.print("- #{d} {s} `{s}`: {s}\n", .{ entry.step_index, @tagName(entry.kind), path_suffix, trimForTimeline(entry.text) });
        } else {
            try writer.print("- #{d} {s}: {s}\n", .{ entry.step_index, @tagName(entry.kind), trimForTimeline(entry.text) });
        }
    }
    return try out.toOwnedSlice();
}

fn parseSnapshotJson(allocator: std.mem.Allocator, json: []const u8) !Snapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTaskLedger;
    const obj = parsed.value.object;
    const phase = if (obj.get("phase")) |value| if (value == .string) parsePhase(value.string) else Phase.planning else Phase.planning;
    const goal_text = if (obj.get("goal")) |value| if (value == .string) value.string else "" else "";
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.text);
        }
        entries.deinit(allocator);
    }
    if (obj.get("entries")) |entries_value| {
        if (entries_value == .array) {
            for (entries_value.array.items) |entry_value| {
                if (entry_value != .object) continue;
                const kind_value = entry_value.object.get("kind") orelse continue;
                const text_value = entry_value.object.get("text") orelse null;
                const path_value = entry_value.object.get("path") orelse null;
                const step_value = entry_value.object.get("step_index") orelse null;
                const kind = if (kind_value == .string) parseEntryKind(kind_value.string) else EntryKind.decision;
                const text = if (text_value != null and text_value.? == .string) text_value.?.string else "";
                const path = if (path_value != null and path_value.? == .string) path_value.?.string else "";
                const step_index: u32 = if (step_value != null and step_value.? == .integer) @intCast(step_value.?.integer) else 0;
                try entries.append(allocator, .{
                    .kind = kind,
                    .step_index = step_index,
                    .path = try allocator.dupe(u8, path),
                    .text = try allocator.dupe(u8, text),
                });
            }
        }
    }
    return .{
        .phase = phase,
        .goal = try allocator.dupe(u8, goal_text),
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn trimForTimeline(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    return if (trimmed.len > 160) trimmed[0..160] else trimmed;
}

pub fn workingStateFromSteps(
    allocator: std.mem.Allocator,
    goal: []const u8,
    steps: []const StepInput,
    phase: Phase,
) !WorkingState {
    var stats = Stats{ .phase = phase, .entries = steps.len + 1 };
    for (steps) |step| {
        switch (classifyStep(step.kind, step.summary)) {
            .file_read => stats.file_reads += 1,
            .file_edited => stats.file_edits += 1,
            .blocker => stats.blockers += 1,
            .validation => stats.validations += 1,
            .search => stats.searches += 1,
            else => {},
        }
    }
    return .{
        .phase = phase,
        .goal = try allocator.dupe(u8, goal),
        .entries = stats.entries,
        .evidence = try collectEvidence(allocator, steps),
        .blockers = stats.blockers,
        .validations = stats.validations,
        .edits = stats.file_edits,
    };
}

pub fn formatWorkingStateMarkdown(allocator: std.mem.Allocator, state: WorkingState) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print("Working state\nPhase: {s}\nGoal: {s}\n", .{ @tagName(state.phase), state.goal });
    try writer.print("Entries: {d} · Edits: {d} · Validations: {d} · Blockers: {d}\n", .{
        state.entries,
        state.edits,
        state.validations,
        state.blockers,
    });
    if (state.evidence.len > 0) {
        try writer.writeAll("Fresh evidence:\n");
        for (state.evidence) |item| {
            if (item.hash) |hash| {
                try writer.print("- #{d} `{s}` hash={x} lines={d}-{d}\n", .{ item.step_index, item.path, hash, item.start_line, item.end_line });
            } else {
                try writer.print("- #{d} `{s}`\n", .{ item.step_index, item.path });
            }
        }
    }
    return try out.toOwnedSlice();
}

pub fn collectEvidence(allocator: std.mem.Allocator, steps: []const StepInput) ![]EvidenceItem {
    var items: std.ArrayListUnmanaged(EvidenceItem) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    for (steps) |step| {
        if (classifyStep(step.kind, step.summary) != .file_read) continue;
        const parsed = parseReadEvidence(allocator, step) catch continue;
        if (parsed.path.len == 0) {
            var owned = parsed;
            owned.deinit(allocator);
            continue;
        }
        try items.append(allocator, parsed);
    }

    return try items.toOwnedSlice(allocator);
}

pub fn validateProposalEvidence(
    allocator: std.mem.Allocator,
    proposal_body: []const u8,
    steps: []const StepInput,
) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(ProposalRoot, allocator, proposal_body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const files = if (parsed.value.workspace_edit) |ws|
        ws.files
    else if (parsed.value.files) |legacy|
        legacy
    else
        return null;

    const evidence = try collectEvidence(allocator, steps);
    defer freeEvidence(allocator, evidence);

    for (files) |file| {
        if (!needsProposalEvidence(file.operation)) continue;
        const item = latestEvidenceForPath(evidence, file.path) orelse {
            return try std.fmt.allocPrint(
                allocator,
                "missing fresh read_file evidence for `{s}` before {s}",
                .{ file.path, file.operation },
            );
        };
        if (file.expected_hash) |expected| {
            const actual = item.hash orelse {
                return try std.fmt.allocPrint(
                    allocator,
                    "read_file evidence for `{s}` is missing hash metadata",
                    .{file.path},
                );
            };
            if (actual != expected) {
                return try std.fmt.allocPrint(
                    allocator,
                    "stale read_file evidence for `{s}`: proposal expected hash {x}, last read hash {x}",
                    .{ file.path, expected, actual },
                );
            }
        }
    }

    return null;
}

pub fn toJsonAlloc(allocator: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, snapshot, .{});
}

pub fn formatMarkdown(
    allocator: std.mem.Allocator,
    snapshot: Snapshot,
    max_entries: usize,
    max_entry_bytes: usize,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.print("Task ledger\nPhase: {s}\nGoal: {s}\n", .{ @tagName(snapshot.phase), snapshot.goal });
    if (snapshot.entries.len == 0) return try out.toOwnedSlice();

    try writer.writeAll("Recent state:\n");
    const start = if (snapshot.entries.len > max_entries) snapshot.entries.len - max_entries else 0;
    if (start > 0) try writer.print("- ... {d} older ledger entrie(s) compacted\n", .{start});
    for (snapshot.entries[start..]) |entry| {
        if (entry.kind == .goal) continue;
        const text = trimTail(entry.text, max_entry_bytes);
        if (entry.path.len > 0) {
            try writer.print("- #{d} {s} `{s}`: {s}\n", .{ entry.step_index, @tagName(entry.kind), entry.path, text });
        } else if (entry.step_index > 0) {
            try writer.print("- #{d} {s}: {s}\n", .{ entry.step_index, @tagName(entry.kind), text });
        } else {
            try writer.print("- {s}: {s}\n", .{ @tagName(entry.kind), text });
        }
    }
    return try out.toOwnedSlice();
}

pub fn classifyStep(kind: []const u8, summary: []const u8) EntryKind {
    if (containsAny(summary, &.{ "failed", "error", "could not", "invalid JSON" })) return .blocker;
    if (containsAny(kind, &.{ "replace_file_content", "write_file", "apply_proposal", "propose", "Write" })) return .file_edited;
    if (looksLikeReadFileSummary(summary)) return .file_read;
    if (looksLikeSearchSummary(summary)) return .search;
    if (containsAny(kind, &.{ "read_file", "Read", "file" })) return .file_read;
    if (containsAny(kind, &.{ "grep", "search", "list_tree", "Tree" })) return .search;
    if (containsAny(kind, &.{ "run_command", "Run" })) return .command;
    if (containsAny(kind, &.{ "validate", "test", "diagnostic" })) return .validation;
    return .decision;
}

fn parsePhase(value: []const u8) Phase {
    inline for (@typeInfo(Phase).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return .planning;
}

fn parseEntryKind(value: []const u8) EntryKind {
    inline for (@typeInfo(EntryKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return .decision;
}

fn parseValidationStatus(value: []const u8) ValidationStatus {
    inline for (@typeInfo(ValidationStatus).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return .unknown;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn looksLikeValidationResult(summary: []const u8) bool {
    return std.mem.startsWith(u8, summary, "run_command exit ") or
        std.mem.indexOf(u8, summary, "validation [") != null or
        containsAny(summary, &.{ "zig build", "zig test", "npm test", "pytest", "cargo test" });
}

fn validationPassed(summary: []const u8) bool {
    return std.mem.startsWith(u8, summary, "run_command exit 0") or
        std.mem.indexOf(u8, summary, "validation [pass]") != null or
        std.mem.indexOf(u8, summary, "all checks passed") != null;
}

fn firstLineAfterPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, prefix) orelse return null;
    var end = start;
    while (end < text.len and text[end] != '\n' and text[end] != '\r') : (end += 1) {}
    return text[start..end];
}

fn pathFromEditArgs(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    _ = allocator;
    _ = text;
    return "";
}

fn looksLikeReadFileSummary(summary: []const u8) bool {
    return std.mem.startsWith(u8, summary, "File `") and std.mem.indexOf(u8, summary, " hash=") != null;
}

fn looksLikeSearchSummary(summary: []const u8) bool {
    return std.mem.startsWith(u8, summary, "Tree `") or
        std.mem.startsWith(u8, summary, "Grep `") or
        std.mem.startsWith(u8, summary, "Search `");
}

fn parseReadEvidence(allocator: std.mem.Allocator, step: StepInput) !EvidenceItem {
    const path = try extractBacktickValue(allocator, step.summary);
    errdefer allocator.free(path);
    const lines = parseLineRange(step.summary);
    return .{
        .path = path,
        .hash = parseHexField(step.summary, "hash="),
        .start_line = lines.start,
        .end_line = lines.end,
        .step_index = step.index,
    };
}

fn latestEvidenceForPath(evidence: []const EvidenceItem, path: []const u8) ?EvidenceItem {
    var index = evidence.len;
    while (index > 0) : (index -= 1) {
        const item = evidence[index - 1];
        if (std.mem.eql(u8, item.path, path)) return item;
    }
    return null;
}

fn needsProposalEvidence(operation: []const u8) bool {
    return std.mem.eql(u8, operation, "modify") or std.mem.eql(u8, operation, "delete");
}

fn parseHexField(text: []const u8, key: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, text, key) orelse return null;
    const value_start = start + key.len;
    var value_end = value_start;
    while (value_end < text.len and std.ascii.isHex(text[value_end])) : (value_end += 1) {}
    if (value_end == value_start) return null;
    return std.fmt.parseInt(u64, text[value_start..value_end], 16) catch null;
}

const LineRange = struct { start: usize = 0, end: usize = 0 };

fn parseLineRange(text: []const u8) LineRange {
    const start = std.mem.indexOf(u8, text, "lines=") orelse return .{};
    const value_start = start + "lines=".len;
    var dash = value_start;
    while (dash < text.len and std.ascii.isDigit(text[dash])) : (dash += 1) {}
    if (dash == value_start or dash >= text.len or text[dash] != '-') return .{};
    var end = dash + 1;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == dash + 1) return .{};
    return .{
        .start = std.fmt.parseInt(usize, text[value_start..dash], 10) catch 0,
        .end = std.fmt.parseInt(usize, text[dash + 1 .. end], 10) catch 0,
    };
}

fn extractBacktickValue(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const first = std.mem.indexOfScalar(u8, text, '`') orelse return allocator.dupe(u8, "");
    const rest = text[first + 1 ..];
    const second_rel = std.mem.indexOfScalar(u8, rest, '`') orelse return allocator.dupe(u8, "");
    return allocator.dupe(u8, rest[0..second_rel]);
}

fn trimWhitespace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

pub fn trimTail(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    return text[text.len - max_bytes ..];
}

test "ledger classifies file reads and writes" {
    const allocator = std.testing.allocator;
    const steps = [_]StepInput{
        .{ .index = 1, .kind = "read_file", .summary = "Read `src/main.zig` lines 1-40" },
        .{ .index = 2, .kind = "replace_file_content", .summary = "Write `src/main.zig`: add resume support" },
    };
    var snapshot = try fromSteps(allocator, "fix resume", &steps, .editing);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(EntryKind.goal, snapshot.entries[0].kind);
    try std.testing.expectEqual(EntryKind.file_read, snapshot.entries[1].kind);
    try std.testing.expectEqual(EntryKind.file_edited, snapshot.entries[2].kind);
    try std.testing.expectEqualStrings("src/main.zig", snapshot.entries[1].path);
}

test "ledger markdown compacts older entries" {
    const allocator = std.testing.allocator;
    const steps = [_]StepInput{
        .{ .index = 1, .kind = "grep", .summary = "Grep `agent` in `.`: 10 hit(s)" },
        .{ .index = 2, .kind = "read_file", .summary = "Read `src/a.zig`" },
        .{ .index = 3, .kind = "read_file", .summary = "Read `src/b.zig`" },
    };
    var snapshot = try fromSteps(allocator, "audit agent", &steps, .gathering);
    defer snapshot.deinit(allocator);
    const text = try formatMarkdown(allocator, snapshot, 2, 64);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "older ledger") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/b.zig") != null);
}

test "ledger stats parse persisted checkpoint json" {
    const allocator = std.testing.allocator;
    const json =
        \\{"phase":"repairing","goal":"fix","entries":[
        \\{"kind":"goal","step_index":0,"path":"","text":"fix"},
        \\{"kind":"file_read","step_index":1,"path":"src/a.zig","text":"Read"},
        \\{"kind":"validation","step_index":2,"path":"","text":"zig build failed"},
        \\{"kind":"blocker","step_index":3,"path":"","text":"Tool failed"}
        \\]}
    ;
    const stats = try statsFromJson(allocator, json);
    try std.testing.expectEqual(Phase.repairing, stats.phase);
    try std.testing.expectEqual(@as(usize, 1), stats.file_reads);
    try std.testing.expectEqual(@as(usize, 1), stats.validations);
    try std.testing.expect(stats.needsFreshEvidence());
}

test "ledger timeline renders compact task state" {
    const allocator = std.testing.allocator;
    const json =
        \\{"phase":"editing","goal":"fix ui","entries":[
        \\{"kind":"goal","step_index":0,"path":"","text":"fix ui"},
        \\{"kind":"file_read","step_index":1,"path":"src/ui.zig","text":"Read `src/ui.zig` lines 1-40"},
        \\{"kind":"file_edited","step_index":2,"path":"src/ui.zig","text":"Write `src/ui.zig`: adjust panel"}
        \\]}
    ;
    const timeline = try formatTimelineFromJson(allocator, json, 8);
    defer allocator.free(timeline);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "Task timeline") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "file_edited") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeline, "src/ui.zig") != null);
}

test "ledger collects read evidence hash and line range" {
    const allocator = std.testing.allocator;
    const steps = [_]StepInput{
        .{ .index = 4, .kind = "read_file", .summary = "File `src/main.zig` hash=7eec5e9b54771a5f bytes=1951 lines=1-400\nconst x = 1;" },
    };
    const evidence = try collectEvidence(allocator, &steps);
    defer freeEvidence(allocator, evidence);

    try std.testing.expectEqual(@as(usize, 1), evidence.len);
    try std.testing.expectEqualStrings("src/main.zig", evidence[0].path);
    try std.testing.expectEqual(@as(?u64, 0x7eec5e9b54771a5f), evidence[0].hash);
    try std.testing.expectEqual(@as(usize, 1), evidence[0].start_line);
    try std.testing.expectEqual(@as(usize, 400), evidence[0].end_line);
}

test "proposal evidence rejects modify without fresh read" {
    const allocator = std.testing.allocator;
    const proposal =
        \\{"schema_version":1,"workspace_edit":{"files":[{"path":"src/main.zig","operation":"modify","expected_hash":1,"edits":[{"start":0,"end":0,"replacement":"// hi\n"}]}]}}
    ;
    const issue = try validateProposalEvidence(allocator, proposal, &.{});
    defer if (issue) |text| allocator.free(text);
    try std.testing.expect(issue != null);
    try std.testing.expect(std.mem.indexOf(u8, issue.?, "missing fresh read_file evidence") != null);
}

test "proposal evidence accepts matching read hash" {
    const allocator = std.testing.allocator;
    const steps = [_]StepInput{
        .{ .index = 1, .kind = "read_file", .summary = "File `src/main.zig` hash=1 bytes=12 lines=1-3\n" },
    };
    const proposal =
        \\{"schema_version":1,"workspace_edit":{"files":[{"path":"src/main.zig","operation":"modify","expected_hash":1,"edits":[{"start":0,"end":0,"replacement":"// hi\n"}]}]}}
    ;
    const issue = try validateProposalEvidence(allocator, proposal, &steps);
    try std.testing.expect(issue == null);
}

test "proposal evidence rejects stale read hash" {
    const allocator = std.testing.allocator;
    const steps = [_]StepInput{
        .{ .index = 1, .kind = "read_file", .summary = "File `src/main.zig` hash=1 bytes=12 lines=1-3\n" },
    };
    const proposal =
        \\{"schema_version":1,"workspace_edit":{"files":[{"path":"src/main.zig","operation":"modify","expected_hash":2,"edits":[{"start":0,"end":0,"replacement":"// hi\n"}]}]}}
    ;
    const issue = try validateProposalEvidence(allocator, proposal, &steps);
    defer if (issue) |text| allocator.free(text);
    try std.testing.expect(issue != null);
    try std.testing.expect(std.mem.indexOf(u8, issue.?, "stale read_file evidence") != null);
}

test "working state includes evidence and counters" {
    const allocator = std.testing.allocator;
    const steps = [_]StepInput{
        .{ .index = 1, .kind = "read_file", .summary = "File `src/main.zig` hash=1 bytes=12 lines=1-3\n" },
        .{ .index = 2, .kind = "replace_file_content", .summary = "Write `src/main.zig`" },
    };
    var state = try workingStateFromSteps(allocator, "fix", &steps, .editing);
    defer state.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), state.evidence.len);
    try std.testing.expectEqual(@as(usize, 1), state.edits);
    const md = try formatWorkingStateMarkdown(allocator, state);
    defer allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "Fresh evidence") != null);
}

test "agent state serializes structured files facts and validation" {
    const allocator = std.testing.allocator;
    var state = try AgentState.init(allocator, "fix layout");
    defer state.deinit(allocator);

    try state.recordToolResult(allocator, 1, "read_file", "File `src/ui.zig` hash=2a bytes=4 lines=1-2\n");
    try state.recordToolResult(allocator, 2, "replace_file_content", "Write `src/ui.zig` hash=2a blocks=1: adjust layout");
    try state.recordToolResult(allocator, 3, "run_command", "run_command exit 0\nzig build test");

    const json = try state.toJsonAlloc(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"facts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"validation\"") != null);
    try std.testing.expect(state.validationAfterLastEdit());
}

test "agent state final gate requires validation after edits" {
    const allocator = std.testing.allocator;
    var state = try AgentState.init(allocator, "fix bug");
    defer state.deinit(allocator);

    try state.recordToolResult(allocator, 1, "read_file", "File `src/main.zig` hash=1 bytes=4 lines=1-1\n");
    try state.recordToolResult(allocator, 2, "replace_file_content", "Write `src/main.zig` hash=1 blocks=1");

    const blocked = try state.finalGateIssue(allocator, "Done.");
    try std.testing.expect(blocked != null);
    defer allocator.free(blocked.?);
    try std.testing.expect(std.mem.indexOf(u8, blocked.?, "no validation command") != null);

    try state.recordToolResult(allocator, 3, "run_command", "run_command exit 0\nzig build");
    const allowed = try state.finalGateIssue(allocator, "Done. Validation passed.");
    try std.testing.expect(allowed == null);
}

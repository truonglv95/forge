const std = @import("std");
const workspace = @import("forge-workspace");
const atomic = workspace.atomic;

pub const specs_subdir = "specs";
pub const specs_dir = specs_subdir;

pub const SpecError = error{
    WorkspaceFailed,
    SpecNotFound,
};

pub const SpecStatus = enum {
    pending,
    approved,
    rejected,
    implemented,

    pub fn label(self: SpecStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .approved => "approved",
            .rejected => "rejected",
            .implemented => "implemented",
        };
    }

    pub fn parse(s: []const u8) ?SpecStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "approved")) return .approved;
        if (std.mem.eql(u8, s, "rejected")) return .rejected;
        if (std.mem.eql(u8, s, "implemented")) return .implemented;
        return null;
    }
};

pub const SpecInfo = struct {
    run_id: []const u8,
    status: SpecStatus,
    intent: []const u8 = "",
    has_requirements: bool,
    has_design: bool,
    has_tasks: bool,
    has_plan: bool,
};

pub const TraceEntry = struct {
    commit: []const u8,
    subject: []const u8,
    timestamp_ms: i64,
};

pub fn persistFromPlan(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    run_id: []const u8,
    plan_markdown: []const u8,
    intent: []const u8,
) SpecError!void {
    workspace.history.ensureLayout(allocator, io, root) catch return error.WorkspaceFailed;
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const specs_abs = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ session_dir, specs_subdir }) catch return error.WorkspaceFailed;
    workspace.global_store.mkdirAllAbsolute(specs_abs) catch {};
    var spec_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const spec_root_abs = std.fmt.bufPrint(&spec_root_buf, "{s}/{s}", .{ specs_abs, run_id }) catch return error.WorkspaceFailed;
    workspace.global_store.mkdirAllAbsolute(spec_root_abs) catch {};

    const sections = splitSections(plan_markdown);
    const requirements = sections.get("requirements") orelse sections.get("goal") orelse intent;
    const design = sections.get("design") orelse sections.get("approach") orelse sections.get("risks") orelse "See plan.md for design notes.";
    const tasks = sections.get("tasks") orelse sections.get("steps") orelse sections.get("validation") orelse "1. Implement changes\n2. Run `zig build test`";

    try writeSpecFileAbs(io, spec_root_abs, "requirements.md", requirements, intent);
    try writeSpecFileAbs(io, spec_root_abs, "design.md", design, "Design notes derived from the implementation plan.");
    try writeSpecFileAbs(io, spec_root_abs, "tasks.md", tasks, "Implementation tasks.");

    var plan_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const plan_abs = std.fmt.bufPrint(&plan_path_buf, "{s}/plan.md", .{spec_root_abs}) catch return error.WorkspaceFailed;
    workspace.global_store.replaceAbsoluteFile(io, plan_abs, plan_markdown) catch return error.WorkspaceFailed;
    writeStatusAbs(io, session_dir, run_id, "pending") catch {};
}

pub fn createSpec(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    run_id: []const u8,
    intent: []const u8,
    requirements_body: ?[]const u8,
    design_body: ?[]const u8,
    tasks_body: ?[]const u8,
) SpecError!void {
    workspace.history.ensureLayout(allocator, io, root) catch return error.WorkspaceFailed;
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const specs_abs = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ session_dir, specs_subdir }) catch return error.WorkspaceFailed;
    workspace.global_store.mkdirAllAbsolute(specs_abs) catch {};
    var spec_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const spec_root_abs = std.fmt.bufPrint(&spec_root_buf, "{s}/{s}", .{ specs_abs, run_id }) catch return error.WorkspaceFailed;
    workspace.global_store.mkdirAllAbsolute(spec_root_abs) catch {};

    const fallback_req = std.fmt.allocPrint(allocator, "# Requirements\n\n{s}\n\n(pending - fill in via `forge spec edit {s}`)\n", .{ intent, run_id }) catch return error.WorkspaceFailed;
    defer allocator.free(fallback_req);
    try writeSpecFileAbs(io, spec_root_abs, "requirements.md", requirements_body orelse fallback_req, intent);
    try writeSpecFileAbs(io, spec_root_abs, "design.md", design_body orelse "# Design\n\n(pending)\n", "Design notes");
    try writeSpecFileAbs(io, spec_root_abs, "tasks.md", tasks_body orelse "# Tasks\n\n1. (pending)\n", "Implementation tasks");
    writeStatusAbs(io, session_dir, run_id, "pending") catch {};
}

pub fn editSection(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    run_id: []const u8,
    section: []const u8,
    body: []const u8,
) SpecError!void {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);

    const filename = if (std.mem.eql(u8, section, "requirements") or std.mem.eql(u8, section, "req"))
        "requirements.md"
    else if (std.mem.eql(u8, section, "design"))
        "design.md"
    else if (std.mem.eql(u8, section, "tasks"))
        "tasks.md"
    else
        return error.SpecNotFound;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/{s}", .{ session_dir, specs_subdir, run_id, filename }) catch return error.WorkspaceFailed;
    workspace.global_store.replaceAbsoluteFile(io, abs, body) catch return error.WorkspaceFailed;
}

pub fn readSection(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    run_id: []const u8,
    section: []const u8,
) SpecError![]u8 {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);

    const filename = if (std.mem.eql(u8, section, "requirements") or std.mem.eql(u8, section, "req"))
        "requirements.md"
    else if (std.mem.eql(u8, section, "design"))
        "design.md"
    else if (std.mem.eql(u8, section, "tasks"))
        "tasks.md"
    else if (std.mem.eql(u8, section, "plan"))
        "plan.md"
    else
        return error.SpecNotFound;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/{s}", .{ session_dir, specs_subdir, run_id, filename }) catch return error.WorkspaceFailed;
    return workspace.global_store.readAbsoluteFile(allocator, io, abs) catch return error.SpecNotFound;
}

pub fn listSpecs(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
) SpecError![]SpecInfo {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);

    var specs_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const specs_abs = std.fmt.bufPrint(&specs_dir_buf, "{s}/{s}", .{ session_dir, specs_subdir }) catch return error.WorkspaceFailed;

    var dir = std.Io.Dir.openDirAbsolute(io, specs_abs, .{ .iterate = true }) catch return error.WorkspaceFailed;
    defer dir.close(io);

    var iter = dir.iterate();
    var infos: std.ArrayList(SpecInfo) = .empty;
    errdefer {
        for (infos.items) |item| allocator.free(item.run_id);
        infos.deinit(allocator);
    }

    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const run_id = allocator.dupe(u8, entry.name) catch return error.WorkspaceFailed;

        var has_req = false;
        var has_design = false;
        var has_tasks = false;
        var has_plan = false;
        {
            var probe = dir.openDir(io, entry.name, .{}) catch continue;
            defer probe.close(io);
            if (probe.statFile(io, "requirements.md", .{})) |_| has_req = true else |_| {}
            if (probe.statFile(io, "design.md", .{})) |_| has_design = true else |_| {}
            if (probe.statFile(io, "tasks.md", .{})) |_| has_tasks = true else |_| {}
            if (probe.statFile(io, "plan.md", .{})) |_| has_plan = true else |_| {}
        }

        const status_str = readStatusStringAbs(io, session_dir, run_id) catch "pending";
        const status_enum: SpecStatus = SpecStatus.parse(status_str) orelse .pending;

        infos.append(allocator, .{
            .run_id = run_id,
            .status = status_enum,
            .has_requirements = has_req,
            .has_design = has_design,
            .has_tasks = has_tasks,
            .has_plan = has_plan,
        }) catch return error.WorkspaceFailed;
    }

    return infos.toOwnedSlice(allocator) catch return error.WorkspaceFailed;
}

pub fn freeSpecList(allocator: std.mem.Allocator, infos: []SpecInfo) void {
    for (infos) |item| allocator.free(item.run_id);
    allocator.free(infos);
}

pub fn approve(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8) SpecError!void {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);
    writeStatusAbs(io, session_dir, run_id, "approved") catch return error.WorkspaceFailed;
}

pub fn reject(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8) SpecError!void {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);
    writeStatusAbs(io, session_dir, run_id, "rejected") catch return error.WorkspaceFailed;
}

pub fn markImplemented(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8) SpecError!void {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);
    writeStatusAbs(io, session_dir, run_id, "implemented") catch return error.WorkspaceFailed;
}

pub fn readStatus(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8) ?SpecStatus {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return null;
    defer allocator.free(session_dir);
    const status_str = readStatusStringAbs(io, session_dir, run_id) catch return null;
    return SpecStatus.parse(status_str);
}

pub fn isApproved(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8) bool {
    return readStatus(allocator, io, root, run_id) == .approved;
}

pub fn recordCommit(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    run_id: []const u8,
    commit_hash: []const u8,
    commit_subject: []const u8,
) SpecError!void {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const trace_abs = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/trace.json", .{ session_dir, specs_subdir, run_id }) catch return error.WorkspaceFailed;

    const existing = workspace.global_store.readAbsoluteFile(allocator, io, trace_abs) catch "";
    defer if (existing.len > 0) allocator.free(existing);

    var entries: std.ArrayList(TraceEntry) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.commit);
            allocator.free(e.subject);
        }
        entries.deinit(allocator);
    }

    if (existing.len > 0) {
        const Arr = []const TraceEntry;
        var parsed = std.json.parseFromSlice(Arr, allocator, existing, .{ .ignore_unknown_fields = true }) catch null;
        defer if (parsed) |*p| p.deinit();
        if (parsed) |p| {
            for (p.value) |e| {
                entries.append(allocator, .{
                    .commit = allocator.dupe(u8, e.commit) catch return error.WorkspaceFailed,
                    .subject = allocator.dupe(u8, e.subject) catch return error.WorkspaceFailed,
                    .timestamp_ms = e.timestamp_ms,
                }) catch return error.WorkspaceFailed;
            }
        }
    }

    for (entries.items) |e| {
        if (std.mem.eql(u8, e.commit, commit_hash)) return;
    }

    entries.append(allocator, .{
        .commit = allocator.dupe(u8, commit_hash) catch return error.WorkspaceFailed,
        .subject = allocator.dupe(u8, commit_subject) catch return error.WorkspaceFailed,
        .timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    }) catch return error.WorkspaceFailed;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    buf.appendSlice(allocator, "[") catch return error.WorkspaceFailed;
    for (entries.items, 0..) |e, i| {
        if (i > 0) buf.appendSlice(allocator, ",") catch return error.WorkspaceFailed;
        const line = std.fmt.allocPrint(allocator, "{{\"commit\":\"{s}\",\"subject\":\"{s}\",\"timestamp_ms\":{d}}}", .{ e.commit, e.subject, e.timestamp_ms }) catch return error.WorkspaceFailed;
        defer allocator.free(line);
        buf.appendSlice(allocator, line) catch return error.WorkspaceFailed;
    }
    buf.appendSlice(allocator, "]\n") catch return error.WorkspaceFailed;

    workspace.global_store.replaceAbsoluteFile(io, trace_abs, buf.items) catch return error.WorkspaceFailed;
}

pub fn readTrace(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    run_id: []const u8,
) SpecError![]TraceEntry {
    const session_dir = workspace.global_store.getSessionDir(allocator, io, root) catch return error.WorkspaceFailed;
    defer allocator.free(session_dir);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const trace_abs = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/trace.json", .{ session_dir, specs_subdir, run_id }) catch return error.WorkspaceFailed;
    const content = workspace.global_store.readAbsoluteFile(allocator, io, trace_abs) catch {
        return allocator.alloc(TraceEntry, 0) catch return error.WorkspaceFailed;
    };
    defer allocator.free(content);

    const Arr = []const TraceEntry;
    var parsed = std.json.parseFromSlice(Arr, allocator, content, .{ .ignore_unknown_fields = true }) catch {
        return allocator.alloc(TraceEntry, 0) catch return error.WorkspaceFailed;
    };
    defer parsed.deinit();

    const out = allocator.alloc(TraceEntry, parsed.value.len) catch return error.WorkspaceFailed;
    for (parsed.value, 0..) |e, i| {
        out[i] = .{
            .commit = allocator.dupe(u8, e.commit) catch return error.WorkspaceFailed,
            .subject = allocator.dupe(u8, e.subject) catch return error.WorkspaceFailed,
            .timestamp_ms = e.timestamp_ms,
        };
    }
    return out;
}

pub fn freeTrace(allocator: std.mem.Allocator, entries: []TraceEntry) void {
    for (entries) |e| {
        allocator.free(e.commit);
        allocator.free(e.subject);
    }
    allocator.free(entries);
}

pub fn specRootPath(run_id: []const u8, buffer: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ specs_subdir, run_id }) catch null;
}

fn writeStatusAbs(io: std.Io, session_dir: []const u8, run_id: []const u8, status: []const u8) SpecError!void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const status_abs = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/status.json", .{ session_dir, specs_subdir, run_id }) catch return error.WorkspaceFailed;
    var body_buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"status\":\"{s}\"}}\n", .{status}) catch return error.WorkspaceFailed;
    workspace.global_store.replaceAbsoluteFile(io, status_abs, body) catch return error.WorkspaceFailed;
}

fn readStatusAbs(io: std.Io, session_dir: []const u8, run_id: []const u8) SpecError!bool {
    return readStatusStringAbs(io, session_dir, run_id) catch false;
}

fn readStatusStringAbs(io: std.Io, session_dir: []const u8, run_id: []const u8) SpecError![]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const status_abs = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/status.json", .{ session_dir, specs_subdir, run_id }) catch return error.WorkspaceFailed;
    const content = workspace.global_store.readAbsoluteFile(std.heap.page_allocator, io, status_abs) catch return error.WorkspaceFailed;
    defer std.heap.page_allocator.free(content);
    const Json = struct { status: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Json, std.heap.page_allocator, content, .{ .ignore_unknown_fields = true }) catch return error.WorkspaceFailed;
    defer parsed.deinit();
    const status = parsed.value.status orelse "pending";
    const Static = struct {
        var buf: [32]u8 = undefined;
    };
    const len = @min(status.len, Static.buf.len);
    @memcpy(Static.buf[0..len], status[0..len]);
    return Static.buf[0..len];
}

fn writeSpecFileAbs(io: std.Io, spec_root_abs: []const u8, name: []const u8, body: []const u8, fallback_title: []const u8) SpecError!void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ spec_root_abs, name }) catch return error.WorkspaceFailed;

    var content_buf: [4096]u8 = undefined;
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    const content = if (trimmed.len > 0) trimmed else blk: {
        break :blk std.fmt.bufPrint(&content_buf, "# {s}\n\n(pending)\n", .{fallback_title}) catch return error.WorkspaceFailed;
    };

    workspace.global_store.replaceAbsoluteFile(io, abs, content) catch return error.WorkspaceFailed;
}

const SectionMap = struct {
    items: [8]struct { key_buf: [48]u8, key_len: usize, body: []const u8 },
    count: usize = 0,

    fn get(self: *const SectionMap, name: []const u8) ?[]const u8 {
        var key_buf: [48]u8 = undefined;
        const key_len = normalizeKey(name, &key_buf);
        for (self.items[0..self.count]) |item| {
            if (item.key_len == key_len and std.mem.eql(u8, item.key_buf[0..item.key_len], key_buf[0..key_len]))
                return item.body;
        }
        return null;
    }

    fn put(self: *SectionMap, heading: []const u8, body: []const u8) void {
        if (self.count >= self.items.len) return;
        var key_buf: [48]u8 = undefined;
        const key_len = normalizeKey(heading, &key_buf);
        if (key_len == 0) return;
        self.items[self.count] = .{
            .key_buf = key_buf,
            .key_len = key_len,
            .body = body,
        };
        self.count += 1;
    }
};

fn splitSections(markdown: []const u8) SectionMap {
    var map = SectionMap{
        .items = undefined,
        .count = 0,
    };
    var current_heading: ?[]const u8 = null;
    var body_start: usize = 0;

    var offset: usize = 0;
    while (offset < markdown.len) {
        const line_end = std.mem.indexOfScalar(u8, markdown[offset..], '\n') orelse markdown.len - offset;
        const line = markdown[offset .. offset + line_end];
        var heading_marks: usize = 0;
        while (heading_marks < line.len and line[heading_marks] == '#') heading_marks += 1;
        const is_heading = heading_marks > 0 and heading_marks < line.len and line[heading_marks] == ' ';
        if (is_heading) {
            if (current_heading) |heading| {
                const body = std.mem.trim(u8, markdown[body_start..offset], &std.ascii.whitespace);
                map.put(heading, body);
            }
            current_heading = std.mem.trim(u8, line[heading_marks + 1 ..], &std.ascii.whitespace);
            body_start = offset + line_end + 1;
        }
        offset += line_end + 1;
    }
    if (current_heading) |heading| {
        const body = std.mem.trim(u8, markdown[body_start..], &std.ascii.whitespace);
        map.put(heading, body);
    }
    return map;
}

fn normalizeKey(heading: []const u8, out: *[48]u8) usize {
    var len: usize = 0;
    var lower_buf: [128]u8 = undefined;
    const capped = if (heading.len > lower_buf.len) heading[0..lower_buf.len] else heading;
    const lower = std.ascii.lowerString(&lower_buf, capped);
    for (lower) |c| {
        if (len >= out.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            out[len] = c;
            len += 1;
        }
    }
    return len;
}

test "splitSections extracts goal and steps" {
    const md =
        \\# Goal
        \\Fix the bug
        \\
        \\## Steps
        \\1. Patch file
    ;
    const sections = splitSections(md);
    try std.testing.expect(sections.get("goal") != null);
    try std.testing.expect(sections.get("steps") != null);
}

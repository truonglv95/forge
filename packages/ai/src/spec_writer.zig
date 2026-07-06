const std = @import("std");
const workspace = @import("forge-workspace");
const atomic = workspace.atomic;

pub const specs_dir = ".forge/specs";

pub const SpecError = error{
    WorkspaceFailed,
};

/// Splits a plan markdown document into formal spec files under `.forge/specs/{run_id}/`.
pub fn persistFromPlan(
    io: std.Io,
    root: workspace.WorkspaceRoot,
    run_id: []const u8,
    plan_markdown: []const u8,
    intent: []const u8,
) SpecError!void {
    workspace.history.ensureLayout(io, root) catch return error.WorkspaceFailed;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const spec_root = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ specs_dir, run_id }) catch return error.WorkspaceFailed;
    root.dir.createDirPath(io, specs_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.WorkspaceFailed,
    };
    root.dir.createDirPath(io, spec_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.WorkspaceFailed,
    };

    const sections = splitSections(plan_markdown);
    const requirements = sections.get("requirements") orelse sections.get("goal") orelse intent;
    const design = sections.get("design") orelse sections.get("approach") orelse sections.get("risks") orelse "See plan.md for design notes.";
    const tasks = sections.get("tasks") orelse sections.get("steps") orelse sections.get("validation") orelse "1. Implement changes\n2. Run `zig build test`";

    try writeSpecFile(io, root, spec_root, "requirements.md", requirements, intent);
    try writeSpecFile(io, root, spec_root, "design.md", design, "Design notes derived from the implementation plan.");
    try writeSpecFile(io, root, spec_root, "tasks.md", tasks, "Implementation tasks.");

    var plan_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const plan_rel = std.fmt.bufPrint(&plan_path_buf, "{s}/plan.md", .{spec_root}) catch return error.WorkspaceFailed;
    atomic.replaceFile(io, root, workspace.WorkspacePath.parse(plan_rel) catch return error.WorkspaceFailed, plan_markdown) catch return error.WorkspaceFailed;

    writeStatus(io, root, run_id, "pending") catch {};
}

pub fn approve(io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8) SpecError!void {
    writeStatus(io, root, run_id, "approved") catch return error.WorkspaceFailed;
}

pub fn isApproved(io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8) bool {
    return readStatus(io, root, run_id) catch return false;
}

pub fn specRootPath(run_id: []const u8, buffer: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ specs_dir, run_id }) catch null;
}

fn writeStatus(io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8, status: []const u8) SpecError!void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const spec_root = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ specs_dir, run_id }) catch return error.WorkspaceFailed;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "{s}/status.json", .{spec_root}) catch return error.WorkspaceFailed;
    var body_buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"status\":\"{s}\"}}\n", .{status}) catch return error.WorkspaceFailed;
    atomic.replaceFile(io, root, workspace.WorkspacePath.parse(rel) catch return error.WorkspaceFailed, body) catch return error.WorkspaceFailed;
}

fn readStatus(io: std.Io, root: workspace.WorkspaceRoot, run_id: []const u8) SpecError!bool {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const spec_root = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ specs_dir, run_id }) catch return error.WorkspaceFailed;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "{s}/status.json", .{spec_root}) catch return error.WorkspaceFailed;
    var snap = workspace.FileSnapshot.read(std.heap.page_allocator, io, root, workspace.WorkspacePath.parse(rel) catch return error.WorkspaceFailed) catch return error.WorkspaceFailed;
    defer snap.deinit();
    const Json = struct { status: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Json, std.heap.page_allocator, snap.content, .{ .ignore_unknown_fields = true }) catch return error.WorkspaceFailed;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.status orelse "", "approved");
}

fn writeSpecFile(io: std.Io, root: workspace.WorkspaceRoot, spec_root: []const u8, name: []const u8, body: []const u8, fallback_title: []const u8) SpecError!void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ spec_root, name }) catch return error.WorkspaceFailed;

    var content_buf: [4096]u8 = undefined;
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    const content = if (trimmed.len > 0) trimmed else blk: {
        break :blk std.fmt.bufPrint(&content_buf, "# {s}\n\n(pending)\n", .{fallback_title}) catch return error.WorkspaceFailed;
    };

    atomic.replaceFile(io, root, workspace.WorkspacePath.parse(rel) catch return error.WorkspaceFailed, content) catch return error.WorkspaceFailed;
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

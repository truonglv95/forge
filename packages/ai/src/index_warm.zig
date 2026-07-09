const std = @import("std");
const workspace = @import("forge-workspace");
const sync = @import("forge-util").sync;
const codebase_search = @import("codebase_search.zig");

pub const Status = enum {
    missing,
    stale,
    building,
    ready,
};

pub const BuildReport = struct {
    status: Status,
    chunk_count: u32 = 0,
    file_count: u32 = 0,
    rebuilt: bool = false,
};

const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    environ_map: ?*const std.process.Environ.Map,
};

var state_mutex: sync.Mutex = .{};
var building_paths: ?std.StringHashMap(void) = null;

fn initState() void {
    state_mutex.lock();
    defer state_mutex.unlock();
    if (building_paths == null) {
        building_paths = std.StringHashMap(void).init(std.heap.page_allocator);
    }
}

fn pathIsBuilding(workspace_path: []const u8) bool {
    initState();
    state_mutex.lock();
    defer state_mutex.unlock();
    return building_paths.?.contains(workspace_path);
}

fn markBuilding(workspace_path: []const u8) bool {
    initState();
    state_mutex.lock();
    defer state_mutex.unlock();
    const owned = std.heap.page_allocator.dupe(u8, workspace_path) catch return false;
    const gop = building_paths.?.getOrPut(owned) catch {
        std.heap.page_allocator.free(owned);
        return false;
    };
    if (gop.found_existing) {
        std.heap.page_allocator.free(owned);
        return false;
    }
    return true;
}

fn clearBuilding(workspace_path: []const u8) void {
    state_mutex.lock();
    defer state_mutex.unlock();
    if (building_paths) |*paths| {
        if (paths.fetchRemove(workspace_path)) |entry| {
            std.heap.page_allocator.free(entry.key);
        }
    }
}

pub fn skipAutoWarm(environ_map: ?*const std.process.Environ.Map) bool {
    if (@import("builtin").is_test) return true;
    if (environ_map) |map| {
        if (map.get("FORGE_SKIP_INDEX")) |value| {
            return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");
        }
    }
    return false;
}

pub fn workspaceStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    workspace_path: []const u8,
) !Status {
    if (pathIsBuilding(workspace_path)) return .building;
    _ = readManifestCounts(allocator, io, root) catch return .missing;
    const needs = try workspace.codebase_index.needsRebuild(allocator, io, root);
    if (needs) return .stale;
    return .ready;
}

pub fn buildForeground(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    environ_map: ?*const std.process.Environ.Map,
) !BuildReport {
    const before = readManifestCounts(allocator, io, root) catch null;
    const needs = workspace.codebase_index.needsRebuild(allocator, io, root) catch true;

    try codebase_search.ensureIndex(allocator, io, root, .{
        .prefer_gemini = environ_map != null,
        .environ_map = environ_map,
        .allow_rebuild = true,
    });

    const after = readManifestCounts(allocator, io, root) catch null;
    return .{
        .status = .ready,
        .chunk_count = if (after) |counts| counts.chunk_count else 0,
        .file_count = if (after) |counts| counts.file_count else 0,
        .rebuilt = needs or before == null,
    };
}

/// Cursor-style background warm: rebuild only when stale/missing. Deduped per path.
pub fn scheduleBackground(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    root: workspace.WorkspaceRoot,
    workspace_path: []const u8,
) void {
    if (skipAutoWarm(environ_map)) return;
    if (pathIsBuilding(workspace_path)) return;

    const needs = workspace.codebase_index.needsRebuild(allocator, io, root) catch {
        spawnBackground(allocator, io, environ_map, workspace_path);
        return;
    };
    if (!needs) return;

    spawnBackground(allocator, io, environ_map, workspace_path);
}

fn spawnBackground(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    workspace_path: []const u8,
) void {
    if (!markBuilding(workspace_path)) return;

    const ctx = allocator.create(WorkerCtx) catch {
        clearBuilding(workspace_path);
        return;
    };
    ctx.* = .{
        .allocator = allocator,
        .io = io,
        .path = allocator.dupe(u8, workspace_path) catch {
            clearBuilding(workspace_path);
            allocator.destroy(ctx);
            return;
        },
        .environ_map = environ_map,
    };

    const thread = std.Thread.spawn(.{}, backgroundWorker, .{ctx}) catch {
        clearBuilding(workspace_path);
        allocator.free(ctx.path);
        allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

fn backgroundWorker(ctx: *WorkerCtx) void {
    defer {
        clearBuilding(ctx.path);
        ctx.allocator.free(ctx.path);
        ctx.allocator.destroy(ctx);
    }

    var root = workspace.WorkspaceRoot.open(ctx.io, ctx.path) catch return;
    defer root.close(ctx.io);

    codebase_search.ensureIndex(ctx.allocator, ctx.io, root, .{
        .prefer_gemini = ctx.environ_map != null,
        .environ_map = ctx.environ_map,
        .allow_rebuild = true,
    }) catch {};
}

const ManifestCounts = struct {
    chunk_count: u32,
    file_count: u32,
};

fn readManifestCounts(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot) !ManifestCounts {
    const p = try workspace.codebase_index.getManifestFile(allocator, io, root);
    defer allocator.free(p);
    const manifest_bytes = try workspace.global_store.readAbsoluteFile(allocator, io, p);
    defer allocator.free(manifest_bytes);

    const Json = struct {
        chunk_count: u32,
        file_count: u32,
    };
    var parsed = try std.json.parseFromSlice(Json, allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .chunk_count = parsed.value.chunk_count,
        .file_count = parsed.value.file_count,
    };
}

test "workspaceStatus reports missing without manifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    const status = try workspaceStatus(allocator, io, root, ".");
    try std.testing.expectEqual(Status.missing, status);
}

test "buildForeground creates index for empty workspace" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();

    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    const report = try buildForeground(allocator, io, root, null);
    try std.testing.expect(report.rebuilt);
    try std.testing.expectEqual(Status.ready, report.status);
}

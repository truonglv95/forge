const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const tools = @import("tools.zig");
const codebase_search = @import("codebase_search.zig");
const context_rerank = @import("context_rerank.zig");
const context_retrieval = @import("context_retrieval.zig");
const web_fetcher = @import("web_fetcher.zig");

pub const AgentToolError = error{
    Cancelled,
    NotAllowed,
    WorkspaceFailed,
    TaskFailed,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    cwd: []const u8,
    profile: tools.CapabilityProfile,
    cancel_token: ?*const kernel.cancellation.CancellationToken = null,
    environ_map: ?*const std.process.Environ.Map = null,
};

pub const Outcome = struct {
    summary: []const u8,
};

pub const SearchOutcome = struct {
    summary: []const u8,
    first_match_path: ?[]const u8,
};

pub const CodebaseSearchOutcome = struct {
    summary: []const u8,
    formatted: ?[]const u8,
};

fn checkCancel(ctx: Context) AgentToolError!void {
    if (ctx.cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }
}

fn requireTool(ctx: Context, tool: tools.ToolId) AgentToolError!void {
    if (!tools.isAllowed(ctx.profile, tool)) return error.NotAllowed;
}

pub fn search(ctx: Context, term: []const u8) AgentToolError!SearchOutcome {
    try checkCancel(ctx);
    try requireTool(ctx, .search);

    var result = workspace.search.searchContent(ctx.allocator, ctx.io, ctx.root, ".", term) catch return error.WorkspaceFailed;
    defer result.deinit();

    const summary = std.fmt.allocPrint(ctx.allocator, "search '{s}' -> {d} hits", .{ term, result.matches.len }) catch return error.WorkspaceFailed;

    const first_match_path = if (result.matches.len > 0)
        ctx.allocator.dupe(u8, result.matches[0].path) catch return error.WorkspaceFailed
    else
        null;

    return .{ .summary = summary, .first_match_path = first_match_path };
}

pub fn codebaseSearch(ctx: Context, query: []const u8) AgentToolError!CodebaseSearchOutcome {
    try checkCancel(ctx);
    try requireTool(ctx, .codebase_search);

    const results = codebase_search.search(ctx.allocator, ctx.io, ctx.root, query, &.{}, .{
        .top_k = 16,
        .prefer_gemini = ctx.environ_map != null,
        .environ_map = ctx.environ_map,
    }) catch return error.WorkspaceFailed;
    defer codebase_search.freeResults(ctx.allocator, results);

    var inputs: std.ArrayList(context_rerank.Input) = .empty;
    defer inputs.deinit(ctx.allocator);
    for (results, 0..) |item, rank| {
        inputs.append(ctx.allocator, .{
            .path = item.path,
            .line_start = item.line_start,
            .line_end = item.line_end,
            .text = item.text,
            .source = .semantic,
            .source_score = item.score,
            .source_rank = rank,
        }) catch return error.WorkspaceFailed;
    }

    const intent_terms = context_retrieval.intentTerms(ctx.allocator, query, 4) catch return error.WorkspaceFailed;
    defer context_retrieval.freeIntentTerms(ctx.allocator, intent_terms);

    const hits = context_rerank.rerank(ctx.allocator, inputs.items, .{ .intent_terms = intent_terms }, .{
        .max_results = 8,
    }) catch return error.WorkspaceFailed;
    defer context_rerank.freeHits(ctx.allocator, hits);

    const formatted = context_rerank.formatBlock(ctx.allocator, hits) catch return error.WorkspaceFailed;

    const summary = std.fmt.allocPrint(ctx.allocator, "codebase_search '{s}' -> {d} reranked hits", .{
        query,
        hits.len,
    }) catch return error.WorkspaceFailed;

    return .{ .summary = summary, .formatted = formatted };
}

pub fn remember(ctx: Context, content: []const u8, kind_text: []const u8, tags: []const []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .remember);

    const kind = workspace.agent_memory.Kind.parse(kind_text) orelse .note;
    const timestamp_ms = std.Io.Timestamp.now(ctx.io, .real).toMilliseconds();

    const id = workspace.agent_memory.appendEntry(ctx.allocator, ctx.io, ctx.root, .{
        .kind = kind,
        .content = content,
        .tags = tags,
        .source = "agent",
        .timestamp_ms = timestamp_ms,
    }) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(id);

    const summary = std.fmt.allocPrint(ctx.allocator, "remember '{s}' -> saved as {s} ({s})", .{
        if (content.len > 48) content[0..48] else content,
        id,
        kind.label(),
    }) catch return error.WorkspaceFailed;

    return .{ .summary = summary };
}

pub const FetchUrlOutcome = struct {
    summary: []const u8,
    content: ?[]const u8,
};

pub fn fetchUrl(ctx: Context, url: []const u8) AgentToolError!FetchUrlOutcome {
    try checkCancel(ctx);
    try requireTool(ctx, .fetch_url);

    const page = web_fetcher.fetchUrl(ctx.allocator, ctx.io, ctx.root, url, .{}) catch return error.WorkspaceFailed;

    const summary = std.fmt.allocPrint(ctx.allocator, "fetch_url '{s}' -> {d} bytes ({s})", .{
        url,
        page.text.len,
        if (page.from_cache) "cache" else "network",
    }) catch {
        web_fetcher.freePage(ctx.allocator, page);
        return error.WorkspaceFailed;
    };

    const content = page.text;
    ctx.allocator.free(page.url);

    return .{
        .summary = summary,
        .content = content,
    };
}

pub fn listTree(ctx: Context) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .list_tree);

    var tree = workspace.tree.scan(ctx.allocator, ctx.io, ctx.root, ".") catch return error.WorkspaceFailed;
    defer tree.deinit();

    const summary = std.fmt.allocPrint(ctx.allocator, "list_tree -> {d} files, {d} dirs", .{
        tree.file_count,
        tree.dir_count,
    }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn readFile(ctx: Context, rel_path: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .read_file);

    const wp = workspace.WorkspacePath.parse(rel_path) catch return error.WorkspaceFailed;
    var snap = workspace.FileSnapshot.read(ctx.allocator, ctx.io, ctx.root, wp) catch return error.WorkspaceFailed;
    defer snap.deinit();

    const summary = std.fmt.allocPrint(ctx.allocator, "read_file '{s}' -> {d} bytes (hash {x})", .{
        rel_path,
        snap.content.len,
        snap.hash,
    }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn runTask(ctx: Context, task_name: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .run_task);

    const argv = if (std.mem.eql(u8, task_name, "test"))
        &[_][]const u8{ "zig", "build", "test" }
    else if (std.mem.eql(u8, task_name, "build"))
        &[_][]const u8{ "zig", "build" }
    else if (std.mem.eql(u8, task_name, "fmt"))
        &[_][]const u8{ "zig", "fmt", "--check", "." }
    else
        return error.NotAllowed;

    const term = kernel.process.run(ctx.allocator, ctx.io, .{
        .argv = argv,
        .cwd = ctx.cwd,
        .token = if (ctx.cancel_token) |token| token else null,
    }) catch return error.TaskFailed;

    const exit_code: u8 = switch (term) {
        .exited => |code| @intCast(code),
        else => 1,
    };

    if (ctx.cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const summary = std.fmt.allocPrint(ctx.allocator, "run_task '{s}' -> exit {d}", .{ task_name, exit_code }) catch return error.WorkspaceFailed;
    if (exit_code != 0) return error.TaskFailed;
    return .{ .summary = summary };
}

test "tool executor search finds content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge search\n");

    const outcome = try search(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .propose,
    }, "forge");
    defer allocator.free(outcome.summary);
    if (outcome.first_match_path) |path| {
        defer allocator.free(path);
    }

    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "1 hits") != null);
    try std.testing.expect(outcome.first_match_path != null);
}

test "tool executor codebase_search returns semantic hits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("auth.zig"), "pub fn authenticateUser() void {}\n");

    const outcome = try codebaseSearch(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .propose,
    }, "authenticate user");
    defer allocator.free(outcome.summary);
    defer if (outcome.formatted) |formatted| allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "reranked hits") != null);
    try std.testing.expect(outcome.formatted != null);
}

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
    edit_callback: ?*const fn (?*anyopaque, path: []const u8, start_line: usize, end_line: usize, replacement: []const u8) void = null,
    edit_context: ?*anyopaque = null,
};

pub const Outcome = struct {
    summary: []const u8,
};

pub const SearchOutcome = struct {
    summary: []const u8,
    first_match_path: ?[]const u8,
    observation: []const u8,
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
    errdefer ctx.allocator.free(summary);

    var observation: std.ArrayList(u8) = .empty;
    errdefer observation.deinit(ctx.allocator);
    const shown = @min(result.matches.len, 20);
    appendPrint(ctx.allocator, &observation, "Search `{s}`: {d} hit(s), showing {d}\n", .{ term, result.matches.len, shown }) catch return error.WorkspaceFailed;
    for (result.matches[0..shown]) |match| {
        appendPrint(ctx.allocator, &observation, "\n{s}:{d}\n{s}\n", .{ match.path, match.line, match.line_text }) catch return error.WorkspaceFailed;
    }

    const first_match_path = if (result.matches.len > 0)
        ctx.allocator.dupe(u8, result.matches[0].path) catch return error.WorkspaceFailed
    else
        null;

    return .{ .summary = summary, .first_match_path = first_match_path, .observation = observation.toOwnedSlice(ctx.allocator) catch return error.WorkspaceFailed };
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

pub fn listTree(ctx: Context, base_path: []const u8, max_depth: usize) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .list_tree);

    var tree = workspace.tree.scan(ctx.allocator, ctx.io, ctx.root, ".") catch return error.WorkspaceFailed;
    defer tree.deinit();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(ctx.allocator);
    appendPrint(ctx.allocator, &output, "Tree `{s}` ({d} files, {d} dirs)\n", .{ base_path, tree.file_count, tree.dir_count }) catch return error.WorkspaceFailed;
    var shown: usize = 0;
    for (tree.entries) |entry| {
        if (!pathUnderBase(entry.path, base_path)) continue;
        if (relativeDepth(entry.path, base_path) > max_depth) continue;
        appendPrint(ctx.allocator, &output, "{s}{s}\n", .{ entry.path, if (entry.kind == .directory) "/" else "" }) catch return error.WorkspaceFailed;
        shown += 1;
        if (shown >= 200) {
            output.appendSlice(ctx.allocator, "... [tree truncated]\n") catch return error.WorkspaceFailed;
            break;
        }
    }
    const summary = std.fmt.allocPrint(ctx.allocator, "list_tree '{s}' -> {d} entries shown", .{
        base_path,
        shown,
    }) catch return error.WorkspaceFailed;
    const rendered = output.toOwnedSlice(ctx.allocator) catch return error.WorkspaceFailed;
    ctx.allocator.free(summary);
    return .{ .summary = rendered };
}

fn pathUnderBase(path: []const u8, base_path: []const u8) bool {
    if (std.mem.eql(u8, base_path, ".") or base_path.len == 0) return true;
    if (std.mem.eql(u8, path, base_path)) return true;
    return std.mem.startsWith(u8, path, base_path) and path.len > base_path.len and path[base_path.len] == std.fs.path.sep;
}

fn relativeDepth(path: []const u8, base_path: []const u8) usize {
    const rel = if (std.mem.eql(u8, base_path, ".") or base_path.len == 0) path else if (path.len > base_path.len) path[base_path.len + 1 ..] else "";
    var depth: usize = 0;
    for (rel) |byte| if (byte == std.fs.path.sep) {
        depth += 1;
    };
    return depth;
}

pub fn readFile(ctx: Context, rel_path: []const u8, start_line: ?usize, end_line: ?usize) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .read_file);

    const wp = workspace.WorkspacePath.parse(rel_path) catch return error.WorkspaceFailed;
    var snap = workspace.FileSnapshot.read(ctx.allocator, ctx.io, ctx.root, wp) catch return error.WorkspaceFailed;
    defer snap.deinit();

    if (std.mem.indexOfScalar(u8, snap.content, 0) != null) return error.NotAllowed;
    const first = @max(start_line orelse 1, 1);
    const last = end_line orelse (first + 399);
    var rendered: std.ArrayList(u8) = .empty;
    errdefer rendered.deinit(ctx.allocator);
    appendPrint(ctx.allocator, &rendered, "File `{s}` hash={x} bytes={d} lines={d}-{d}\n", .{ rel_path, snap.hash, snap.content.len, first, last }) catch return error.WorkspaceFailed;
    var lines = std.mem.splitScalar(u8, snap.content, '\n');
    var line_no: usize = 1;
    var emitted_bytes: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no < first) continue;
        if (line_no > last or emitted_bytes >= 64 * 1024) break;
        appendPrint(ctx.allocator, &rendered, "{d: >6} | {s}\n", .{ line_no, line }) catch return error.WorkspaceFailed;
        emitted_bytes += line.len + 10;
    }
    if (line_no <= last and emitted_bytes >= 64 * 1024) rendered.appendSlice(ctx.allocator, "... [file truncated]\n") catch return error.WorkspaceFailed;
    return .{ .summary = rendered.toOwnedSlice(ctx.allocator) catch return error.WorkspaceFailed };
}

fn appendPrint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

pub fn runCommand(ctx: Context, command: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .run_command);
    const argv = allowedCommandArgv(command) orelse return error.NotAllowed;

    const captured = kernel.process.runCapture(ctx.allocator, .{
        .argv = argv,
        .cwd = ctx.cwd,
        .max_bytes = 24 * 1024,
    }) catch return error.TaskFailed;
    defer ctx.allocator.free(captured.output);

    if (ctx.cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const clipped = if (captured.output.len > 1200) captured.output[0..1200] else captured.output;
    const summary = std.fmt.allocPrint(ctx.allocator, "run_command exit {d}\n{s}", .{ captured.exit_code, clipped }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn replaceFileContent(ctx: Context, path: []const u8, start_line: usize, end_line: usize, replacement: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .propose_edit);

    if (ctx.edit_callback) |cb| {
        cb(ctx.edit_context, path, start_line, end_line, replacement);
    }

    const summary = std.fmt.allocPrint(ctx.allocator, "Proposed edit to {s} (lines {d}-{d})", .{ path, start_line, end_line }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

/// Maps a deliberately small set of read-only or validation commands to argv.
/// Never pass model text through a shell: prefix checks do not prevent command
/// separators, substitutions, redirects, or path traversal.
fn allowedCommandArgv(command: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, command, "zig build")) return &.{ "zig", "build" };
    if (std.mem.eql(u8, command, "zig build test")) return &.{ "zig", "build", "test" };
    if (std.mem.eql(u8, command, "zig fmt --check .")) return &.{ "zig", "fmt", "--check", "." };
    if (std.mem.eql(u8, command, "git status")) return &.{ "git", "status" };
    if (std.mem.eql(u8, command, "git status --short")) return &.{ "git", "status", "--short" };
    if (std.mem.eql(u8, command, "git diff")) return &.{ "git", "--no-pager", "diff", "--no-ext-diff" };
    if (std.mem.eql(u8, command, "git diff --stat")) return &.{ "git", "--no-pager", "diff", "--no-ext-diff", "--stat" };
    if (std.mem.eql(u8, command, "git log --oneline")) return &.{ "git", "--no-pager", "log", "--oneline" };
    if (std.mem.eql(u8, command, "pwd")) return &.{"pwd"};
    return null;
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
        .token = if (ctx.cancel_token) |token| token.* else null,
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
    defer allocator.free(outcome.observation);
    if (outcome.first_match_path) |path| {
        defer allocator.free(path);
    }

    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "1 hits") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.observation, "sample.txt:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.observation, "hello forge search") != null);
    try std.testing.expect(outcome.first_match_path != null);
}

test "read file returns bounded source with line numbers and hash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("source.zig"), "one\ntwo\nthree\n");

    const outcome = try readFile(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .read_only,
    }, "source.zig", 2, 3);
    defer allocator.free(outcome.summary);
    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "hash=") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "2 | two") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "1 | one") == null);
}

test "list tree returns workspace paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir);
    try tmp.dir.createDirPath(io, "src");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/main.zig"), "pub fn main() void {}\n");

    const outcome = try listTree(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .read_only,
    }, "src", 2);
    defer allocator.free(outcome.summary);
    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "src/main.zig") != null);
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

test "run command allowlist produces argv without a shell" {
    const argv = allowedCommandArgv("git diff --stat").?;
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("--no-pager", argv[1]);
    for (argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "sh"));
}

test "run command rejects shell injection and path-reading commands" {
    try std.testing.expect(allowedCommandArgv("git status; rm -rf .") == null);
    try std.testing.expect(allowedCommandArgv("git status && echo exposed") == null);
    try std.testing.expect(allowedCommandArgv("git diff $(touch owned)") == null);
    try std.testing.expect(allowedCommandArgv("cat ../../.ssh/id_rsa") == null);
    try std.testing.expect(allowedCommandArgv("find . -exec sh {} ;") == null);
}

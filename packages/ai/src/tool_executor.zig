const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const tools = @import("tools.zig");
const codebase_search = @import("codebase_search.zig");
const context_rerank = @import("context_rerank.zig");
const context_retrieval = @import("context_retrieval.zig");
const web_fetcher = @import("web_fetcher.zig");
const tool_cache_mod = @import("tool_cache.zig");

pub const ToolCache = tool_cache_mod.Cache;

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
    edit_callback: ?*const fn (?*anyopaque, edit: workspace.edit.WorkspaceEdit) void = null,
    edit_context: ?*anyopaque = null,
    lsp_request_callback: ?*const fn (?*anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ?[]const u8 = null,
    lsp_context: ?*anyopaque = null,
    cache: ?*tool_cache_mod.Cache = null,
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

pub fn search(ctx: Context, args: @import("tools/args.zig").SearchArgs) AgentToolError!SearchOutcome {
    const owned: @import("tools/args.zig").SearchArgs = .{
        .pattern = ctx.allocator.dupe(u8, args.pattern) catch return error.WorkspaceFailed,
        .path = ctx.allocator.dupe(u8, args.path) catch return error.WorkspaceFailed,
        .glob = if (args.glob) |glob| ctx.allocator.dupe(u8, glob) catch return error.WorkspaceFailed else null,
        .case_sensitive = args.case_sensitive,
        .head_limit = args.head_limit,
        .context_lines = args.context_lines,
    };
    defer @import("tools/args.zig").freeSearchArgs(ctx.allocator, owned);
    try checkCancel(ctx);
    try requireTool(ctx, .search);

    const cache_key = std.fmt.allocPrint(ctx.allocator, "{{\"pattern\":\"{s}\",\"path\":\"{s}\",\"glob\":{s},\"case_sensitive\":{}}}", .{
        owned.pattern,
        owned.path,
        if (owned.glob) |g| g else "null",
        owned.case_sensitive,
    }) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(cache_key);

    if (ctx.cache) |cache| {
        const key = tool_cache_mod.Cache.makeKey(ctx.allocator, "search", cache_key) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(key);
        if (cache.get(key)) |cached| {
            const summary = std.fmt.allocPrint(ctx.allocator, "grep '{s}' -> cache hit", .{owned.pattern}) catch return error.WorkspaceFailed;
            const observation = ctx.allocator.dupe(u8, cached) catch return error.WorkspaceFailed;
            return .{ .summary = summary, .first_match_path = null, .observation = observation };
        }
    }

    var result = workspace.search.grepContent(ctx.allocator, ctx.io, ctx.root, .{
        .pattern = owned.pattern,
        .path = owned.path,
        .glob = owned.glob,
        .case_sensitive = owned.case_sensitive,
        .head_limit = owned.head_limit,
        .context_lines = owned.context_lines,
    }) catch return error.WorkspaceFailed;
    defer result.deinit();

    const summary = std.fmt.allocPrint(ctx.allocator, "grep '{s}' -> {d} hits", .{ owned.pattern, result.matches.len }) catch return error.WorkspaceFailed;
    errdefer ctx.allocator.free(summary);

    var observation: std.ArrayList(u8) = .empty;
    errdefer observation.deinit(ctx.allocator);
    const shown = result.matches.len;
    appendPrint(ctx.allocator, &observation, "Grep `{s}` in `{s}`: {d} hit(s)", .{ owned.pattern, owned.path, result.matches.len }) catch return error.WorkspaceFailed;
    if (owned.glob) |glob| appendPrint(ctx.allocator, &observation, " glob=`{s}`", .{glob}) catch return error.WorkspaceFailed;
    appendPrint(ctx.allocator, &observation, "\n", .{}) catch return error.WorkspaceFailed;
    const has_context = owned.context_lines > 0;
    for (result.matches[0..shown], 0..) |match, idx| {
        if (has_context) {
            // grep -C style: emit before-context lines, match line, after-context lines,
            // then a -- separator between groups.
            if (idx > 0) appendPrint(ctx.allocator, &observation, "--\n", .{}) catch return error.WorkspaceFailed;
            if (match.before_context.len > 0) {
                var before_iter = std.mem.splitScalar(u8, match.before_context, '\n');
                var ctx_line_no: u32 = match.line - @as(u32, @intCast(@min(owned.context_lines, match.line - 1)));
                while (before_iter.next()) |bline| {
                    appendPrint(ctx.allocator, &observation, "{s}:{d}: {s}\n", .{ match.path, ctx_line_no, bline }) catch return error.WorkspaceFailed;
                    ctx_line_no += 1;
                }
            }
            appendPrint(ctx.allocator, &observation, "{s}:{d}: {s}\n", .{ match.path, match.line, match.line_text }) catch return error.WorkspaceFailed;
            if (match.after_context.len > 0) {
                var after_iter = std.mem.splitScalar(u8, match.after_context, '\n');
                var ctx_line_no: u32 = match.line + 1;
                while (after_iter.next()) |aline| {
                    appendPrint(ctx.allocator, &observation, "{s}:{d}: {s}\n", .{ match.path, ctx_line_no, aline }) catch return error.WorkspaceFailed;
                    ctx_line_no += 1;
                }
            }
        } else {
            appendPrint(ctx.allocator, &observation, "\n{s}:{d}\n{s}\n", .{ match.path, match.line, match.line_text }) catch return error.WorkspaceFailed;
        }
    }

    const first_match_path = if (result.matches.len > 0)
        ctx.allocator.dupe(u8, result.matches[0].path) catch return error.WorkspaceFailed
    else
        null;

    const observation_owned = observation.toOwnedSlice(ctx.allocator) catch return error.WorkspaceFailed;

    if (ctx.cache) |cache| {
        const key = tool_cache_mod.Cache.makeKey(ctx.allocator, "search", cache_key) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(key);
        cache.put(key, observation_owned) catch {};
    }

    return .{ .summary = summary, .first_match_path = first_match_path, .observation = observation_owned };
}

pub fn lspWorkspaceSymbol(ctx: Context, query: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .lsp_workspace_symbol);

    const cb = ctx.lsp_request_callback orelse {
        const summary = ctx.allocator.dupe(u8, "LSP not connected.") catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    };

    const params_json = std.fmt.allocPrint(ctx.allocator, "{{\"query\":\"{s}\"}}", .{query}) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(params_json);

    if (cb(ctx.lsp_context, ctx.allocator, "workspace/symbol", params_json)) |res| {
        return .{ .summary = res };
    }

    const summary = std.fmt.allocPrint(ctx.allocator, "No symbols found for '{s}'.", .{query}) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn lspFindReferences(ctx: Context, path: []const u8, line: usize, character: usize) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .lsp_find_references);

    const cb = ctx.lsp_request_callback orelse {
        const summary = ctx.allocator.dupe(u8, "LSP not connected.") catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    };

    const abs_path = std.fs.path.join(ctx.allocator, &.{ ctx.root.path, path }) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(abs_path);
    const uri = std.fmt.allocPrint(ctx.allocator, "file://{s}", .{abs_path}) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(uri);

    // textDocument/references params:
    // { "textDocument": { "uri": "..." }, "position": { "line": ..., "character": ... }, "context": { "includeDeclaration": true } }
    const params_json = std.fmt.allocPrint(ctx.allocator,
        \\{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"context":{{"includeDeclaration":true}}}}
    , .{ uri, line, character }) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(params_json);

    if (cb(ctx.lsp_context, ctx.allocator, "textDocument/references", params_json)) |res| {
        return .{ .summary = res };
    }

    const summary = std.fmt.allocPrint(ctx.allocator, "No references found for '{s}' at {d}:{d}.", .{ path, line, character }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn codebaseSearch(ctx: Context, query: []const u8) AgentToolError!CodebaseSearchOutcome {
    try checkCancel(ctx);
    try requireTool(ctx, .codebase_search);

    const args_json = std.fmt.allocPrint(ctx.allocator, "{{\"query\":\"{s}\"}}", .{query}) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(args_json);

    if (ctx.cache) |cache| {
        const key = tool_cache_mod.Cache.makeKey(ctx.allocator, "codebase_search", args_json) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(key);
        if (cache.get(key)) |cached| {
            const summary = std.fmt.allocPrint(ctx.allocator, "codebase_search '{s}' -> cache hit", .{query}) catch return error.WorkspaceFailed;
            const formatted = ctx.allocator.dupe(u8, cached) catch return error.WorkspaceFailed;
            return .{ .summary = summary, .formatted = formatted };
        }
    }

    const results = codebase_search.search(ctx.allocator, ctx.io, ctx.root, query, &.{}, .{
        .top_k = 16,
        .prefer_gemini = ctx.environ_map != null,
        .environ_map = ctx.environ_map,
    }) catch {
        const summary = std.fmt.allocPrint(ctx.allocator, "codebase_search '{s}' -> index unavailable", .{query}) catch return error.WorkspaceFailed;
        const formatted = std.fmt.allocPrint(
            ctx.allocator,
            "Semantic index is not ready for this workspace. Try list_tree or read_file on known paths.\n",
            .{},
        ) catch return error.WorkspaceFailed;
        return .{ .summary = summary, .formatted = formatted };
    };
    defer codebase_search.freeResults(ctx.allocator, results);

    var inputs: std.ArrayList(context_rerank.Input) = .empty;
    defer inputs.deinit(ctx.allocator);
    for (results, 0..) |item, rank| {
        inputs.append(ctx.allocator, .{
            .path = item.path,
            .line_start = item.line_start,
            .line_end = item.line_end,
            .text = item.text,
            .symbol = item.symbol orelse "",
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

    if (ctx.cache) |cache| {
        if (formatted) |text| {
            const key = tool_cache_mod.Cache.makeKey(ctx.allocator, "codebase_search", args_json) catch return error.WorkspaceFailed;
            defer ctx.allocator.free(key);
            cache.put(key, text) catch {};
        }
    }

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

pub fn findFiles(ctx: Context, pattern: []const u8, search_path: []const u8, head_limit: usize) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .find_files);

    const limit = @min(head_limit, 200);

    // --- Try fd first ---
    const is_glob = std.mem.indexOfAny(u8, pattern, "*?") != null;
    const fd_out: ?[]const u8 = blk: {
        if (is_glob) {
            const glob_argv = [_][]const u8{ "fd", "--type", "f", "--glob", pattern, search_path };
            const captured = kernel.process.runCapture(ctx.allocator, .{
                .argv = &glob_argv,
                .cwd = ctx.cwd,
                .max_bytes = 256 * 1024,
            }) catch break :blk null;
            if (captured.exit_code != 0) {
                ctx.allocator.free(captured.output);
                break :blk null;
            }
            break :blk captured.output;
        } else {
            const plain_argv = [_][]const u8{ "fd", "--type", "f", pattern, search_path };
            const captured = kernel.process.runCapture(ctx.allocator, .{
                .argv = &plain_argv,
                .cwd = ctx.cwd,
                .max_bytes = 256 * 1024,
            }) catch break :blk null;
            if (captured.exit_code != 0) {
                ctx.allocator.free(captured.output);
                break :blk null;
            }
            break :blk captured.output;
        }
    };

    if (fd_out) |raw| {
        defer ctx.allocator.free(raw);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(ctx.allocator);

        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, raw, "\n"), '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (count >= limit) break;
            appendPrint(ctx.allocator, &output, "{s}\n", .{trimmed}) catch return error.WorkspaceFailed;
            count += 1;
        }

        const header = std.fmt.allocPrint(ctx.allocator, "find_files '{s}' in '{s}': {d} file(s)\n\n", .{ pattern, search_path, count }) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(header);
        output.insertSlice(ctx.allocator, 0, header) catch return error.WorkspaceFailed;

        const summary = output.toOwnedSlice(ctx.allocator) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    }

    // --- Pure Zig fallback ---
    var tree_scan = workspace.tree.scan(ctx.allocator, ctx.io, ctx.root, ".") catch return error.WorkspaceFailed;
    defer tree_scan.deinit();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(ctx.allocator);

    var count: usize = 0;
    for (tree_scan.entries) |entry| {
        if (entry.kind != .file) continue;
        if (!pathUnderBase(entry.path, search_path)) continue;
        if (count >= limit) break;

        const matched = if (is_glob)
            globMatchesPath(entry.path, pattern)
        else
            caseInsensitiveContains(entry.path, pattern);

        if (!matched) continue;
        appendPrint(ctx.allocator, &output, "{s}\n", .{entry.path}) catch return error.WorkspaceFailed;
        count += 1;
    }

    const header = std.fmt.allocPrint(ctx.allocator, "find_files '{s}' in '{s}': {d} file(s)\n\n", .{ pattern, search_path, count }) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(header);
    output.insertSlice(ctx.allocator, 0, header) catch return error.WorkspaceFailed;

    const summary = output.toOwnedSlice(ctx.allocator) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

/// Glob match against the full path (if pattern contains '/') or the basename.
fn globMatchesPath(path: []const u8, glob: []const u8) bool {
    const target = if (std.mem.indexOfScalar(u8, glob, '/')) |_| path else std.fs.path.basename(path);
    return simpleGlob(target, glob);
}

fn simpleGlob(text: []const u8, pattern: []const u8) bool {
    return globRec(text, pattern, 0, 0);
}

fn globRec(text: []const u8, pattern: []const u8, ti: usize, pi: usize) bool {
    if (pi == pattern.len) return ti == text.len;
    if (pattern[pi] == '*') {
        var skip: usize = pi + 1;
        while (skip < pattern.len and pattern[skip] == '*') skip += 1;
        if (skip == pattern.len) return true;
        var start: usize = ti;
        while (start <= text.len) : (start += 1) {
            if (globRec(text, pattern, start, skip)) return true;
        }
        return false;
    }
    if (ti == text.len) return false;
    const pc = pattern[pi];
    const tc = text[ti];
    if (pc == '?' or pc == tc) return globRec(text, pattern, ti + 1, pi + 1);
    return false;
}

fn caseInsensitiveContains(path: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    const base = std.fs.path.basename(path);
    // Check basename first (most common use case), then full path
    if (std.ascii.indexOfIgnoreCase(base, needle) != null) return true;
    if (std.ascii.indexOfIgnoreCase(path, needle) != null) return true;
    return false;
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
    if (isDeniedReadPath(rel_path)) {
        const summary = std.fmt.allocPrint(
            ctx.allocator,
            "read_file blocked `{s}`: skip __pycache__, .pyc, and other generated/binary files. Read the matching source file (e.g. tensor.py) instead.",
            .{rel_path},
        ) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    }

    const cache_key = std.fmt.allocPrint(ctx.allocator, "{{\"path\":\"{s}\",\"start\":{?},\"end\":{?}}}", .{ rel_path, start_line, end_line }) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(cache_key);

    if (ctx.cache) |cache| {
        const key = tool_cache_mod.Cache.makeKey(ctx.allocator, "read_file", cache_key) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(key);
        if (cache.get(key)) |cached| {
            const summary = ctx.allocator.dupe(u8, cached) catch return error.WorkspaceFailed;
            return .{ .summary = summary };
        }
    }

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
    const summary = rendered.toOwnedSlice(ctx.allocator) catch return error.WorkspaceFailed;

    if (ctx.cache) |cache| {
        const key = tool_cache_mod.Cache.makeKey(ctx.allocator, "read_file", cache_key) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(key);
        cache.put(key, summary) catch {};
    }

    return .{ .summary = summary };
}

fn appendPrint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn isDeniedReadPath(rel_path: []const u8) bool {
    const trimmed = std.mem.trim(u8, rel_path, &std.ascii.whitespace);
    if (trimmed.len == 0) return true;
    if (std.mem.indexOf(u8, trimmed, "__pycache__") != null) return true;
    const base = std.fs.path.basename(trimmed);
    const denied_suffixes = [_][]const u8{ ".pyc", ".pyo", ".pyd", ".so", ".dll", ".exe", ".bin", ".o", ".class", ".wasm" };
    for (denied_suffixes) |suffix| {
        if (std.mem.endsWith(u8, base, suffix)) return true;
    }
    return false;
}

pub fn runCommand(ctx: Context, command: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .run_command);
    const checkout_path = parseGitCheckoutPath(command);
    var checkout_argv: [4][]const u8 = undefined;
    const grep_args = parseGrepNCommand(command);
    var grep_argv: [4][]const u8 = undefined;
    const argv = allowedCommandArgv(command) orelse blk: {
        if (checkout_path) |path| {
            _ = workspace.WorkspacePath.parse(path) catch return error.NotAllowed;
            checkout_argv = .{ "git", "checkout", "--", path };
            break :blk checkout_argv[0..];
        }
        if (grep_args) |args| {
            _ = workspace.WorkspacePath.parse(args.path) catch return error.NotAllowed;
            grep_argv = .{ "grep", "-n", args.pattern, args.path };
            break :blk grep_argv[0..];
        }
        return error.NotAllowed;
    };

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

fn parseGitCheckoutPath(command: []const u8) ?[]const u8 {
    const prefix = "git checkout ";
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const path = std.mem.trim(u8, command[prefix.len..], &std.ascii.whitespace);
    if (path.len == 0) return null;
    if (std.mem.indexOfAny(u8, path, " \t\r\n") != null) return null;
    if (std.mem.startsWith(u8, path, "-")) return null;
    return path;
}

const GrepNCommand = struct {
    pattern: []const u8,
    path: []const u8,
};

fn parseGrepNCommand(command: []const u8) ?GrepNCommand {
    const prefix = "grep -n ";
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    var rest = std.mem.trim(u8, command[prefix.len..], &std.ascii.whitespace);
    if (rest.len == 0) return null;

    var pattern: []const u8 = "";
    if (rest[0] == '"' or rest[0] == '\'') {
        const quote = rest[0];
        var end: usize = 1;
        while (end < rest.len and rest[end] != quote) : (end += 1) {}
        if (end >= rest.len) return null;
        pattern = rest[1..end];
        rest = std.mem.trim(u8, rest[end + 1 ..], &std.ascii.whitespace);
    } else {
        const split = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse return null;
        pattern = rest[0..split];
        rest = std.mem.trim(u8, rest[split..], &std.ascii.whitespace);
    }

    const path = rest;
    if (pattern.len == 0 or path.len == 0) return null;
    if (std.mem.indexOfAny(u8, pattern, "\r\n\x00") != null) return null;
    if (std.mem.indexOfAny(u8, path, " \t\r\n\x00") != null) return null;
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    if (std.mem.startsWith(u8, pattern, "-") or std.mem.startsWith(u8, path, "-")) return null;
    return .{ .pattern = pattern, .path = path };
}

pub fn replaceFileContent(ctx: Context, args: @import("tools/args.zig").ReplaceFileContentArgs) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .propose_edit);

    if (ctx.edit_callback) |cb| {
        const wp = workspace.WorkspacePath.parse(args.path) catch return error.WorkspaceFailed;
        var snap = workspace.FileSnapshot.read(ctx.allocator, ctx.io, ctx.root, wp) catch return error.WorkspaceFailed;
        defer snap.deinit();

        const expected_hash = workspace.edit.contentHash(snap.content);

        var text_edits: std.ArrayList(workspace.edit.TextEdit) = .empty;
        defer text_edits.deinit(ctx.allocator);
        for (args.edits) |e| {
            text_edits.append(ctx.allocator, .{
                .start = 0,
                .end = 0,
                .search = e.search,
                .replacement = e.replace,
            }) catch return error.WorkspaceFailed;
        }

        const file_edit = workspace.edit.FileEdit{
            .path = args.path,
            .operation = .modify,
            .expected_hash = expected_hash,
            .edits = text_edits.items,
        };

        const ws_edit = workspace.edit.WorkspaceEdit{
            .files = &.{file_edit},
        };

        cb(ctx.edit_context, ws_edit);
    }

    const summary = std.fmt.allocPrint(ctx.allocator, "Edited {s} ({d} blocks)", .{ args.path, args.edits.len }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

fn unsafeEditShrinkReason(
    ctx: Context,
    path: []const u8,
    start_line: usize,
    end_line: usize,
    replacement: []const u8,
) AgentToolError!?[]u8 {
    const wp = workspace.WorkspacePath.parse(path) catch return null;
    var snap = workspace.FileSnapshot.read(ctx.allocator, ctx.io, ctx.root, wp) catch return null;
    defer snap.deinit();

    const old_lines = countLines(snap.content);
    if (old_lines == 0) return null;
    const replacement_lines = countLines(replacement);
    const removed_lines = if (start_line == 0 and end_line == 0)
        old_lines
    else if (end_line >= start_line)
        end_line - start_line + 1
    else
        0;

    if (removed_lines < 20) return null;
    if (replacement_lines * 2 + 10 >= removed_lines) return null;

    return std.fmt.allocPrint(
        ctx.allocator,
        "Edit rejected for safety: requested replacement of {d} line(s) in `{s}` with only {d} line(s). Read the exact target range and retry with a narrower line range.",
        .{ removed_lines, path, replacement_lines },
    ) catch return error.WorkspaceFailed;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n' and count > 0) count -= 1;
    return count;
}

/// Maps a deliberately small set of read-only or validation commands to argv.
/// Never pass model text through a shell: prefix checks do not prevent command
/// separators, substitutions, redirects, or path traversal.
pub fn allowedCommandArgv(command: []const u8) ?[]const []const u8 {
    // --- Zig ---
    if (std.mem.eql(u8, command, "zig build")) return &.{ "zig", "build" };
    if (std.mem.eql(u8, command, "zig build test")) return &.{ "zig", "build", "test" };
    if (std.mem.eql(u8, command, "zig fmt --check .")) return &.{ "zig", "fmt", "--check", "." };
    if (std.mem.eql(u8, command, "zig test src/main.zig")) return &.{ "zig", "test", "src/main.zig" };
    // --- Git ---
    if (std.mem.eql(u8, command, "git status")) return &.{ "git", "status" };
    if (std.mem.eql(u8, command, "git status --short")) return &.{ "git", "status", "--short" };
    if (std.mem.eql(u8, command, "git diff")) return &.{ "git", "--no-pager", "diff", "--no-ext-diff" };
    if (std.mem.eql(u8, command, "git diff --stat")) return &.{ "git", "--no-pager", "diff", "--no-ext-diff", "--stat" };
    if (std.mem.eql(u8, command, "git log --oneline")) return &.{ "git", "--no-pager", "log", "--oneline" };
    if (std.mem.eql(u8, command, "git log --oneline -10")) return &.{ "git", "--no-pager", "log", "--oneline", "-10" };
    if (std.mem.eql(u8, command, "git stash list")) return &.{ "git", "--no-pager", "stash", "list" };
    // --- Node / npm / bun ---
    if (std.mem.eql(u8, command, "npm test")) return &.{ "npm", "test" };
    if (std.mem.eql(u8, command, "npm run build")) return &.{ "npm", "run", "build" };
    if (std.mem.eql(u8, command, "npm run lint")) return &.{ "npm", "run", "lint" };
    if (std.mem.eql(u8, command, "npm run typecheck")) return &.{ "npm", "run", "typecheck" };
    if (std.mem.eql(u8, command, "npm install")) return &.{ "npm", "install" };
    if (std.mem.eql(u8, command, "npx tsc --noEmit")) return &.{ "npx", "tsc", "--noEmit" };
    if (std.mem.eql(u8, command, "npx eslint .")) return &.{ "npx", "eslint", "." };
    if (std.mem.eql(u8, command, "bun test")) return &.{ "bun", "test" };
    if (std.mem.eql(u8, command, "bun run build")) return &.{ "bun", "run", "build" };
    if (std.mem.eql(u8, command, "bun install")) return &.{ "bun", "install" };
    // --- Rust / Cargo ---
    if (std.mem.eql(u8, command, "cargo build")) return &.{ "cargo", "build" };
    if (std.mem.eql(u8, command, "cargo test")) return &.{ "cargo", "test" };
    if (std.mem.eql(u8, command, "cargo check")) return &.{ "cargo", "check" };
    if (std.mem.eql(u8, command, "cargo clippy")) return &.{ "cargo", "clippy" };
    if (std.mem.eql(u8, command, "cargo fmt --check")) return &.{ "cargo", "fmt", "--check" };
    if (std.mem.eql(u8, command, "cargo build --release")) return &.{ "cargo", "build", "--release" };
    // --- Go ---
    if (std.mem.eql(u8, command, "go build ./...")) return &.{ "go", "build", "./..." };
    if (std.mem.eql(u8, command, "go test ./...")) return &.{ "go", "test", "./..." };
    if (std.mem.eql(u8, command, "go vet ./...")) return &.{ "go", "vet", "./..." };
    if (std.mem.eql(u8, command, "go build .")) return &.{ "go", "build", "." };
    if (std.mem.eql(u8, command, "gofmt -l .")) return &.{ "gofmt", "-l", "." };
    // --- Python ---
    if (std.mem.eql(u8, command, "python -m pytest")) return &.{ "python", "-m", "pytest" };
    if (std.mem.eql(u8, command, "python -m pytest -v")) return &.{ "python", "-m", "pytest", "-v" };
    if (std.mem.eql(u8, command, "python -m mypy .")) return &.{ "python", "-m", "mypy", "." };
    if (std.mem.eql(u8, command, "python -m ruff check .")) return &.{ "python", "-m", "ruff", "check", "." };
    if (std.mem.eql(u8, command, "python -m ruff format --check .")) return &.{ "python", "-m", "ruff", "format", "--check", "." };
    if (std.mem.eql(u8, command, "uv run pytest")) return &.{ "uv", "run", "pytest" };
    if (std.mem.eql(u8, command, "uv run mypy .")) return &.{ "uv", "run", "mypy", "." };
    // --- Make ---
    if (std.mem.eql(u8, command, "make")) return &.{"make"};
    if (std.mem.eql(u8, command, "make test")) return &.{ "make", "test" };
    if (std.mem.eql(u8, command, "make build")) return &.{ "make", "build" };
    if (std.mem.eql(u8, command, "make check")) return &.{ "make", "check" };
    if (std.mem.eql(u8, command, "make lint")) return &.{ "make", "lint" };
    // --- Dart / Flutter ---
    if (std.mem.eql(u8, command, "dart test")) return &.{ "dart", "test" };
    if (std.mem.eql(u8, command, "dart analyze")) return &.{ "dart", "analyze" };
    if (std.mem.eql(u8, command, "flutter test")) return &.{ "flutter", "test" };
    if (std.mem.eql(u8, command, "flutter analyze")) return &.{ "flutter", "analyze" };
    // --- Java / Kotlin / JVM ---
    if (std.mem.eql(u8, command, "mvn test")) return &.{ "mvn", "test" };
    if (std.mem.eql(u8, command, "mvn compile")) return &.{ "mvn", "compile" };
    if (std.mem.eql(u8, command, "gradle test")) return &.{ "gradle", "test" };
    if (std.mem.eql(u8, command, "gradle build")) return &.{ "gradle", "build" };
    if (std.mem.eql(u8, command, "./gradlew test")) return &.{ "./gradlew", "test" };
    if (std.mem.eql(u8, command, "./gradlew build")) return &.{ "./gradlew", "build" };
    // --- C/C++ ---
    if (std.mem.eql(u8, command, "cmake --build .")) return &.{ "cmake", "--build", "." };
    if (std.mem.eql(u8, command, "ctest")) return &.{"ctest"};
    if (std.mem.eql(u8, command, "ninja")) return &.{"ninja"};
    // --- System ---
    if (std.mem.eql(u8, command, "pwd")) return &.{"pwd"};
    if (std.mem.eql(u8, command, "ls")) return &.{"ls"};
    if (std.mem.eql(u8, command, "ls -la")) return &.{ "ls", "-la" };
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
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge search\n");

    const outcome = try search(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .propose,
    }, .{
        .pattern = "forge",
        .path = ".",
    });
    defer allocator.free(outcome.summary);
    defer allocator.free(outcome.observation);
    if (outcome.first_match_path) |path| {
        defer allocator.free(path);
    }

    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "1 hits") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.observation, "Grep `forge`") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.observation, "sample.txt") != null);
    try std.testing.expect(outcome.first_match_path != null);
}

test "read file returns bounded source with line numbers and hash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
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
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
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
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
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

test "run command parses simple approved grep without a shell" {
    const parsed = parseGrepNCommand("grep -n \"mouse_click\\|click_event\" apps/forge-ide/src/ui").?;
    try std.testing.expectEqualStrings("mouse_click\\|click_event", parsed.pattern);
    try std.testing.expectEqualStrings("apps/forge-ide/src/ui", parsed.path);
    try std.testing.expect(parseGrepNCommand("grep -n \"x\" apps/forge-ide/src/ui; rm -rf .") == null);
    try std.testing.expect(parseGrepNCommand("grep -n \"x\" ../../.ssh") == null);
}

test "run command rejects shell injection and path-reading commands" {
    try std.testing.expect(allowedCommandArgv("git status; rm -rf .") == null);
    try std.testing.expect(allowedCommandArgv("git status && echo exposed") == null);
    try std.testing.expect(allowedCommandArgv("git diff $(touch owned)") == null);
    try std.testing.expect(allowedCommandArgv("cat ../../.ssh/id_rsa") == null);
    try std.testing.expect(allowedCommandArgv("find . -exec sh {} ;") == null);
}

const std = @import("std");
const workspace = @import("forge-workspace");
const kernel = @import("forge-kernel");
const tools = @import("tools.zig");
const codebase_search = @import("codebase_search.zig");
const context_rerank = @import("context_rerank.zig");
const context_retrieval = @import("context_retrieval.zig");
const web_fetcher = @import("web_fetcher.zig");
const tool_cache_mod = @import("tool_cache.zig");
const args_mod = @import("tools/args.zig");
const command_policy = @import("tools/command_policy.zig");
const executor_types = @import("tools/executor_types.zig");
const edit_executor = @import("tools/edit_executor.zig");
const subagent_executor = @import("tools/subagent_executor.zig");
const lsp_executor = @import("tools/lsp_executor.zig");

pub const ToolCache = executor_types.ToolCache;
pub const allowedCommandArgv = command_policy.allowedCommandArgv;
pub const allowedCommandArgvWithExtra = command_policy.allowedCommandArgvWithExtra;

pub const AgentToolError = executor_types.AgentToolError;
pub const Context = executor_types.Context;
pub const Outcome = executor_types.Outcome;
pub const SearchOutcome = executor_types.SearchOutcome;
pub const CodebaseSearchOutcome = executor_types.CodebaseSearchOutcome;

const checkCancel = executor_types.checkCancel;
const requireTool = executor_types.requireTool;

pub fn getEditorContext(ctx: Context) AgentToolError!Outcome {
    try requireTool(ctx, .get_editor_context);
    try checkCancel(ctx);

    if (ctx.editor_context_callback) |callback| {
        if (callback(ctx.editor_context, ctx.allocator)) |context_json| {
            defer ctx.allocator.free(context_json);
            const summary = std.fmt.allocPrint(ctx.allocator, "editor context retrieved:\n{s}", .{context_json}) catch return error.WorkspaceFailed;
            return .{ .summary = summary };
        }
    }

    const summary = ctx.allocator.dupe(u8, "no editor context available") catch return error.WorkspaceFailed;
    return .{ .summary = summary };
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
        .enable_hyde = ctx.enable_hyde,
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

    var scoped_files: usize = 0;
    var scoped_dirs: usize = 0;
    for (tree.entries) |entry| {
        if (!pathUnderBase(entry.path, base_path)) continue;
        if (isBaseDirectoryEntry(entry, base_path)) continue;
        switch (entry.kind) {
            .file => scoped_files += 1,
            .directory => scoped_dirs += 1,
            else => {},
        }
    }

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(ctx.allocator);
    appendPrint(ctx.allocator, &output, "Tree `{s}` ({d} files, {d} dirs)\n", .{ base_path, scoped_files, scoped_dirs }) catch return error.WorkspaceFailed;
    var shown: usize = 0;
    for (tree.entries) |entry| {
        if (!pathUnderBase(entry.path, base_path)) continue;
        if (isBaseDirectoryEntry(entry, base_path)) continue;
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

fn isBaseDirectoryEntry(entry: workspace.tree.TreeEntry, base_path: []const u8) bool {
    if (std.mem.eql(u8, base_path, ".") or base_path.len == 0) return false;
    return entry.kind == .directory and std.mem.eql(u8, entry.path, base_path);
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

pub fn gitDiff(ctx: Context, stat: bool) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .git_diff);
    return runCommandUnchecked(ctx, if (stat) "git diff --stat" else "git diff");
}

pub fn gitStage(ctx: Context, args: args_mod.GitStageArgs) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .git_stage);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    argv.appendSlice(ctx.allocator, &.{ "git", "add", "--" }) catch return error.WorkspaceFailed;
    for (args.paths) |path| {
        argv.append(ctx.allocator, path) catch return error.WorkspaceFailed;
    }

    const captured = kernel.process.runCapture(ctx.allocator, .{
        .argv = argv.items,
        .cwd = ctx.cwd,
        .max_bytes = 24 * 1024,
    }) catch return error.TaskFailed;
    defer ctx.allocator.free(captured.output);

    const clipped = if (captured.output.len > 1200) captured.output[0..1200] else captured.output;
    const summary = std.fmt.allocPrint(ctx.allocator, "git stage exit {d}\n{s}", .{ captured.exit_code, clipped }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn gitCommit(ctx: Context, args: args_mod.GitCommitArgs) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .git_commit);

    const captured = kernel.process.runCapture(ctx.allocator, .{
        .argv = &.{ "git", "commit", "-m", args.message },
        .cwd = ctx.cwd,
        .max_bytes = 24 * 1024,
    }) catch return error.TaskFailed;
    defer ctx.allocator.free(captured.output);

    const clipped = if (captured.output.len > 1200) captured.output[0..1200] else captured.output;
    const summary = std.fmt.allocPrint(ctx.allocator, "git commit exit {d}\n{s}", .{ captured.exit_code, clipped }) catch return error.WorkspaceFailed;
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
    return runCommandUnchecked(ctx, command);
}

fn runCommandUnchecked(ctx: Context, command: []const u8) AgentToolError!Outcome {
    const mac_sandbox_profile = std.fmt.allocPrint(ctx.allocator, command_policy.mac_sandbox_profile_template, .{ctx.root.path}) catch return error.WorkspaceFailed;
    defer ctx.allocator.free(mac_sandbox_profile);
    if (std.mem.startsWith(u8, command, "wasm-run ")) {
        if (ctx.wasm_run_callback) |cb| {
            const rest = std.mem.trim(u8, command["wasm-run ".len..], &std.ascii.whitespace);
            var iter = std.mem.splitScalar(u8, rest, ' ');
            const wasm_file = iter.next() orelse return error.NotAllowed;

            var args_list: std.ArrayList([]const u8) = .empty;
            defer args_list.deinit(ctx.allocator);
            args_list.append(ctx.allocator, wasm_file) catch return error.WorkspaceFailed;
            while (iter.next()) |arg| {
                if (arg.len == 0) continue;
                args_list.append(ctx.allocator, arg) catch return error.WorkspaceFailed;
            }

            const out_str = cb(ctx.wasm_run_context, ctx.allocator, wasm_file, args_list.items) catch return error.TaskFailed;
            defer ctx.allocator.free(out_str);
            const summary = std.fmt.allocPrint(ctx.allocator, "wasm-run exit 0\n{s}", .{out_str}) catch return error.WorkspaceFailed;
            return .{ .summary = summary };
        } else {
            const summary = ctx.allocator.dupe(u8, "wasm-run not supported in this context.") catch return error.WorkspaceFailed;
            return .{ .summary = summary };
        }
    }

    const checkout_path = command_policy.parseGitCheckoutPath(command);
    var checkout_argv: [4][]const u8 = undefined;
    const grep_args = command_policy.parseGrepNCommand(command);
    var grep_argv: [4][]const u8 = undefined;
    const argv = command_policy.allowedCommandArgvWithExtra(command, ctx.extra_allowed_commands) orelse blk: {
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

    if (ctx.stream_callback != null) {
        const stream_result = kernel.process.runStreaming(ctx.allocator, .{
            .argv = argv,
            .cwd = ctx.cwd,
            .max_bytes = 24 * 1024,
            .on_output = ctx.stream_callback,
            .on_output_context = ctx.stream_context,
            .token = if (ctx.cancel_token) |token| token.* else null,
            .use_mac_sandbox = true,
            .mac_sandbox_profile = mac_sandbox_profile,
        }) catch return error.TaskFailed;
        defer ctx.allocator.free(stream_result.output);
        if (stream_result.cancelled) return error.Cancelled;
        const clipped = if (stream_result.output.len > 1200) stream_result.output[0..1200] else stream_result.output;
        const summary = std.fmt.allocPrint(ctx.allocator, "run_command exit {d}\n{s}", .{ stream_result.exit_code, clipped }) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    }

    const captured = kernel.process.runCapture(ctx.allocator, .{
        .argv = argv,
        .cwd = ctx.cwd,
        .max_bytes = 24 * 1024,
        .use_mac_sandbox = true,
        .mac_sandbox_profile = mac_sandbox_profile,
    }) catch return error.TaskFailed;
    defer ctx.allocator.free(captured.output);

    if (ctx.cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const clipped = if (captured.output.len > 1200) captured.output[0..1200] else captured.output;
    const summary = std.fmt.allocPrint(ctx.allocator, "run_command exit {d}\n{s}", .{ captured.exit_code, clipped }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn replaceFileContent(ctx: Context, args: @import("tools/args.zig").ReplaceFileContentArgs) AgentToolError!Outcome {
    return edit_executor.replaceFileContent(ctx, args);
}

pub fn multiEdit(ctx: Context, args: @import("tools/args.zig").MultiEditArgs) AgentToolError!Outcome {
    return edit_executor.multiEdit(ctx, args);
}

pub fn spawnSubagent(ctx: Context, role: []const u8, prompt: []const u8) AgentToolError!Outcome {
    return subagent_executor.spawnSubagent(ctx, role, prompt);
}

pub fn diffPreview(ctx: Context, path: []const u8, search_block: []const u8, replace_block: []const u8) AgentToolError!Outcome {
    return edit_executor.diffPreview(ctx, path, search_block, replace_block);
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

test "list tree counts requested subtree only" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try tmp.dir.createDirPath(io, "packages/lsp/src");
    try tmp.dir.createDirPath(io, "apps/forge");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("packages/lsp/src/root.zig"), "pub const ok = true;\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("apps/forge/main.zig"), "pub fn main() void {}\n");

    const outcome = try listTree(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .read_only,
    }, "packages/lsp", 3);
    defer allocator.free(outcome.summary);
    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "Tree `packages/lsp` (1 files, 1 dirs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "packages/lsp/src/root.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "apps/forge/main.zig") == null);
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

test "replace_file_content can direct-apply through transaction history" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("sample.txt"), "hello forge\n");

    const EditArg = @import("tools/args.zig").ReplaceFileContentArgs.Edit;
    const edits = [_]EditArg{.{ .search = "hello", .replace = "hi" }};
    const outcome = try replaceFileContent(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .cwd = ".",
        .profile = .propose_and_task,
        .direct_apply_edits = true,
    }, .{
        .path = "sample.txt",
        .edits = &edits,
    });
    defer allocator.free(outcome.summary);

    var snap = try workspace.FileSnapshot.read(allocator, io, root, try workspace.WorkspacePath.parse("sample.txt"));
    defer snap.deinit();
    try std.testing.expectEqualStrings("hi forge\n", snap.content);
    try std.testing.expect(std.mem.indexOf(u8, outcome.summary, "Applied edit") != null);
}

pub fn readManyFiles(ctx: Context, args: @import("tools/args.zig").ReadManyFilesArgs) AgentToolError!Outcome {
    try requireTool(ctx, .read_many_files);
    try checkCancel(ctx);

    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(ctx.allocator);

    for (args.files) |f| {
        if (summary.items.len > 0) {
            appendPrint(ctx.allocator, &summary, "\n---\n", .{}) catch return error.WorkspaceFailed;
        }

        const start_line: ?usize = if (f.start_line) |l| @as(usize, l) else null;
        const end_line: ?usize = if (f.end_line) |l| @as(usize, l) else null;
        const outcome = readFile(ctx, f.path, start_line, end_line) catch |err| {
            appendPrint(ctx.allocator, &summary, "file {s} not found or unreadable: {s}\n", .{ f.path, @errorName(err) }) catch return error.WorkspaceFailed;
            continue;
        };
        defer ctx.allocator.free(outcome.summary);

        appendPrint(ctx.allocator, &summary, "{s}", .{outcome.summary}) catch return error.WorkspaceFailed;
    }

    if (summary.items.len == 0) {
        return .{ .summary = ctx.allocator.dupe(u8, "no files read") catch return error.WorkspaceFailed };
    }

    return .{ .summary = summary.toOwnedSlice(ctx.allocator) catch return error.WorkspaceFailed };
}

pub fn lspDefinition(ctx: Context, path: []const u8, line: u32, character: u32) AgentToolError!Outcome {
    return lsp_executor.definition(ctx, path, line, character);
}

pub fn lspHover(ctx: Context, path: []const u8, line: u32, character: u32) AgentToolError!Outcome {
    return lsp_executor.hover(ctx, path, line, character);
}

pub fn lspDocumentSymbols(ctx: Context, path: []const u8) AgentToolError!Outcome {
    return lsp_executor.documentSymbols(ctx, path);
}

pub fn lspDiagnostics(ctx: Context, path: []const u8) AgentToolError!Outcome {
    return lsp_executor.diagnostics(ctx, path);
}

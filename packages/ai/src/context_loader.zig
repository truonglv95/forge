const std = @import("std");
const context = @import("context.zig");
const context_retrieval = @import("context_retrieval.zig");
const context_supplement = @import("context_supplement.zig");
const codebase_search = @import("codebase_search.zig");
const context_rank = @import("context_rank.zig");
const context_rerank = @import("context_rerank.zig");
const docs_loader = @import("docs_loader.zig");
const scope_resolver = @import("scope_resolver.zig");
const web_fetcher = @import("web_fetcher.zig");
const agent_memory = @import("agent_memory.zig");
const import_graph = @import("import_graph.zig");
const workspace = @import("forge-workspace");

pub const AttachmentInput = struct {
    kind: enum { text_snippet, image },
    label: []const u8,
    text: ?[]const u8 = null,
    stored_path: ?[]const u8 = null,
};

pub const LoadOptions = struct {
    max_bytes: usize = 1024 * 1024,
    intent: ?[]const u8 = null,
    explicit_files: []const []const u8 = &.{},
    active_file: ?[]const u8 = null,
    attachments: []const AttachmentInput = &.{},
    include_project_rules: bool = true,
    workspace_cwd: ?[]const u8 = null,
    recent_files: []const []const u8 = &.{},
    include_pre_retrieval: bool = true,
    include_git_diff: bool = true,
    fused_ranking: bool = true,
    include_recent_files: bool = true,
    include_semantic_search: bool = true,
    auto_semantic_search: bool = true,
    include_import_graph: bool = true,
    include_diagnostics: bool = true,
    include_lsp_context: bool = true,
    import_max_files: usize = 12,
    import_preview_bytes: usize = 2048,
    supplement: context_supplement.Supplement = .{},
    prefer_gemini_embeddings: bool = true,
    environ_map: ?*const std.process.Environ.Map = null,
    allow_rebuild: bool = true,
    retrieval_max_chunks: usize = 12,
    recent_file_limit: usize = 5,
    recent_file_preview_bytes: usize = 4096,
    include_agent_memory: bool = true,
    memory_max_entries: usize = 8,
    memory_max_entry_chars: usize = 512,
    include_web: bool = true,
    web_max_urls: usize = 4,
    web_max_bytes: usize = 32 * 1024,
};

pub const ManifestStatus = enum {
    included,
    truncated,
    rejected,
};

pub const ManifestItem = struct {
    kind: context.BlockType,
    name: []const u8,
    status: ManifestStatus,
    bytes: usize,
    reason: ?[]const u8 = null,
};

/// Copies manifest rows from a built context into `out` (caller owns appended strings).
pub fn collectManifest(
    allocator: std.mem.Allocator,
    builder: *const context.ContextBuilder,
    out: *std.ArrayList(ManifestItem),
) !void {
    for (builder.blocks.items) |block| {
        const status: ManifestStatus = if (block.is_truncated) .truncated else .included;
        try out.append(allocator, .{
            .kind = block.block_type,
            .name = try allocator.dupe(u8, block.name),
            .status = status,
            .bytes = block.content.len,
            .reason = if (block.detail) |detail| try allocator.dupe(u8, detail) else null,
        });
    }

    for (builder.manifest_extras.items) |extra| {
        try out.append(allocator, .{
            .kind = extra.kind,
            .name = try allocator.dupe(u8, extra.name),
            .status = .included,
            .bytes = extra.bytes,
            .reason = try allocator.dupe(u8, extra.detail),
        });
    }

    var reject_it = builder.rejected.iterator();
    while (reject_it.next()) |entry| {
        try out.append(allocator, .{
            .kind = .file,
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .status = .rejected,
            .bytes = 0,
            .reason = try allocator.dupe(u8, entry.value_ptr.*),
        });
    }
}

pub fn freeManifestItems(allocator: std.mem.Allocator, items: *std.ArrayList(ManifestItem)) void {
    for (items.items) |item| {
        allocator.free(item.name);
        if (item.reason) |reason| allocator.free(reason);
    }
    items.deinit(allocator);
    items.* = .empty;
}

pub const rules_paths = struct {
    pub const forge_md = "FORGE.md";
    pub const forge_toml = "forge.toml";
};

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    options: LoadOptions,
) !context.ContextBuilder {
    var builder = context.ContextBuilder.init(allocator, options.max_bytes);

    if (options.include_project_rules) {
        try loadProjectRules(allocator, io, root, &builder);
    }

    if (options.intent) |intent| {
        try builder.addBlock(.intent, "intent", intent);
    }

    if (options.include_agent_memory) {
        try loadMemoryBlock(allocator, io, root, options, &builder);
    }

    if (options.include_git_diff) {
        if (options.workspace_cwd) |cwd| {
            try loadGitDiffBlock(allocator, cwd, &builder);
        }
    }

    if (options.include_pre_retrieval and !(options.fused_ranking and options.intent != null)) {
        if (options.intent) |intent| {
            try loadRetrievalBlock(allocator, io, root, intent, options, &builder);
        }
    }

    if (options.include_recent_files) {
        if (!shouldSkipOptionalBlock(&builder, .recent)) {
            try loadRecentFileBlocks(allocator, io, root, options, &builder);
        } else {
            try noteSkippedBlock(allocator, &builder, .recent, "recent:workspace");
        }
    }

    if (options.include_diagnostics) {
        try loadDiagnosticsBlock(allocator, options, &builder);
    }

    const seed_paths = try collectSeedPaths(allocator, options);
    defer freePathSlice(allocator, seed_paths);

    if (options.include_import_graph) {
        if (!shouldSkipOptionalBlock(&builder, .imports)) {
            try loadImportGraphBlock(allocator, io, root, seed_paths, options, &builder);
        } else {
            try noteSkippedBlock(allocator, &builder, .imports, "imports:neighbors");
        }
    }

    var resolved = try scope_resolver.resolve(allocator, io, root, options.explicit_files);
    defer scope_resolver.freeResolved(allocator, &resolved);

    if (resolved.include_docs or resolved.docs_files.len > 0) {
        if (!shouldSkipOptionalBlock(&builder, .docs)) {
            try loadDocsBlocks(allocator, io, root, &resolved, &builder);
        } else {
            try noteSkippedBlock(allocator, &builder, .docs, "docs:project");
        }
    }

    if (options.include_web and (resolved.include_web or resolved.web_urls.len > 0)) {
        if (!shouldSkipOptionalBlock(&builder, .web)) {
            try loadWebBlocks(allocator, io, root, options, &resolved, &builder);
        } else {
            try noteSkippedBlock(allocator, &builder, .web, "web:external");
        }
    }

    if (options.include_semantic_search and options.intent != null) {
        const run_semantic = resolved.include_codebase or options.auto_semantic_search;
        if (run_semantic) {
            if (options.fused_ranking) {
                const auto_only = !resolved.include_codebase;
                if (!auto_only or !shouldSkipOptionalBlock(&builder, .fused)) {
                    try loadFusedBlock(allocator, io, root, options.intent.?, options, resolved, seed_paths, &builder, resolved.include_codebase);
                } else {
                    try noteSkippedBlock(allocator, &builder, .fused, "context:fused-rrf");
                }
            } else {
                const auto_only = !resolved.include_codebase;
                if (!auto_only or !shouldSkipOptionalBlock(&builder, .semantic)) {
                    try loadSemanticBlock(allocator, io, root, options.intent.?, options, resolved.files, &builder, resolved.include_codebase);
                } else {
                    try noteSkippedBlock(allocator, &builder, .semantic, "semantic:@codebase");
                }
            }
        }
    } else if (options.fused_ranking and options.intent != null and options.include_pre_retrieval) {
        if (!shouldSkipOptionalBlock(&builder, .fused)) {
            try loadFusedBlock(allocator, io, root, options.intent.?, options, resolved, seed_paths, &builder, false);
        } else {
            try noteSkippedBlock(allocator, &builder, .fused, "context:fused-rrf");
        }
    }

    if (options.include_lsp_context) {
        try loadLspBlock(allocator, options, &builder);
    }

    for (resolved.files) |file_path| {
        if (std.mem.startsWith(u8, file_path, scope_resolver.folder_prefix)) continue;
        if (std.mem.eql(u8, file_path, scope_resolver.codebase_marker)) continue;
        if (std.mem.eql(u8, file_path, scope_resolver.docs_marker)) continue;
        if (std.mem.startsWith(u8, file_path, scope_resolver.docs_file_prefix)) continue;
        if (std.mem.eql(u8, file_path, scope_resolver.web_marker)) continue;
        if (std.mem.startsWith(u8, file_path, scope_resolver.web_url_prefix)) continue;
        try loadExplicitFile(allocator, io, root, &builder, file_path);
    }

    if (options.active_file) |active_path| {
        if (!pathAlreadyLoaded(&builder, resolved.files, active_path)) {
            try loadExplicitFile(allocator, io, root, &builder, active_path);
        }
    }

    for (options.attachments) |attachment| {
        try loadAttachment(allocator, &builder, attachment);
    }

    return builder;
}

fn loadWebBlocks(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    options: LoadOptions,
    resolved: *const scope_resolver.ResolvedScope,
    builder: *context.ContextBuilder,
) !void {
    const urls = web_fetcher.collectTargetUrls(
        allocator,
        resolved.include_web,
        resolved.web_urls,
        options.intent,
        options.web_max_urls,
    ) catch return;
    defer web_fetcher.freeUrlList(allocator, urls);
    if (urls.len == 0) return;

    var pages: std.ArrayList(web_fetcher.FetchedPage) = .empty;
    defer {
        for (pages.items) |page| web_fetcher.freePage(allocator, page);
        pages.deinit(allocator);
    }
    errdefer {
        // The unconditional defer owns cleanup.
    }

    for (urls) |url| {
        const page = web_fetcher.fetchUrl(allocator, io, root, url, .{
            .max_bytes = options.web_max_bytes,
        }) catch {
            try builder.addManifestExtra(.web, url, "fetch failed", 0);
            continue;
        };
        const detail = if (page.from_cache) "cached web page" else "fetched web page";
        try builder.addManifestExtra(.web, url, detail, page.text.len);
        try pages.append(allocator, page);
    }

    if (pages.items.len == 0) return;

    const block = web_fetcher.formatWebBlock(allocator, pages.items) catch return;
    if (block) |text| {
        defer allocator.free(text);
        var detail_buf: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{d} web page(s)", .{pages.items.len}) catch "external web docs";
        try builder.addBlockWithDetail(.web, "web:external", text, detail);
    }
}

fn loadMemoryBlock(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    options: LoadOptions,
    builder: *context.ContextBuilder,
) !void {
    var list = workspace.agent_memory.listEntries(allocator, io, root) catch return;
    defer list.deinit();
    if (list.items.len == 0) return;

    const selected = agent_memory.selectForIntent(allocator, list.items, options.intent, .{
        .max_entries = options.memory_max_entries,
        .max_entry_chars = options.memory_max_entry_chars,
    }) catch return;
    defer agent_memory.freeScoredEntries(allocator, selected);
    if (selected.len == 0) return;

    for (selected) |item| {
        try builder.addManifestExtra(.memory, item.entry.id, item.detail, item.entry.content.len);
    }

    const block = agent_memory.formatBlock(allocator, selected, .{
        .max_entries = options.memory_max_entries,
        .max_entry_chars = options.memory_max_entry_chars,
    }) catch return;
    if (block) |text| {
        defer allocator.free(text);
        var detail_buf: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{d} memory entr(y/ies) selected", .{selected.len}) catch "agent memory";
        try builder.addBlockWithDetail(.memory, "memory:agent", text, detail);
    }
}

fn shouldSkipOptionalBlock(builder: *const context.ContextBuilder, btype: context.BlockType) bool {
    const tier = context_rank.blockTier(btype);
    return !context_rank.hasBudgetFor(tier, builder.used_bytes, builder.max_bytes);
}

fn noteSkippedBlock(allocator: std.mem.Allocator, builder: *context.ContextBuilder, btype: context.BlockType, name: []const u8) !void {
    const reason = try context_rank.formatSkipReason(allocator, btype);
    defer allocator.free(reason);
    try builder.addManifestExtra(btype, name, reason, 0);
}

fn markSeenPath(allocator: std.mem.Allocator, seen: *std.StringHashMap(void), path: []const u8) !void {
    const owned = try allocator.dupe(u8, path);
    const gop = try seen.getOrPut(owned);
    if (gop.found_existing) allocator.free(owned);
}

fn loadDocsBlocks(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    resolved: *const scope_resolver.ResolvedScope,
    builder: *context.ContextBuilder,
) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    errdefer {
        // The unconditional defer owns cleanup.
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    if (resolved.include_docs) {
        const collected = docs_loader.collectWorkspaceDocs(allocator, io, root, docs_loader.max_doc_files) catch return;
        defer docs_loader.freePaths(allocator, collected);
        for (collected) |path| {
            if (seen.contains(path)) continue;
            try markSeenPath(allocator, &seen, path);
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
    }

    for (resolved.docs_files) |path| {
        if (seen.contains(path)) continue;
        try markSeenPath(allocator, &seen, path);
        try paths.append(allocator, try allocator.dupe(u8, path));
    }

    if (paths.items.len == 0) return;

    var previews: std.ArrayList([]const u8) = .empty;
    defer {
        for (previews.items) |preview| allocator.free(preview);
        previews.deinit(allocator);
    }

    for (paths.items) |path| {
        try builder.addManifestExtra(.docs, path, "project documentation", 0);
        const wp = workspace.WorkspacePath.parse(path) catch {
            try previews.append(allocator, try allocator.dupe(u8, ""));
            continue;
        };
        var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch {
            try previews.append(allocator, try allocator.dupe(u8, ""));
            continue;
        };
        defer snap.deinit();
        const take = @min(snap.content.len, docs_loader.max_doc_bytes);
        var preview_buf: std.ArrayList(u8) = .empty;
        defer preview_buf.deinit(allocator);
        try preview_buf.appendSlice(allocator, snap.content[0..take]);
        if (take < snap.content.len) {
            try preview_buf.appendSlice(allocator, "\n... [preview truncated]\n");
        }
        try previews.append(allocator, try preview_buf.toOwnedSlice(allocator));
    }

    const block = docs_loader.formatDocsBlock(allocator, paths.items, previews.items) catch return;
    if (block) |text| {
        defer allocator.free(text);
        var detail_buf: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{d} doc file(s)", .{paths.items.len}) catch "project docs";
        try builder.addBlockWithDetail(.docs, "docs:project", text, detail);
    }
}

fn pathAlreadyLoaded(
    builder: *const context.ContextBuilder,
    explicit_files: []const []const u8,
    path: []const u8,
) bool {
    for (explicit_files) |file_path| {
        if (std.mem.eql(u8, file_path, scope_resolver.codebase_marker)) continue;
        if (std.mem.eql(u8, file_path, scope_resolver.docs_marker)) continue;
        if (std.mem.startsWith(u8, file_path, scope_resolver.docs_file_prefix)) continue;
        if (std.mem.eql(u8, file_path, scope_resolver.web_marker)) continue;
        if (std.mem.startsWith(u8, file_path, scope_resolver.web_url_prefix)) continue;
        if (std.mem.startsWith(u8, file_path, scope_resolver.folder_prefix)) continue;
        if (std.mem.eql(u8, file_path, path)) return true;
    }
    for (builder.blocks.items) |block| {
        if (block.block_type == .file and std.mem.eql(u8, block.name, path)) return true;
    }
    return false;
}

fn loadAttachment(allocator: std.mem.Allocator, builder: *context.ContextBuilder, attachment: AttachmentInput) !void {
    var name_buf: [512]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "attachment:{s}", .{attachment.label}) catch attachment.label;

    switch (attachment.kind) {
        .text_snippet => {
            const text = attachment.text orelse return;
            try builder.addBlock(.attachment, name, text);
        },
        .image => {
            var content_buf: [768]u8 = undefined;
            const content = if (attachment.stored_path) |stored|
                std.fmt.bufPrint(&content_buf, "[Image attachment: {s} — sent to vision model]", .{stored}) catch
                    "[Image attachment — sent to vision model]"
            else
                "[Image attachment — no stored file]";
            try builder.addBlock(.attachment, name, content);
        },
    }
    _ = allocator;
}

fn loadOptionalRulesBlock(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    builder: *context.ContextBuilder,
    rel_path: []const u8,
) !void {
    const wp = workspace.WorkspacePath.parse(rel_path) catch return;
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer snap.deinit();
    if (snap.content.len == 0) return;
    try builder.addBlock(.rules, rel_path, snap.content);
}

pub fn loadProjectRules(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    builder: *context.ContextBuilder,
) !void {
    try loadOptionalRulesBlock(allocator, io, root, builder, rules_paths.forge_md);
    try loadOptionalRulesBlock(allocator, io, root, builder, rules_paths.forge_toml);
    try loadOptionalRulesBlock(allocator, io, root, builder, ".cursorrules");
    try loadOptionalRulesBlock(allocator, io, root, builder, "AGENTS.md");
    try loadCursorRulesDirectory(allocator, io, root, builder);
}

fn loadCursorRulesDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    builder: *context.ContextBuilder,
) !void {
    var walker = root.dir.walk(allocator) catch return;
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, ".cursor/rules/")) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md") and !std.mem.endsWith(u8, entry.path, ".mdc")) continue;
        try loadOptionalRulesBlock(allocator, io, root, builder, entry.path);
    }
}

fn loadExplicitFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    builder: *context.ContextBuilder,
    file_path: []const u8,
) !void {
    const wp = workspace.WorkspacePath.parse(file_path) catch {
        try builder.rejected.put(try allocator.dupe(u8, file_path), "Invalid workspace path");
        return;
    };

    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch |err| {
        const reason = switch (err) {
            error.FileNotFound => "File not found",
            else => "Failed to read file",
        };
        try builder.rejected.put(try allocator.dupe(u8, file_path), reason);
        return;
    };
    defer snap.deinit();

    try builder.addBlock(.file, file_path, snap.content);
}

fn loadGitDiffBlock(allocator: std.mem.Allocator, workspace_cwd: []const u8, builder: *context.ContextBuilder) !void {
    const diff_text = workspace.git_diff.captureWorkingDiff(allocator, workspace_cwd, .{
        .max_bytes = @min(32 * 1024, builder.max_bytes -| builder.used_bytes),
    }) catch return;
    if (diff_text) |text| {
        defer allocator.free(text);
        try builder.addBlock(.git_diff, "git:working-tree", text);
    }
}

fn loadRetrievalBlock(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    options: LoadOptions,
    builder: *context.ContextBuilder,
) !void {
    const skip = collectLoadedPaths(allocator, builder, options) catch return;
    defer {
        for (skip) |path| allocator.free(path);
        allocator.free(skip);
    }

    const block = context_retrieval.retrieveFromIntent(allocator, io, root, intent, skip, .{
        .max_chunks = options.retrieval_max_chunks,
    }) catch return;
    if (block) |text| {
        defer allocator.free(text);
        try builder.addBlockWithDetail(.retrieval, "retrieval:intent-search", text, "keyword grep pre-retrieval");
    }
}

fn appendOwnedRerankInput(
    allocator: std.mem.Allocator,
    inputs: *std.ArrayList(context_rerank.Input),
    item: context_rerank.Input,
) !void {
    try inputs.append(allocator, .{
        .path = try allocator.dupe(u8, item.path),
        .line_start = item.line_start,
        .line_end = item.line_end,
        .text = try allocator.dupe(u8, item.text),
        .symbol = if (item.symbol.len > 0) try allocator.dupe(u8, item.symbol) else "",
        .source = item.source,
        .source_score = item.source_score,
        .source_rank = item.source_rank,
    });
}

fn loadFusedBlock(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    options: LoadOptions,
    resolved: scope_resolver.ResolvedScope,
    seed_paths: []const []const u8,
    builder: *context.ContextBuilder,
    explicit_codebase: bool,
) !void {
    const skip = collectLoadedPathsFrom(allocator, builder, resolved.files, options.active_file) catch return;
    defer {
        for (skip) |path| allocator.free(path);
        allocator.free(skip);
    }

    const pool_k = options.retrieval_max_chunks * 2;

    var inputs: std.ArrayList(context_rerank.Input) = .empty;
    errdefer {
        for (inputs.items) |item| {
            allocator.free(item.path);
            allocator.free(item.text);
            if (item.symbol.len > 0) allocator.free(item.symbol);
        }
        inputs.deinit(allocator);
    }

    if (options.include_pre_retrieval) {
        const keyword = context_retrieval.collectFromIntent(allocator, io, root, intent, skip, .{
            .max_chunks = pool_k,
        }) catch @as([]context_retrieval.CandidateChunk, &.{});
        defer if (keyword.len > 0) context_retrieval.freeCandidates(allocator, keyword);

        var max_kw_score: u32 = 1;
        for (keyword) |chunk| max_kw_score = @max(max_kw_score, chunk.score);

        for (keyword, 0..) |chunk, rank| {
            try appendOwnedRerankInput(allocator, &inputs, .{
                .path = chunk.path,
                .line_start = chunk.line_start,
                .line_end = chunk.line_end,
                .text = chunk.preview,
                .source = .keyword,
                .source_score = @as(f32, @floatFromInt(chunk.score)) / @as(f32, @floatFromInt(max_kw_score)),
                .source_rank = rank,
            });
        }
    }

    if (options.include_semantic_search) {
        const semantic = codebase_search.search(allocator, io, root, intent, skip, .{
            .top_k = pool_k,
            .prefer_gemini = options.prefer_gemini_embeddings,
            .environ_map = options.environ_map,
            .allow_rebuild = options.allow_rebuild,
        }) catch @as([]codebase_search.ScoredChunk, &.{});
        defer if (semantic.len > 0) codebase_search.freeResults(allocator, semantic);

        for (semantic, 0..) |item, rank| {
            try appendOwnedRerankInput(allocator, &inputs, .{
                .path = item.path,
                .line_start = item.line_start,
                .line_end = item.line_end,
                .text = item.text,
                .symbol = item.symbol orelse "",
                .source = .semantic,
                .source_score = item.score,
                .source_rank = rank,
            });
        }
    }

    if (inputs.items.len == 0) return;

    defer {
        for (inputs.items) |item| {
            allocator.free(item.path);
            allocator.free(item.text);
            if (item.symbol.len > 0) allocator.free(item.symbol);
        }
        inputs.deinit(allocator);
    }

    const intent_terms = context_retrieval.intentTerms(allocator, intent, 6) catch &[_][]const u8{};
    defer context_retrieval.freeIntentTerms(allocator, intent_terms);

    const git_paths = if (options.workspace_cwd) |cwd|
        workspace.git_diff.listChangedPaths(allocator, cwd, 32) catch &[_][]const u8{}
    else
        &[_][]const u8{};
    defer workspace.git_diff.freePaths(allocator, git_paths);

    const import_paths = if (options.include_import_graph and seed_paths.len > 0)
        import_graph.collectNeighborPaths(allocator, io, root, seed_paths, skip, .{
            .max_files = options.import_max_files,
            .preview_bytes = 0,
        }) catch &[_][]const u8{}
    else
        &[_][]const u8{};
    defer if (import_paths.len > 0) import_graph.freePaths(allocator, import_paths);

    const signals = context_rerank.Signals{
        .active_file = options.active_file,
        .scoped_paths = resolved.files,
        .recent_paths = options.recent_files,
        .import_paths = import_paths,
        .git_paths = git_paths,
        .intent_terms = intent_terms,
    };

    const hits = context_rerank.rerank(allocator, inputs.items, signals, .{
        .max_results = options.retrieval_max_chunks,
    }) catch return;
    defer context_rerank.freeHits(allocator, hits);

    for (hits) |hit| {
        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}:{d}-{d}", .{ hit.path, hit.line_start, hit.line_end }) catch hit.path;
        try builder.addManifestExtra(.fused, name, hit.detail, hit.text.len);
    }

    const block = context_rerank.formatBlock(allocator, hits) catch return;
    if (block) |text| {
        defer allocator.free(text);
        const source = if (explicit_codebase)
            "RRF fused (@codebase + keyword)"
        else
            "RRF fused (auto semantic + keyword)";
        try builder.addBlockWithDetail(.fused, "context:fused-rrf", text, source);
    }
}

fn loadSemanticBlock(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    options: LoadOptions,
    scoped_files: []const []const u8,
    builder: *context.ContextBuilder,
    explicit_codebase: bool,
) !void {
    const skip = collectLoadedPathsFrom(allocator, builder, scoped_files, options.active_file) catch return;
    defer {
        for (skip) |path| allocator.free(path);
        allocator.free(skip);
    }

    const results = codebase_search.search(allocator, io, root, intent, skip, .{
        .top_k = options.retrieval_max_chunks,
        .prefer_gemini = options.prefer_gemini_embeddings,
        .environ_map = options.environ_map,
        .allow_rebuild = options.allow_rebuild,
    }) catch return;
    defer codebase_search.freeResults(allocator, results);

    for (results) |item| {
        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}:{d}-{d}", .{ item.path, item.line_start, item.line_end }) catch item.path;
        var detail_buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "semantic score {d:.3}", .{item.score}) catch "semantic hit";
        try builder.addManifestExtra(.semantic, name, detail, item.text.len);
    }

    const block = codebase_search.formatBlock(allocator, results) catch return;
    if (block) |text| {
        defer allocator.free(text);
        const source = if (explicit_codebase) "explicit @codebase" else "auto semantic (intent)";
        try builder.addBlockWithDetail(.semantic, "semantic:@codebase", text, source);
    }
}

fn collectLoadedPathsFrom(
    allocator: std.mem.Allocator,
    builder: *const context.ContextBuilder,
    explicit_files: []const []const u8,
    active_file: ?[]const u8,
) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (explicit_files) |path| {
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    if (active_file) |path| {
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    for (builder.blocks.items) |block| {
        if (block.block_type == .file or block.block_type == .recent) {
            try paths.append(allocator, try allocator.dupe(u8, block.name));
        }
    }

    return try paths.toOwnedSlice(allocator);
}

fn loadRecentFileBlocks(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    options: LoadOptions,
    builder: *context.ContextBuilder,
) !void {
    const skip = collectLoadedPaths(allocator, builder, options) catch return;
    defer {
        for (skip) |path| allocator.free(path);
        allocator.free(skip);
    }

    const recent_paths = workspace.recent_files.mergeRecentPaths(allocator, io, root, options.recent_files, .{
        .limit = options.recent_file_limit,
        .exclude = skip,
    }) catch return;
    defer workspace.recent_files.freePaths(allocator, recent_paths);

    for (recent_paths) |path| {
        if (pathAlreadyInBuilder(builder, path)) continue;
        try loadRecentPreview(allocator, io, root, builder, path, options.recent_file_preview_bytes);
    }
}

fn collectLoadedPaths(allocator: std.mem.Allocator, builder: *const context.ContextBuilder, options: LoadOptions) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (options.explicit_files) |path| {
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    if (options.active_file) |path| {
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    for (builder.blocks.items) |block| {
        if (block.block_type == .file or block.block_type == .recent) {
            try paths.append(allocator, try allocator.dupe(u8, block.name));
        }
    }

    return try paths.toOwnedSlice(allocator);
}

fn pathAlreadyInBuilder(builder: *const context.ContextBuilder, path: []const u8) bool {
    for (builder.blocks.items) |block| {
        if ((block.block_type == .file or block.block_type == .recent) and std.mem.eql(u8, block.name, path)) {
            return true;
        }
    }
    return false;
}

fn loadRecentPreview(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    builder: *context.ContextBuilder,
    file_path: []const u8,
    preview_bytes: usize,
) !void {
    const wp = workspace.WorkspacePath.parse(file_path) catch return;
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return;
    defer snap.deinit();

    const take = @min(snap.content.len, preview_bytes);
    var preview_buf: std.ArrayList(u8) = .empty;
    defer preview_buf.deinit(allocator);
    try preview_buf.appendSlice(allocator, snap.content[0..take]);
    if (take < snap.content.len) {
        try preview_buf.appendSlice(allocator, "\n... [preview truncated]\n");
    }

    try builder.addBlock(.recent, file_path, preview_buf.items);
}

fn collectSeedPaths(allocator: std.mem.Allocator, options: LoadOptions) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (options.explicit_files) |path| {
        if (std.mem.eql(u8, path, scope_resolver.codebase_marker)) continue;
        if (std.mem.eql(u8, path, scope_resolver.docs_marker)) continue;
        if (std.mem.startsWith(u8, path, scope_resolver.docs_file_prefix)) continue;
        if (std.mem.eql(u8, path, scope_resolver.web_marker)) continue;
        if (std.mem.startsWith(u8, path, scope_resolver.web_url_prefix)) continue;
        if (std.mem.startsWith(u8, path, scope_resolver.folder_prefix)) continue;
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    if (options.active_file) |path| {
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    return try paths.toOwnedSlice(allocator);
}

fn freePathSlice(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn loadDiagnosticsBlock(allocator: std.mem.Allocator, options: LoadOptions, builder: *context.ContextBuilder) !void {
    for (options.supplement.diagnostics) |entry| {
        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}:{d}:{d}", .{ entry.path, entry.line + 1, entry.character + 1 }) catch entry.path;
        var detail_buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{s}: {s}", .{ entry.severity, entry.message }) catch entry.severity;
        try builder.addManifestExtra(.diagnostic, name, detail, entry.message.len);
    }

    const block = context_supplement.formatDiagnosticsBlock(allocator, options.supplement.diagnostics) catch return;
    if (block) |text| {
        defer allocator.free(text);
        var detail_buf: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{d} diagnostic(s) from IDE", .{options.supplement.diagnostics.len}) catch "IDE diagnostics";
        try builder.addBlockWithDetail(.diagnostic, "diagnostics:workspace", text, detail);
    }
}

fn loadLspBlock(allocator: std.mem.Allocator, options: LoadOptions, builder: *context.ContextBuilder) !void {
    for (options.supplement.lsp_hints) |hint| {
        var name_buf: [512]u8 = undefined;
        const kind = switch (hint.kind) {
            .definition => "definition",
            .reference => "reference",
        };
        const name = std.fmt.bufPrint(&name_buf, "{s}:{s}:{d}:{d}", .{ kind, hint.path, hint.line + 1, hint.character + 1 }) catch hint.path;
        try builder.addManifestExtra(.lsp, name, kind, 0);
    }

    const block = context_supplement.formatLspBlock(allocator, options.supplement) catch return;
    if (block) |text| {
        defer allocator.free(text);
        const detail = if (options.supplement.hover_text) |hover| hover else "LSP cursor context";
        try builder.addBlockWithDetail(.lsp, "lsp:cursor-context", text, detail);
    }
}

fn loadImportGraphBlock(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    seed_paths: []const []const u8,
    options: LoadOptions,
    builder: *context.ContextBuilder,
) !void {
    if (seed_paths.len == 0) return;

    const skip = collectLoadedPaths(allocator, builder, options) catch return;
    defer freePathSlice(allocator, skip);

    const neighbors = import_graph.collectNeighborPaths(allocator, io, root, seed_paths, skip, .{
        .max_files = options.import_max_files,
        .preview_bytes = options.import_preview_bytes,
    }) catch return;
    defer import_graph.freePaths(allocator, neighbors);
    if (neighbors.len == 0) return;

    var previews: std.ArrayList([]const u8) = .empty;
    defer {
        for (previews.items) |preview| allocator.free(preview);
        previews.deinit(allocator);
    }

    for (neighbors) |path| {
        try builder.addManifestExtra(.imports, path, "imports:auto-neighbors", 0);
        const wp = workspace.WorkspacePath.parse(path) catch {
            try previews.append(allocator, try allocator.dupe(u8, ""));
            continue;
        };
        var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch {
            try previews.append(allocator, try allocator.dupe(u8, ""));
            continue;
        };
        defer snap.deinit();
        const take = @min(snap.content.len, options.import_preview_bytes);
        var preview_buf: std.ArrayList(u8) = .empty;
        defer preview_buf.deinit(allocator);
        try preview_buf.appendSlice(allocator, snap.content[0..take]);
        if (take < snap.content.len) {
            try preview_buf.appendSlice(allocator, "\n... [preview truncated]\n");
        }
        try previews.append(allocator, try allocator.dupe(u8, preview_buf.items));
    }

    const block = import_graph.formatImportBlock(allocator, neighbors, previews.items) catch return;
    if (block) |text| {
        defer allocator.free(text);
        var detail_buf: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{d} import neighbor(s) (auto)", .{neighbors.len}) catch "imports:auto-neighbors";
        try builder.addBlockWithDetail(.imports, "imports:neighbors", text, detail);
    }
}

pub fn renderManifestHuman(builder: *const context.ContextBuilder, writer: *std.Io.Writer) !void {
    for (builder.blocks.items) |block| {
        const tag = if (block.is_truncated) "TRUNCATED" else "INCLUDED";
        try writer.print("[{s}] {s} ({s}, {d} bytes)\n", .{
            tag,
            block.name,
            @tagName(block.block_type),
            block.content.len,
        });
    }

    var reject_it = builder.rejected.iterator();
    while (reject_it.next()) |entry| {
        try writer.print("[REJECTED] {s} (file) — {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    try writer.print("\nTotal budget used: {d} / {d} bytes\n", .{ builder.used_bytes, builder.max_bytes });
}

pub fn renderManifestJson(builder: *const context.ContextBuilder, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"schema_version\":1,\"items\":[");
    var first = true;
    for (builder.blocks.items) |block| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.print(
            "{{\"kind\":\"{s}\",\"name\":\"{s}\",\"included\":true,\"truncated\":{},\"bytes\":{d}}}",
            .{ @tagName(block.block_type), block.name, block.is_truncated, block.content.len },
        );
    }

    var reject_it = builder.rejected.iterator();
    while (reject_it.next()) |entry| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.print(
            "{{\"kind\":\"file\",\"name\":\"{s}\",\"included\":false,\"reason\":\"{s}\",\"bytes\":0}}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
    }

    try writer.print("],\"budget_bytes\":{d},\"used_bytes\":{d}}}\n", .{ builder.max_bytes, builder.used_bytes });
}

test "collectManifest includes blocks and rejections" {
    const allocator = std.testing.allocator;
    var builder = context.ContextBuilder.init(allocator, 1000);
    defer builder.deinit();

    try builder.addBlock(.rules, "FORGE.md", "project rules");
    try builder.addBlock(.file, ".env", "SECRET=1");
    try builder.rejected.put(try allocator.dupe(u8, "missing.zig"), "File not found");

    var items: std.ArrayList(ManifestItem) = .empty;
    defer freeManifestItems(allocator, &items);
    try collectManifest(allocator, &builder, &items);

    try std.testing.expectEqual(@as(usize, 3), items.items.len);

    var found_rules = false;
    var found_env_reject = false;
    var found_missing = false;
    for (items.items) |item| {
        if (std.mem.eql(u8, item.name, "FORGE.md")) {
            found_rules = true;
            try std.testing.expect(item.status == .included);
        }
        if (std.mem.eql(u8, item.name, ".env")) {
            found_env_reject = true;
            try std.testing.expect(item.status == .rejected);
        }
        if (std.mem.eql(u8, item.name, "missing.zig")) {
            found_missing = true;
            try std.testing.expect(item.reason != null);
        }
    }
    try std.testing.expect(found_rules and found_env_reject and found_missing);
}

test "import graph auto-neighbors respect budget" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("main.zig"),
        \\const helper = @import("helper.zig");
        \\pub fn main() void { _ = helper.answer; }
    );
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("helper.zig"),
        \\pub const answer: u32 = 42;
    );

    var builder = try build(allocator, io, root, .{
        .max_bytes = 8 * 1024,
        .intent = "use helper",
        .active_file = "main.zig",
        .include_import_graph = true,
        .include_semantic_search = false,
        .auto_semantic_search = false,
        .include_web = false,
        .include_recent_files = false,
        .include_git_diff = false,
        .include_project_rules = false,
        .include_agent_memory = false,
        .include_diagnostics = false,
        .include_lsp_context = false,
    });
    defer builder.deinit();

    try std.testing.expect(builder.used_bytes <= builder.max_bytes);
    var found = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .imports and std.mem.eql(u8, block.name, "imports:neighbors")) found = true;
    }
    try std.testing.expect(found);
}

test "active file is included when not already scoped" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("open.zig"), "pub fn main() {}\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("other.zig"), "const x = 1;\n");

    var builder = try build(allocator, io, root, .{
        .explicit_files = &[_][]const u8{"other.zig"},
        .active_file = "open.zig",
    });
    defer builder.deinit();

    var found_open = false;
    var found_other = false;
    for (builder.blocks.items) |block| {
        if (std.mem.eql(u8, block.name, "open.zig")) found_open = true;
        if (std.mem.eql(u8, block.name, "other.zig")) found_other = true;
    }
    try std.testing.expect(found_open and found_other);
}

test "pre-retrieval adds retrieval block from intent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("auth.zig"), "pub fn authenticate() void {}\n");

    var builder = try build(allocator, io, root, .{
        .intent = "fix authenticate middleware",
        .include_git_diff = false,
        .include_recent_files = false,
    });
    defer builder.deinit();

    var found_fused = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .fused) {
            found_fused = true;
            try std.testing.expect(std.mem.indexOf(u8, block.content, "authenticate") != null);
        }
        if (block.block_type == .retrieval) {
            try std.testing.expect(false); // fused_ranking replaces standalone retrieval
        }
    }
    try std.testing.expect(found_fused);
}

test "legacy retrieval block when fused_ranking disabled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("auth.zig"), "pub fn authenticate() void {}\n");

    var builder = try build(allocator, io, root, .{
        .intent = "fix authenticate middleware",
        .include_git_diff = false,
        .include_recent_files = false,
        .fused_ranking = false,
        .auto_semantic_search = false,
    });
    defer builder.deinit();

    var found_retrieval = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .retrieval) found_retrieval = true;
    }
    try std.testing.expect(found_retrieval);
}

test "semantic block added when @codebase scoped" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("auth.zig"), "pub fn authenticateUser() void {}\n");

    var builder = try build(allocator, io, root, .{
        .intent = "fix authenticate user flow",
        .explicit_files = &[_][]const u8{scope_resolver.codebase_marker},
        .include_git_diff = false,
        .include_recent_files = false,
        .include_pre_retrieval = false,
    });
    defer builder.deinit();

    var found_fused = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .fused) {
            found_fused = true;
            try std.testing.expect(std.mem.indexOf(u8, block.content, "authenticate") != null);
        }
    }
    try std.testing.expect(found_fused);
}

test "@docs scope loads markdown documentation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try tmp.dir.createDirPath(io, "docs/plan");
    try tmp.dir.createDirPath(io, "src");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("docs/plan/phase5.md"), "# Phase 5\ncontext ranking\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("src/main.zig"), "main");

    var builder = try build(allocator, io, root, .{
        .intent = "implement phase 5",
        .explicit_files = &[_][]const u8{scope_resolver.docs_marker},
        .include_git_diff = false,
        .include_recent_files = false,
        .include_pre_retrieval = false,
        .auto_semantic_search = false,
    });
    defer builder.deinit();

    var found_docs = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .docs) {
            found_docs = true;
            try std.testing.expect(std.mem.indexOf(u8, block.content, "Phase 5") != null);
        }
    }
    try std.testing.expect(found_docs);
}

test "agent memory block injected when memories exist" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    const memory_id = try workspace.agent_memory.appendEntry(allocator, io, root, .{
        .kind = .decision,
        .content = "Use context_rerank for fused retrieval",
        .tags = &[_][]const u8{"context"},
        .source = "agent",
        .timestamp_ms = 100,
    });
    defer allocator.free(memory_id);

    var builder = try build(allocator, io, root, .{
        .intent = "improve context pipeline",
        .include_git_diff = false,
        .include_recent_files = false,
        .include_pre_retrieval = false,
        .auto_semantic_search = false,
    });
    defer builder.deinit();

    var found_memory = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .memory) {
            found_memory = true;
            try std.testing.expect(std.mem.indexOf(u8, block.content, "context_rerank") != null);
        }
    }
    try std.testing.expect(found_memory);
}

test "@web scope loads cached web documentation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    const url = "https://example.com/docs";
    try root.dir.createDirPath(io, ".forge");
    try root.dir.createDirPath(io, ".forge/cache");
    try root.dir.createDirPath(io, web_fetcher.cache_dir);
    var cache_path_buf: [64]u8 = undefined;
    const cache_rel = std.fmt.bufPrint(&cache_path_buf, "{s}/{x}.txt", .{
        web_fetcher.cache_dir,
        std.hash.Wyhash.hash(0, url),
    }) catch return error.OutOfMemory;
    const cache_body = "# URL: https://example.com/docs\nExample external documentation body\n";
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse(cache_rel), cache_body);

    var builder = try build(allocator, io, root, .{
        .intent = "read example docs",
        .explicit_files = &[_][]const u8{"@web:https://example.com/docs"},
        .include_git_diff = false,
        .include_recent_files = false,
        .include_pre_retrieval = false,
        .auto_semantic_search = false,
        .include_agent_memory = false,
    });
    defer builder.deinit();

    var found_web = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .web) {
            found_web = true;
            try std.testing.expect(std.mem.indexOf(u8, block.content, "Example external documentation") != null);
        }
    }
    try std.testing.expect(found_web);
}

test "build with active file triggers import graph without crashing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.createDirPath(io, "apps");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("lib/util.zig"), "pub fn util() void {}\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("apps/main.zig"),
        \\const util = @import("../lib/util.zig");
        \\pub fn main() void { util.util(); }
    );

    const recent = [_][]const u8{"apps/main.zig"};
    var builder = try build(allocator, io, root, .{
        .intent = "fix the main function",
        .active_file = "apps/main.zig",
        .recent_files = &recent,
        .include_git_diff = false,
        .workspace_cwd = ".",
    });
    defer builder.deinit();

    var found_imports = false;
    var found_neighbor_recent = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .imports) found_imports = true;
        if (block.block_type == .recent and std.mem.eql(u8, block.name, "lib/util.zig")) found_neighbor_recent = true;
    }
    try std.testing.expect(found_imports or found_neighbor_recent);
}

test "fused rerank survives keyword candidate cleanup before rerank" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("auth.zig"), "pub fn authenticateUser() void {}\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("other.zig"), "const x = 1;\n");

    var builder = try build(allocator, io, root, .{
        .intent = "fix authenticate user flow",
        .include_git_diff = false,
        .include_pre_retrieval = true,
        .include_semantic_search = false,
        .fused_ranking = true,
        .workspace_cwd = ".",
    });
    defer builder.deinit();

    var found_fused = false;
    var found_relevant_recent = false;
    for (builder.blocks.items) |block| {
        if (block.block_type == .fused) found_fused = true;
        if (block.block_type == .recent and std.mem.indexOf(u8, block.content, "authenticateUser") != null) found_relevant_recent = true;
    }
    // Retrieval must avoid duplicating a relevant file already supplied by the
    // recent-file layer; either representation satisfies the context contract.
    try std.testing.expect(found_fused or found_relevant_recent);
}

test "cursor-compatible rules files are loaded" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .access_sub_paths = true });
    defer tmp.cleanup();
    const root = workspace.WorkspaceRoot.init(tmp.dir, ".");

    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse(".cursorrules"), "Use zig fmt.\n");
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse("AGENTS.md"), "# Agents\nBe careful.\n");
    tmp.dir.createDirPath(io, ".cursor/rules") catch {};
    try workspace.atomic.replaceFile(io, root, try workspace.WorkspacePath.parse(".cursor/rules/zig.mdc"), "Prefer explicit error sets.\n");

    var builder = try build(allocator, io, root, .{
        .include_git_diff = false,
        .include_pre_retrieval = false,
        .include_semantic_search = false,
        .include_recent_files = false,
        .include_import_graph = false,
    });
    defer builder.deinit();

    var found_cursorrules = false;
    var found_agents = false;
    var found_rule_file = false;
    for (builder.blocks.items) |block| {
        if (block.block_type != .rules) continue;
        if (std.mem.eql(u8, block.name, ".cursorrules")) found_cursorrules = true;
        if (std.mem.eql(u8, block.name, "AGENTS.md")) found_agents = true;
        if (std.mem.eql(u8, block.name, ".cursor/rules/zig.mdc")) found_rule_file = true;
    }
    try std.testing.expect(found_cursorrules and found_agents and found_rule_file);
}

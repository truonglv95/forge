const std = @import("std");
const context = @import("context.zig");
const routing = @import("routing.zig");

pub const Summary = struct {
    has_fused_retrieval: bool = false,
    has_semantic: bool = false,
    preloaded_paths: []const []const u8,
};

pub fn summarize(allocator: std.mem.Allocator, builder: *const context.ContextBuilder) !Summary {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    var has_fused = false;
    var has_semantic = false;

    for (builder.blocks.items) |block| {
        switch (block.block_type) {
            .fused => {
                has_fused = true;
                try appendPathFromName(allocator, &paths, block.name);
            },
            .semantic => has_semantic = true,
            .file => try appendUniquePath(allocator, &paths, block.name),
            else => {},
        }
    }

    return .{
        .has_fused_retrieval = has_fused,
        .has_semantic = has_semantic,
        .preloaded_paths = try paths.toOwnedSlice(allocator),
    };
}

pub fn freeSummary(allocator: std.mem.Allocator, summary: *Summary) void {
    for (summary.preloaded_paths) |path| allocator.free(path);
    allocator.free(summary.preloaded_paths);
    summary.* = .{
        .has_fused_retrieval = false,
        .has_semantic = false,
        .preloaded_paths = &.{},
    };
}

pub fn hasPreloadedRetrieval(builder: *const context.ContextBuilder) bool {
    for (builder.blocks.items) |block| {
        if (block.block_type == .fused or block.block_type == .semantic) return true;
    }
    return false;
}

pub fn formatManifest(allocator: std.mem.Allocator, builder: *const context.ContextBuilder, summary: Summary) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Pre-loaded context manifest:\n");

    for (builder.blocks.items) |block| {
        const line = try std.fmt.allocPrint(allocator, "- [{s}] {s} ({d} bytes)\n", .{
            @tagName(block.block_type),
            block.name,
            block.content.len,
        });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    if (summary.preloaded_paths.len > 0) {
        try out.appendSlice(allocator, "\nKey paths already in context:\n");
        const shown = @min(summary.preloaded_paths.len, 24);
        for (summary.preloaded_paths[0..shown]) |path| {
            const line = try std.fmt.allocPrint(allocator, "- {s}\n", .{path});
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }
        if (summary.preloaded_paths.len > shown) {
            const more = try std.fmt.allocPrint(allocator, "- ... and {d} more\n", .{summary.preloaded_paths.len - shown});
            defer allocator.free(more);
            try out.appendSlice(allocator, more);
        }
    }

    if (summary.has_fused_retrieval or summary.has_semantic) {
        try out.appendSlice(allocator, "\nSemantic + keyword retrieval is already included. Prefer read_file on paths above before repeating codebase_search.\n");
    }

    return try out.toOwnedSlice(allocator);
}

pub fn intentGuidance(intent: routing.TaskIntent) []const u8 {
    return switch (intent) {
        .explore_codebase =>
        \\Task: explore the codebase. For location/status questions, list_tree first, then read_file. Use keyword search, not full sentences.
        ,
        .edit_code =>
        \\Task: implement a code change. Read relevant source files, then call replace_file_content to edit the code directly.
        \\Do not stop at list_tree/read_file when the user asked to build or implement something.
        \\Do not output proposal JSON for direct edit tasks.
        \\Never read __pycache__, .pyc, or other generated/binary artifacts.
        ,
        .debug_failure =>
        \\Task: debug a failure. Prioritize git diff, diagnostics, and reading error-related files before broad search.
        ,
        .plan_change =>
        \\Task: plan a change. Gather architecture context; avoid mutating tools until a proposal is requested.
        ,
        .answer_question =>
        \\Task: answer from existing context. Avoid redundant search when manifest paths already cover the topic.
        ,
    };
}

fn appendPathFromName(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), name: []const u8) !void {
    if (std.mem.indexOfScalar(u8, name, ':')) |colon| {
        try appendUniquePath(allocator, paths, name[0..colon]);
    } else {
        try appendUniquePath(allocator, paths, name);
    }
}

fn appendUniquePath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try paths.append(allocator, try allocator.dupe(u8, path));
}

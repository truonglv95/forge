const std = @import("std");
const context = @import("../context.zig");
const context_manifest = @import("../context_manifest.zig");
const routing = @import("../routing.zig");

pub const Options = struct {
    task_intent: routing.TaskIntent = .explore_codebase,
    preloaded_retrieval: bool = false,
};

pub fn buildExplorePrompt(
    allocator: std.mem.Allocator,
    intent: []const u8,
    builder: *const context.ContextBuilder,
    options: Options,
) ![]u8 {
    var summary = try context_manifest.summarize(allocator, builder);
    defer context_manifest.freeSummary(allocator, &summary);

    const manifest = try context_manifest.formatManifest(allocator, builder, summary);
    defer allocator.free(manifest);

    var prompt = std.Io.Writer.Allocating.init(allocator);
    defer prompt.deinit();
    const writer = &prompt.writer;

    try writer.print("You are a coding agent working inside a Forge workspace.\n", .{});
    try writer.writeAll(context_manifest.intentGuidance(options.task_intent));
    try writer.print("\nUser intent: {s}\n\n", .{intent});

    if (options.preloaded_retrieval) {
        try writer.writeAll(
            \\Retrieval policy: fused semantic + keyword context is pre-loaded below.
            \\Do not call codebase_search for the same intent unless you need different symbols.
            \\
        );
    } else {
        try writer.writeAll(
            \\Use search, codebase_search, list_tree, and read_file to gather facts before answering.
            \\Do not guess file contents.
            \\
        );
    }

    try writer.writeAll(manifest);
    try writer.writeAll("\nContext blocks loaded:\n");

    for (builder.blocks.items) |block| {
        try writer.print("[{s}] {s}\n", .{ @tagName(block.block_type), block.name });
    }

    return prompt.toOwnedSlice();
}

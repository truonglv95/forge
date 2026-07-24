const std = @import("std");
const context = @import("../context.zig");
const context_manifest = @import("../context_manifest.zig");
const routing = @import("../routing.zig");
const prompt_pack = @import("../prompt_pack.zig");

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

    try writer.print("Prompt pack: {s}\n", .{prompt_pack.version});
    try writer.writeAll(prompt_pack.base_constitution);
    try writer.writeAll(prompt_pack.tool_loop_contract);
    try writer.writeAll(context_manifest.intentGuidance(options.task_intent));
    try writer.writeAll(prompt_pack.intentPolicy(options.task_intent));
    try writer.writeAll(prompt_pack.final_answer_checklist);
    try writer.print("\nUser intent: {s}\n\n", .{intent});
    try writer.writeAll(prompt_pack.retrievalPolicy(options.preloaded_retrieval));

    try writer.writeAll(manifest);
    try writer.writeAll("\nContext blocks loaded:\n");

    for (builder.blocks.items) |block| {
        try writer.print("[{s}] {s}\n", .{ @tagName(block.block_type), block.name });
    }

    return prompt.toOwnedSlice();
}

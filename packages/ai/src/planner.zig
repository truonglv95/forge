const std = @import("std");
const provider = @import("provider.zig");
const context = @import("context.zig");
const kernel = @import("forge-kernel");

pub const PlannerError = error{
    GenerationFailed,
    InvalidResponseFormat,
};

pub const Planner = struct {
    allocator: std.mem.Allocator,
    prov: provider.Provider,
    ctx_builder: *const context.ContextBuilder,

    pub fn init(allocator: std.mem.Allocator, prov: provider.Provider, ctx_builder: *const context.ContextBuilder) Planner {
        return .{
            .allocator = allocator,
            .prov = prov,
            .ctx_builder = ctx_builder,
        };
    }

    /// Generates a WorkspaceEdit JSON response by prompting the AI provider
    pub fn plan(self: *Planner, writer: *std.Io.Writer, cancel_token: *const kernel.cancellation.CancellationToken) !void {
        var p_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer p_alloc.deinit();
        const p_writer = &p_alloc.writer;
        try p_writer.writeAll("You are an expert software engineer. Your task is to output a single JSON object matching the WorkspaceEdit schema based on the following intent.\n\n");
        
        try p_writer.writeAll("--- CONTEXT ---\n");
        for (self.ctx_builder.blocks.items) |block| {
            try p_writer.print("[{s}] {s}\n", .{ @tagName(block.block_type), block.name });
            try p_writer.print("{s}\n\n", .{block.content});
        }
        
        try p_writer.writeAll("--- INSTRUCTIONS ---\n");
        try p_writer.writeAll(
            \\Respond ONLY with valid JSON. Do not use markdown blocks.
            \\Schema:
            \\{
            \\  "id": "uuid",
            \\  "description": "Short summary",
            \\  "modifications": [
            \\    { "path": "file.txt", "content": "new contents" }
            \\  ]
            \\}
        );

        // Call the provider
        const prompt_items = p_alloc.writer.buffer[0..p_alloc.writer.end];
        self.prov.ask(self.allocator, prompt_items, writer, cancel_token) catch return error.GenerationFailed;
    }
};

test "Planner execution with FakeProvider" {
    const allocator = std.testing.allocator;
    const fake_provider = @import("fake_provider.zig");
    
    var ctx = context.ContextBuilder.init(allocator, 1024);
    defer ctx.deinit();
    try ctx.addBlock(.intent, "user intent", "Fix the bug");
    
    var mock_llm = fake_provider.FakeProvider.init("{\"id\": \"123\", \"description\": \"mock\"}");
    
    var planner = Planner.init(allocator, mock_llm.providerInterface(), &ctx);
    
    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();
    
    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    const token = cancel_src.getToken();
    
    try planner.plan(&w_alloc.writer, &token);
    
    const out_items = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expectEqualStrings("{\"id\": \"123\", \"description\": \"mock\"}", out_items);
}

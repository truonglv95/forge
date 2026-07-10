const std = @import("std");
const provider = @import("provider.zig");
const context = @import("context.zig");
const conversation = @import("conversation.zig");
const kernel = @import("forge-kernel");

pub const PlannerError = error{
    GenerationFailed,
    InvalidResponseFormat,
};

pub const Planner = struct {
    allocator: std.mem.Allocator,
    prov: provider.Provider,
    ctx_builder: *const context.ContextBuilder,
    history: []const conversation.Turn,
    images: []const provider.ImagePart,

    pub fn init(
        allocator: std.mem.Allocator,
        prov: provider.Provider,
        ctx_builder: *const context.ContextBuilder,
        history: []const conversation.Turn,
        images: []const provider.ImagePart,
    ) Planner {
        return .{
            .allocator = allocator,
            .prov = prov,
            .ctx_builder = ctx_builder,
            .history = history,
            .images = images,
        };
    }

    fn writePromptHeader(self: *Planner, p_writer: *std.Io.Writer, intro: []const u8) provider.ProviderError!void {
        p_writer.writeAll(intro) catch return error.ProviderInternalError;
        conversation.appendHistory(p_writer, self.history) catch return error.ProviderInternalError;
        p_writer.writeAll("--- CONTEXT ---\n") catch return error.ProviderInternalError;
        for (self.ctx_builder.blocks.items) |block| {
            p_writer.print("[{s}] {s}\n", .{ @tagName(block.block_type), block.name }) catch return error.ProviderInternalError;
            p_writer.print("{s}\n\n", .{block.content}) catch return error.ProviderInternalError;
        }
    }

    fn writeJsonContractInstructions(self: *Planner, p_writer: *std.Io.Writer) provider.ProviderError!void {
        const is_local = std.mem.eql(u8, self.prov.metadata().provider_name, "ollama");
        p_writer.writeAll(
            \\Respond ONLY with valid JSON. Do not use markdown blocks or prose before/after the object.
            \\The response must start with '{' and end with '}'.
            \\Schema (proposal v1):
            \\{"schema_version":1,"summary":"one line","assumptions":["..."],"validation_tasks":["auto:test","property: fuzz changed parsers if applicable"],"workspace_edit":{"files":[{"path":"relative/path.txt","operation":"create|modify|delete","expected_hash":null,"edits":[{"start":0,"end":0,"replacement":"content"}]}]}}
            \\For modify/delete include expected_hash from the current file snapshot.
            \\If no file edits are required yet, return workspace_edit.files as an empty array.
            \\
            \\CODE QUALITY & STYLE RULES:
            \\- Strictly follow the project's coding conventions (e.g. idiomatic Zig, standard naming, avoid deprecated APIs).
            \\- Ensure logic correctness, handle edge cases, and double-check syntax before generating the final JSON.
            \\- Preserve existing code comments and indentation levels.
            \\- For `modify` operations, provide a complete drop-in replacement that logically fits without breaking the surrounding context.
        ) catch return error.ProviderInternalError;
        if (is_local) {
            p_writer.writeAll(
                \\
                \\LOCAL MODEL RULES (strict):
                \\- Never wrap JSON in ``` fences.
                \\- Never explain the proposal outside the JSON object.
                \\- Keep summary short; put details in assumptions or file edits.
                \\- For questions/reviews with no code changes, use workspace_edit.files: [] and put the answer in summary.
                \\- Example (no edits): {"schema_version":1,"summary":"Project uses Zig monorepo layout.","assumptions":[],"validation_tasks":[],"workspace_edit":{"files":[]}}
                \\
            ) catch return error.ProviderInternalError;
        }
    }

    /// Generates a WorkspaceEdit JSON response by prompting the AI provider
    pub fn plan(self: *Planner, writer: *std.Io.Writer, cancel_token: *const kernel.cancellation.CancellationToken) provider.ProviderError!void {
        var p_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer p_alloc.deinit();
        const p_writer = &p_alloc.writer;
        try self.writePromptHeader(
            p_writer,
            "You are an expert software engineer. Your task is to output a single JSON object matching the WorkspaceEdit schema based on the following intent.\n\n",
        );

        p_writer.writeAll("--- INSTRUCTIONS ---\n") catch return error.ProviderInternalError;
        try self.writeJsonContractInstructions(p_writer);

        // Call the provider
        const prompt_items = p_alloc.writer.buffer[0..p_alloc.writer.end];
        try self.prov.ask(self.allocator, prompt_items, self.images, writer, cancel_token);
    }

    /// Generates a Markdown implementation plan (Plan mode — before proposing edits).
    pub fn planMarkdown(self: *Planner, writer: *std.Io.Writer, cancel_token: *const kernel.cancellation.CancellationToken) provider.ProviderError!void {
        var p_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer p_alloc.deinit();
        const p_writer = &p_alloc.writer;
        try self.writePromptHeader(
            p_writer,
            "MARKDOWN PLAN MODE\nYou are an expert software engineer. Write an implementation plan in Markdown based on the intent and context below.\n\n",
        );

        p_writer.writeAll(
            \\--- INSTRUCTIONS ---
            \\Respond ONLY with Markdown (headings, bullet lists). Do not output JSON or code fences wrapping the whole document.
            \\Include: goal, approach, files to touch, risks, and validation steps.
            \\Use headings: Goal, Design, Tasks, Risks, Validation.
        ) catch return error.ProviderInternalError;

        const prompt_items = p_alloc.writer.buffer[0..p_alloc.writer.end];
        try self.prov.ask(self.allocator, prompt_items, self.images, writer, cancel_token);
    }

    /// Regenerates a proposal after trial apply + validation failed.
    pub fn planRepair(
        self: *Planner,
        writer: *std.Io.Writer,
        cancel_token: *const kernel.cancellation.CancellationToken,
        validation_report: []const u8,
        failed_proposal: []const u8,
    ) provider.ProviderError!void {
        var p_alloc = std.Io.Writer.Allocating.init(self.allocator);
        defer p_alloc.deinit();
        const p_writer = &p_alloc.writer;
        try self.writePromptHeader(
            p_writer,
            "REPAIR MODE\nYour previous proposal failed validation after a trial apply to the workspace. Output a corrected JSON proposal that fixes the failures.\n\n",
        );

        p_writer.writeAll("--- FAILED PROPOSAL ---\n") catch return error.ProviderInternalError;
        p_writer.writeAll(failed_proposal) catch return error.ProviderInternalError;
        p_writer.writeAll("\n\n--- VALIDATION OUTPUT ---\n") catch return error.ProviderInternalError;
        p_writer.writeAll(validation_report) catch return error.ProviderInternalError;

        p_writer.writeAll("\n\n--- INSTRUCTIONS ---\n") catch return error.ProviderInternalError;
        try self.writeJsonContractInstructions(p_writer);
        p_writer.writeAll(
            \\Address every validation failure shown above.
        ) catch return error.ProviderInternalError;

        const prompt_items = p_alloc.writer.buffer[0..p_alloc.writer.end];
        try self.prov.ask(self.allocator, prompt_items, self.images, writer, cancel_token);
    }
};

test "Planner execution with FakeProvider" {
    const allocator = std.testing.allocator;
    const fake_provider = @import("providers/fake/provider.zig");

    var ctx = context.ContextBuilder.init(allocator, 1024);
    defer ctx.deinit();
    try ctx.addBlock(.intent, "user intent", "Fix the bug");

    var mock_llm = fake_provider.FakeProvider.init("{\"id\": \"123\", \"description\": \"mock\"}", null, null);

    var planner = Planner.init(allocator, mock_llm.providerInterface(), &ctx, &.{}, &.{});

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    const token = cancel_src.getToken();

    try planner.plan(&w_alloc.writer, &token);

    const out_items = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expectEqualStrings("{\"id\": \"123\", \"description\": \"mock\"}", out_items);
}

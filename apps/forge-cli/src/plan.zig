const std = @import("std");
const args_mod = @import("args.zig");
const ai = @import("forge-ai");
const kernel = @import("forge-kernel");

pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    if (parsed.positional.len == 0) {
        try writer.writeAll("error: plan command requires an intent\n");
        return 2;
    }
    const intent = parsed.positional[0];

    try writer.print("Planning intent: '{s}'\n", .{intent});
    try writer.writeAll("Building context...\n");

    var ctx_builder = ai.context.ContextBuilder.init(allocator, 1024 * 1024);
    defer ctx_builder.deinit();
    try ctx_builder.addBlock(.intent, "user_intent", intent);

    try writer.writeAll("Invoking AI Provider...\n");
    
    // Fallback to fake provider if no key
    var fake_prov = ai.fake_provider.FakeProvider.init(
        \\{
        \\  "id": "1234-5678",
        \\  "description": "Generated proposal mock",
        \\  "modifications": []
        \\}
    );
    const p = fake_prov.providerInterface();

    var planner = ai.planner.Planner.init(allocator, p, &ctx_builder);
    
    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel_src = try kernel.cancellation.CancellationTokenSource.init(allocator);
    defer cancel_src.deinit();
    const token = cancel_src.getToken();

    planner.plan(&w_alloc.writer, &token) catch |err| {
        try writer.print("Error during planning: {}\n", .{err});
        return 1;
    };

    // Save proposal to a local file
    const out_path = ".forge-proposal.json";
    
    var file = try std.Io.Dir.createFile(.cwd(), io, out_path, .{});
    defer file.close(io);
    
    const proposal_items = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try file.writeStreamingAll(io, proposal_items);

    try writer.print("Proposal saved to {s}\n", .{out_path});
    try writer.writeAll("Run `forge diff .forge/proposals/latest.json` to review.\n");

    return 0;
}

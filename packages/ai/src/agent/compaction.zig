const std = @import("std");
const context = @import("../context.zig");
const context_manifest = @import("../context_manifest.zig");
const prompt_pack = @import("../prompt_pack.zig");
const routing = @import("../routing.zig");

pub const Options = struct {
    attempt: u8 = 1,
    max_conversation_tail: usize = 12 * 1024,
    max_manifest_bytes: usize = 16 * 1024,
    task_ledger_json: []const u8 = "",
};

pub fn recoveryOptions(attempt: u8) Options {
    return switch (attempt) {
        0, 1 => .{
            .attempt = attempt,
            .max_conversation_tail = 12 * 1024,
            .max_manifest_bytes = 16 * 1024,
        },
        2 => .{
            .attempt = attempt,
            .max_conversation_tail = 4 * 1024,
            .max_manifest_bytes = 8 * 1024,
        },
        else => .{
            .attempt = attempt,
            .max_conversation_tail = 2 * 1024,
            .max_manifest_bytes = 4 * 1024,
        },
    };
}

pub fn buildRecoveryPrompt(
    allocator: std.mem.Allocator,
    intent: []const u8,
    builder: *const context.ContextBuilder,
    conversation_json: []const u8,
    task_intent: routing.TaskIntent,
    options: Options,
) ![]u8 {
    var summary = try context_manifest.summarize(allocator, builder);
    defer context_manifest.freeSummary(allocator, &summary);

    const manifest_full = try context_manifest.formatManifest(allocator, builder, summary);
    defer allocator.free(manifest_full);
    const manifest = trimTail(manifest_full, options.max_manifest_bytes);
    const convo_tail = trimTail(conversation_json, options.max_conversation_tail);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try prompt_pack.writeRecoveryHeader(writer, task_intent, options.attempt, intent);

    try writer.writeAll("Compacted context manifest:\n");
    try writer.writeAll(manifest);
    try writeTaskLedger(writer, options.task_ledger_json);
    try writer.writeAll("\nCompacted prior conversation tail:\n```json\n");
    try writer.writeAll(convo_tail);
    try writer.writeAll("\n```\n\n");

    try writer.writeAll(prompt_pack.recovery_rules);

    return try out.toOwnedSlice();
}

pub fn buildResumePrompt(
    allocator: std.mem.Allocator,
    intent: []const u8,
    builder: *const context.ContextBuilder,
    conversation_json: []const u8,
    task_intent: routing.TaskIntent,
    next_step_index: u32,
    options: Options,
) ![]u8 {
    var summary = try context_manifest.summarize(allocator, builder);
    defer context_manifest.freeSummary(allocator, &summary);

    const manifest_full = try context_manifest.formatManifest(allocator, builder, summary);
    defer allocator.free(manifest_full);
    const manifest = trimTail(manifest_full, options.max_manifest_bytes);
    const convo_tail = trimTail(conversation_json, options.max_conversation_tail);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try prompt_pack.writeResumeHeader(writer, task_intent, next_step_index, intent);

    try writer.writeAll("Compact context manifest:\n");
    try writer.writeAll(manifest);
    try writeTaskLedger(writer, options.task_ledger_json);
    try writer.writeAll("\nRecent conversation/tool evidence tail:\n```json\n");
    try writer.writeAll(convo_tail);
    try writer.writeAll("\n```\n\n");

    try writer.writeAll(prompt_pack.resume_rules);

    return try out.toOwnedSlice();
}

pub fn trimTail(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    return text[text.len - max_bytes ..];
}

fn writeTaskLedger(writer: *std.Io.Writer, task_ledger_json: []const u8) !void {
    if (task_ledger_json.len == 0) return;
    try writer.writeAll("\nTask ledger checkpoint:\n```json\n");
    try writer.writeAll(trimTail(task_ledger_json, 8192));
    try writer.writeAll("\n```\n");
}

pub const SummaryStep = struct {
    index: u32,
    kind: []const u8,
    summary: []const u8,
};

pub fn buildSessionSummary(
    allocator: std.mem.Allocator,
    intent: []const u8,
    steps: []const SummaryStep,
    final_text: ?[]const u8,
    conversation_json: []const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.print("Goal: {s}\n", .{intent});
    if (steps.len > 0) {
        try writer.writeAll("Tool evidence:\n");
        const start = if (steps.len > 16) steps.len - 16 else 0;
        if (start > 0) try writer.print("- ... {d} older step(s) compacted\n", .{start});
        for (steps[start..]) |step| {
            try writer.print("- #{d} {s}: {s}\n", .{ step.index, step.kind, trimTail(step.summary, 512) });
        }
    }
    if (final_text) |text| {
        try writer.print("Final answer:\n{s}\n", .{trimTail(text, 2048)});
    } else if (conversation_json.len > 0) {
        try writer.print("Conversation tail:\n{s}\n", .{trimTail(conversation_json, 2048)});
    }
    return try out.toOwnedSlice();
}

test "buildRecoveryPrompt keeps goal and trims long conversation" {
    const allocator = std.testing.allocator;
    var builder = context.ContextBuilder.init(allocator, 4096);
    defer builder.deinit();
    try builder.addBlock(.intent, "intent", "fix socket cleanup");
    try builder.addBlock(.file, "src/socket.ts", "socket cleanup code");

    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const prompt = try buildRecoveryPrompt(allocator, "fix leak", &builder, long, .edit_code, .{
        .attempt = 2,
        .max_conversation_tail = 8,
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "fix leak") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "src/socket.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "aaaaaaaa") != null);
}

test "buildSessionSummary keeps latest tool evidence" {
    const allocator = std.testing.allocator;
    const steps = [_]SummaryStep{
        .{ .index = 1, .kind = "read_file", .summary = "Read `src/main.zig` lines 1-40" },
        .{ .index = 2, .kind = "replace_file_content", .summary = "Write `src/main.zig`: add compact recovery" },
    };
    const summary = try buildSessionSummary(allocator, "fix context", &steps, "done", "");
    defer allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "fix context") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "replace_file_content") != null);
}

test "buildResumePrompt includes task ledger when present" {
    const allocator = std.testing.allocator;
    var builder = context.ContextBuilder.init(allocator, 4096);
    defer builder.deinit();
    try builder.addBlock(.intent, "intent", "fix resume");

    const prompt = try buildResumePrompt(allocator, "fix resume", &builder, "[]", .edit_code, 7, .{
        .task_ledger_json = "{\"goal\":\"fix resume\",\"phase\":\"editing\"}",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Task ledger checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"phase\":\"editing\"") != null);
}

test "recoveryOptions shrink context across attempts" {
    const first = recoveryOptions(1);
    const second = recoveryOptions(2);
    const third = recoveryOptions(3);
    try std.testing.expect(second.max_conversation_tail < first.max_conversation_tail);
    try std.testing.expect(third.max_manifest_bytes < second.max_manifest_bytes);
}

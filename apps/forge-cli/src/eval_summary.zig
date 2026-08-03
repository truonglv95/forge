const std = @import("std");
const args_mod = @import("args.zig");

const Summary = struct {
    schema_version: u32 = 1,
    generated_at: []const u8,
    provider: []const u8,
    model: []const u8,
    tasks: usize,
    successes: usize,
    success_rate: f64,
    proposal_valid_rate: f64,
    validation_pass_rate: f64,
    average_steps: f64,
    average_repairs: f64,
    reported_tokens_total: u64,
    latency_ms_p50: f64,
    latency_ms_p95: f64,
    results_jsonl: []const u8,
    git_commit: []const u8,
    baseline: ?[]const u8 = null,
    success_rate_delta: ?f64 = null,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    flags: args_mod.GlobalFlags,
    writer: *std.Io.Writer,
) !u8 {
    _ = environ_map;

    var dir = std.Io.Dir.cwd().openDir(io, ".forge/evals", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.writeAll("No evals found. Run `forge eval ai-flow` first.\n");
            return 0;
        },
        else => return err,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    var latest_parsed: ?std.json.Parsed(Summary) = null;
    var latest_summary_json: ?[]const u8 = null;
    defer {
        if (latest_parsed) |*p| p.deinit();
        if (latest_summary_json) |j| allocator.free(j);
    }

    var latest_time: i64 = 0;

    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        var file = dir.openFile(io, entry.name, .{}) catch continue;
        defer file.close(io);

        const stat = file.stat(io) catch continue;
        const mtime = stat.mtime.toMilliseconds();

        const max_size = 10 * 1024 * 1024; // 10MB limit for jsonl
        if (stat.size > max_size) continue;

        const size: usize = @intCast(stat.size);
        const content = allocator.alloc(u8, size) catch continue;
        defer allocator.free(content);
        _ = file.readPositionalAll(io, content, 0) catch continue;

        // Find the last line
        var lines = std.mem.splitBackwardsScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len == 0) continue;

            // Try to parse as summary
            if (std.mem.indexOf(u8, trimmed, "\"schema_version\"") != null and std.mem.indexOf(u8, trimmed, "\"success_rate\"") != null) {
                if (mtime > latest_time) {
                    if (latest_summary_json) |j| allocator.free(j);
                    latest_summary_json = allocator.dupe(u8, trimmed) catch continue;

                    const parsed = std.json.parseFromSlice(Summary, allocator, latest_summary_json.?, .{ .ignore_unknown_fields = true }) catch continue;

                    if (latest_parsed) |*p| p.deinit();

                    latest_parsed = parsed;
                    latest_time = mtime;
                }
            }
            break; // only check the last non-empty line
        }
    }

    if (latest_parsed) |parsed| {
        const summary = parsed.value;
        if (flags.json) {
            try writer.writeAll(latest_summary_json.?);
            try writer.writeAll("\n");
            return 0;
        }

        try writer.print(
            \\=== Forge AI Evaluation Scorecard ===
            \\Generated At: {s}
            \\Provider: {s} ({s})
            \\Tasks Evaluated: {d}
            \\
            \\--- Metrics ---
            \\Overall Success Rate: {d:.2}% (Min: {d:.2}%)
            \\Proposal Valid Rate:  {d:.2}%
            \\Validation Pass Rate: {d:.2}% (Min: 80.00%)
            \\
            \\--- Performance ---
            \\Avg Steps / Task:   {d:.2}
            \\Avg Repair Attempts: {d:.2}
            \\Latency (p50):      {d:.0} ms
            \\Latency (p95):      {d:.0} ms
            \\Total Tokens:       {d}
            \\
            \\Results File: {s}
            \\Commit: {s}
            \\
        , .{
            summary.generated_at,
            summary.provider,
            summary.model,
            summary.tasks,
            summary.success_rate * 100.0,
            flags.min_success_rate * 100.0,
            summary.proposal_valid_rate * 100.0,
            summary.validation_pass_rate * 100.0,
            summary.average_steps,
            summary.average_repairs,
            summary.latency_ms_p50,
            summary.latency_ms_p95,
            summary.reported_tokens_total,
            summary.results_jsonl,
            summary.git_commit,
        });

        if (summary.baseline) |base| {
            try writer.print("Baseline: {s}\nDelta: {d:.2}%\n", .{ base, summary.success_rate_delta.? * 100.0 });
        }

        // M3 gate checks
        var failed = false;
        if (summary.success_rate < flags.min_success_rate) {
            try writer.print("\nFAIL: Success rate {d:.2}% < {d:.2}%\n", .{ summary.success_rate * 100.0, flags.min_success_rate * 100.0 });
            failed = true;
        }
        if (summary.validation_pass_rate < 0.8) {
            try writer.print("\nFAIL: First-pass validation rate {d:.2}% < 80.00%\n", .{summary.validation_pass_rate * 100.0});
            failed = true;
        }
        if (summary.success_rate_delta) |delta| {
            if (delta < -flags.max_success_regression) {
                try writer.print("\nFAIL: Regression {d:.2}% exceeds max allowed {d:.2}%\n", .{ delta * 100.0, flags.max_success_regression * 100.0 });
                failed = true;
            }
        }

        return if (failed) 1 else 0;
    } else {
        try writer.writeAll("No valid evaluation summary found in .forge/evals/*.jsonl\n");
        return 2;
    }
}

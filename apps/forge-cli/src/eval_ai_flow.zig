const std = @import("std");
const ai = @import("forge-ai");
const kernel = @import("forge-kernel");
const workspace = @import("forge-workspace");

const args_mod = @import("args.zig");
const ai_workflow = @import("ai_workflow.zig");

pub const EvalError = error{
    InvalidCorpus,
    WorkspaceFailed,
    ProviderFailed,
    OutOfMemory,
};

const TaskExpect = struct {
    const File = struct {
        path: []const u8,
        contains: []const u8 = "",
        not_contains: []const u8 = "",
        exists: bool = true,
    };

    proposal_only: bool = false,
    step_limit_checkpoint: bool = false,
    context_recovery: bool = false,
    expect_repair: bool = false,
    path: []const u8 = "",
    contains: []const u8 = "",
    files: []const File = &.{},
    min_steps: u32 = 0,
    has_import_neighbors: bool = false,
    min_ledger_entries: usize = 0,
    context_includes: []const []const u8 = &.{},
    context_top_k: usize = 0,
};

const Task = struct {
    id: []const u8,
    intent: []const u8,
    context_only: bool = false,
    max_steps: ?u32 = null,
    fake_context_failures: u8 = 0,
    fake_response: ?[]const u8 = null,
    fake_repair_response: ?[]const u8 = null,
    workspace_files: std.StringHashMapUnmanaged([]const u8) = .{},
    expect: TaskExpect = .{},

    fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        var it = self.workspace_files.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.workspace_files.deinit(allocator);
        allocator.free(self.id);
        allocator.free(self.intent);
        if (self.expect.path.len > 0) allocator.free(self.expect.path);
        if (self.expect.contains.len > 0) allocator.free(self.expect.contains);
        for (self.expect.files) |file| {
            allocator.free(file.path);
            if (file.contains.len > 0) allocator.free(file.contains);
            if (file.not_contains.len > 0) allocator.free(file.not_contains);
        }
        if (self.expect.files.len > 0) allocator.free(self.expect.files);
        for (self.expect.context_includes) |item| allocator.free(item);
        if (self.expect.context_includes.len > 0) allocator.free(self.expect.context_includes);
        if (self.fake_response) |text| allocator.free(text);
        if (self.fake_repair_response) |text| allocator.free(text);
        self.* = undefined;
    }
};

const Record = struct {
    task_id: []const u8,
    repetition: u32,
    provider: []const u8,
    model: []const u8,
    latency_ms: f64,
    command_success: bool,
    proposal_valid: bool,
    apply_success: bool,
    validation_pass: bool,
    task_success: bool,
    steps: usize,
    repair_attempts: u8,
    context_hits: usize = 0,
    context_best_rank: usize = 0,
    context_blocks: usize = 0,
    reported_tokens: struct {
        prompt: usize = 0,
        completion: usize = 0,
        total: usize = 0,
    },
    reason: []const u8,
};

const Summary = struct {
    schema_version: u32 = 1,
    generated_at: []const u8,
    provider: []const u8,
    model: []const u8,
    provider_model: []const u8,
    corpus: []const u8,
    tasks: usize,
    successes: usize,
    success_rate: f64,
    proposal_valid_rate: f64,
    validation_pass_rate: f64,
    average_steps: f64,
    average_repairs: f64,
    reported_tokens_total: u64,
    context_hit_rate: f64 = 0,
    context_rank_p50: f64 = 0,
    context_rank_p95: f64 = 0,
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
) EvalError!u8 {
    const corpus_path = flags.corpus orelse "fixtures/eval/agent_reliability.json";
    const out_path = flags.output orelse ".forge/evals/latest.jsonl";
    const repeat = if (flags.repeat == 0) 1 else flags.repeat;
    const max_steps = if (flags.max_steps > 0) flags.max_steps else 8;
    const provider_name = flags.provider orelse "fake";
    const model_name = flags.model orelse "default";

    const tasks = loadCorpus(allocator, io, corpus_path) catch return error.InvalidCorpus;
    defer freeTasks(allocator, tasks);

    var records: std.ArrayList(Record) = .empty;
    defer {
        for (records.items) |rec| {
            allocator.free(rec.task_id);
            allocator.free(rec.provider);
            allocator.free(rec.model);
            allocator.free(rec.reason);
        }
        records.deinit(allocator);
    }

    var latencies: std.ArrayList(f64) = .empty;
    defer latencies.deinit(allocator);

    var token_total: u64 = 0;

    for (1..repeat + 1) |rep| {
        const rep_u32: u32 = @intCast(rep);
        for (tasks) |task| {
            const start_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
            var eval_ws = EvalWorkspace.create(allocator, io) catch return error.WorkspaceFailed;
            defer eval_ws.deinit();

            seedWorkspace(allocator, io, eval_ws.root, task.workspace_files) catch return error.WorkspaceFailed;

            const active_file: ?[]const u8 = blk: {
                if (!task.expect.has_import_neighbors) break :blk null;
                if (task.workspace_files.get("main.zig") != null) break :blk "main.zig";
                break :blk null;
            };

            if (task.context_only) {
                const latency_ms = millisDelta(start_ms, std.Io.Timestamp.now(io, .real).toMilliseconds());
                try latencies.append(allocator, latency_ms);
                const context_result = contextExpectationOk(allocator, io, eval_ws.root, task.intent, active_file, task.expect) catch ContextExpectation{
                    .ok = false,
                    .reason = "context retrieval failed",
                };
                var rec = try makeRecord(
                    allocator,
                    task.id,
                    rep_u32,
                    provider_name,
                    model_name,
                    latency_ms,
                    context_result.ok,
                    context_result.ok,
                    context_result.ok,
                    context_result.ok,
                    context_result.ok,
                    0,
                    0,
                    .{},
                    context_result.reason,
                );
                rec.context_hits = context_result.hits;
                rec.context_best_rank = context_result.best_rank;
                rec.context_blocks = context_result.blocks;
                try records.append(allocator, rec);
                continue;
            }

            var eval_flags = flags;
            if (eval_flags.provider == null) eval_flags.provider = "fake";
            var provider_opts = ai_workflow.agentProviderOptionsFromFlags(allocator, eval_flags, task.intent, io, null);
            provider_opts.options.fake_context_failures = task.fake_context_failures;
            if (task.fake_response) |response_text| provider_opts.options.fake_response = response_text;
            if (task.fake_repair_response) |repair_text| provider_opts.options.fake_plan_response = repair_text;
            const task_max_steps = task.max_steps orelse max_steps;
            var result = ai.agent.run(allocator, io, environ_map, eval_ws.root, task.intent, .{
                .max_steps = task_max_steps,
                .provider_options = provider_opts.options,
                .workspace_cwd = eval_ws.absolute_path,
                .active_file = active_file,
                .mode = .agent,
                .capability_profile = .propose,
                .max_repair_attempts = if (task.expect.expect_repair) 2 else if (std.mem.eql(u8, provider_opts.options.provider_name, "fake")) 0 else 2,
            }) catch |err| {
                const latency_ms = millisDelta(start_ms, std.Io.Timestamp.now(io, .real).toMilliseconds());
                try latencies.append(allocator, latency_ms);
                if (task.expect.step_limit_checkpoint and err == error.StepLimitReached) {
                    const checkpoint = latestResumableCheckpointOk(allocator, io, eval_ws.absolute_path, task.expect.min_ledger_entries) catch CheckpointExpectation{
                        .ok = false,
                        .steps = 0,
                        .reason = "checkpoint inspection failed",
                    };
                    try records.append(allocator, try makeRecord(
                        allocator,
                        task.id,
                        rep_u32,
                        provider_name,
                        model_name,
                        latency_ms,
                        checkpoint.ok,
                        checkpoint.ok,
                        checkpoint.ok,
                        checkpoint.ok,
                        checkpoint.ok,
                        checkpoint.steps,
                        0,
                        .{},
                        checkpoint.reason,
                    ));
                    continue;
                }
                const reason = try std.fmt.allocPrint(allocator, "agent run failed: {s}", .{@errorName(err)});
                defer allocator.free(reason);
                try records.append(allocator, try makeFailedRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, reason));
                continue;
            };
            defer ai.agent.deinitResult(allocator, &result);

            const latency_ms = millisDelta(start_ms, std.Io.Timestamp.now(io, .real).toMilliseconds());
            try latencies.append(allocator, latency_ms);

            if (task.expect.has_import_neighbors) {
                var ctx_builder = ai.context_loader.build(allocator, io, eval_ws.root, .{
                    .max_bytes = 256 * 1024,
                    .intent = task.intent,
                    .active_file = active_file,
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
                }) catch {
                    try records.append(allocator, try makeFailedRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, "context build failed"));
                    continue;
                };
                defer ctx_builder.deinit();

                var found_imports = false;
                for (ctx_builder.blocks.items) |block| {
                    if (block.block_type == .imports) {
                        found_imports = true;
                        break;
                    }
                }
                if (!found_imports) {
                    try records.append(allocator, try makeFailedRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, "missing import neighbors in context"));
                    continue;
                }
            }
            if (task.expect.context_includes.len > 0) {
                const context_result = contextIncludesExpected(allocator, io, eval_ws.root, task.intent, task.expect) catch ContextExpectation{
                    .ok = false,
                    .reason = "context retrieval failed",
                };
                if (!context_result.ok) {
                    var rec = try makeFailedRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, context_result.reason);
                    rec.context_hits = context_result.hits;
                    rec.context_best_rank = context_result.best_rank;
                    rec.context_blocks = context_result.blocks;
                    try records.append(allocator, rec);
                    continue;
                }
            }

            const proposal_ok, const proposal_reason, const proposal_rel = proposalStatus(allocator, io, eval_ws.root, result.proposal_rel) catch {
                try records.append(allocator, try makeFailedRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, "proposal missing or malformed"));
                continue;
            };

            if (!proposal_ok) {
                try records.append(allocator, try makeFailedRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, proposal_reason));
                continue;
            }

            var apply_success = false;
            var validation_pass = false;
            var reason: []const u8 = "unknown";

            if (task.expect.proposal_only) {
                apply_success = true;
                validation_pass = true;
                reason = "proposal contract satisfied";
            } else {
                apply_success = applyProposalInPlace(allocator, io, eval_ws.root, proposal_rel) catch false;
                if (!apply_success) {
                    reason = "proposal failed transaction apply";
                } else {
                    const ok, const why = postconditionOk(allocator, io, eval_ws.root, task.expect) catch .{ false, "postcondition check failed" };
                    validation_pass = ok;
                    reason = why;
                }
            }

            const steps_count = result.steps.len;
            if (steps_count < task.expect.min_steps) {
                try records.append(allocator, try makeRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, true, true, apply_success, validation_pass, false, steps_count, result.repair_attempts, result.usage, "insufficient tool exploration"));
                continue;
            }
            if (task.expect.min_ledger_entries > 0) {
                const ledger_ok = sessionLedgerHasEntries(allocator, io, result.session_id, task.expect.min_ledger_entries) catch false;
                if (!ledger_ok) {
                    try records.append(allocator, try makeRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, true, true, apply_success, validation_pass, false, steps_count, result.repair_attempts, result.usage, "session task ledger missing or too small"));
                    continue;
                }
            }
            if (task.expect.context_recovery) {
                const recovery_ok = sessionEventsContain(allocator, io, result.session_id, "context_compacted") catch false;
                if (!recovery_ok) {
                    try records.append(allocator, try makeRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, true, true, apply_success, validation_pass, false, steps_count, result.repair_attempts, result.usage, "missing context recovery compaction event"));
                    continue;
                }
            }
            if (task.expect.expect_repair and result.repair_attempts == 0) {
                try records.append(allocator, try makeRecord(allocator, task.id, rep_u32, provider_name, model_name, latency_ms, true, true, apply_success, validation_pass, false, steps_count, result.repair_attempts, result.usage, "expected repair loop did not run"));
                continue;
            }

            const success = apply_success and validation_pass;
            token_total += @intCast(result.usage.total_tokens);
            try records.append(allocator, try makeRecord(
                allocator,
                task.id,
                rep_u32,
                provider_name,
                model_name,
                latency_ms,
                true,
                true,
                apply_success,
                validation_pass,
                success,
                steps_count,
                result.repair_attempts,
                result.usage,
                reason,
            ));
        }
    }

    persistRecords(allocator, io, out_path, records.items) catch return error.WorkspaceFailed;

    const success_count = countSuccess(records.items);
    const success_rate = if (records.items.len == 0) 0 else @as(f64, @floatFromInt(success_count)) / @as(f64, @floatFromInt(records.items.len));
    const proposal_rate = rateBool(records.items, "proposal_valid");
    const validation_rate = rateBool(records.items, "validation_pass");
    const avg_steps = avgUsize(records.items, "steps");
    const avg_repairs = avgU8(records.items, "repair_attempts");
    const context_hit_rate_value = contextHitRate(records.items);
    const context_ranks = collectContextRanks(allocator, records.items) catch &.{};
    defer if (context_ranks.len > 0) allocator.free(context_ranks);
    const p50 = percentile(latencies.items, 0.50);
    const p95 = percentile(latencies.items, 0.95);
    const git_commit = gitCommitShort(allocator, io) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(git_commit);

    const generated_at = timestampIsoUtc(allocator, io) catch try allocator.dupe(u8, "");
    defer allocator.free(generated_at);
    const provider_model = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_name, model_name });
    defer allocator.free(provider_model);

    var summary = Summary{
        .generated_at = generated_at,
        .provider = provider_name,
        .model = model_name,
        .provider_model = provider_model,
        .corpus = corpus_path,
        .tasks = records.items.len,
        .successes = success_count,
        .success_rate = round4(success_rate),
        .proposal_valid_rate = round4(proposal_rate),
        .validation_pass_rate = round4(validation_rate),
        .average_steps = round2(avg_steps),
        .average_repairs = round2(avg_repairs),
        .reported_tokens_total = token_total,
        .context_hit_rate = round4(context_hit_rate_value),
        .context_rank_p50 = percentileUsize(context_ranks, 0.50),
        .context_rank_p95 = percentileUsize(context_ranks, 0.95),
        .latency_ms_p50 = p50,
        .latency_ms_p95 = p95,
        .results_jsonl = out_path,
        .git_commit = git_commit,
    };

    var regression_ok = true;
    if (flags.baseline) |baseline_path| {
        const baseline = loadBaseline(allocator, io, baseline_path) catch null;
        if (baseline) |rate| {
            const delta = round4(summary.success_rate - rate);
            summary.baseline = baseline_path;
            summary.success_rate_delta = delta;
            regression_ok = delta >= -flags.max_success_regression;
        }
    }

    persistSummary(allocator, io, out_path, summary) catch return error.WorkspaceFailed;

    const json = std.json.Stringify.valueAlloc(allocator, summary, .{}) catch return error.OutOfMemory;
    defer allocator.free(json);
    writer.writeAll(json) catch return error.WorkspaceFailed;
    writer.writeAll("\n") catch return error.WorkspaceFailed;

    const meets_min = summary.success_rate >= flags.min_success_rate;
    return if (meets_min and regression_ok) 0 else 2;
}

fn loadCorpus(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]Task {
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidCorpus;
    var tasks: std.ArrayList(Task) = .empty;
    errdefer {
        for (tasks.items) |*task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) return error.InvalidCorpus;
        const obj = item.object;
        const id_val = obj.get("id") orelse return error.InvalidCorpus;
        const intent_val = obj.get("intent") orelse return error.InvalidCorpus;
        if (id_val != .string or intent_val != .string) return error.InvalidCorpus;

        var task = Task{
            .id = try allocator.dupe(u8, id_val.string),
            .intent = try allocator.dupe(u8, intent_val.string),
        };
        errdefer task.deinit(allocator);

        if (obj.get("workspace_files")) |wf| {
            if (wf != .object) return error.InvalidCorpus;
            var it = wf.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidCorpus;
                try task.workspace_files.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*.string));
            }
        }

        if (obj.get("max_steps")) |v| {
            if (v == .integer) task.max_steps = @intCast(v.integer);
        }
        if (obj.get("context_only")) |v| {
            if (v == .bool) task.context_only = v.bool;
        }
        if (obj.get("fake_context_failures")) |v| {
            if (v == .integer) task.fake_context_failures = @intCast(v.integer);
        }
        if (obj.get("fake_response")) |v| {
            if (v == .string) task.fake_response = try allocator.dupe(u8, v.string);
        }
        if (obj.get("fake_repair_response")) |v| {
            if (v == .string) task.fake_repair_response = try allocator.dupe(u8, v.string);
        }

        if (obj.get("expect")) |ex| {
            if (ex != .object) return error.InvalidCorpus;
            if (ex.object.get("proposal_only")) |v| {
                if (v == .bool) task.expect.proposal_only = v.bool;
            }
            if (ex.object.get("step_limit_checkpoint")) |v| {
                if (v == .bool) task.expect.step_limit_checkpoint = v.bool;
            }
            if (ex.object.get("context_recovery")) |v| {
                if (v == .bool) task.expect.context_recovery = v.bool;
            }
            if (ex.object.get("expect_repair")) |v| {
                if (v == .bool) task.expect.expect_repair = v.bool;
            }
            if (ex.object.get("path")) |v| {
                if (v == .string) task.expect.path = try allocator.dupe(u8, v.string);
            }
            if (ex.object.get("contains")) |v| {
                if (v == .string) task.expect.contains = try allocator.dupe(u8, v.string);
            }
            if (ex.object.get("files")) |v| {
                if (v != .array) return error.InvalidCorpus;
                var files: std.ArrayList(TaskExpect.File) = .empty;
                errdefer {
                    for (files.items) |expected_file| {
                        allocator.free(expected_file.path);
                        if (expected_file.contains.len > 0) allocator.free(expected_file.contains);
                        if (expected_file.not_contains.len > 0) allocator.free(expected_file.not_contains);
                    }
                    files.deinit(allocator);
                }
                for (v.array.items) |entry| {
                    if (entry != .object) return error.InvalidCorpus;
                    const path_value = entry.object.get("path") orelse return error.InvalidCorpus;
                    if (path_value != .string) return error.InvalidCorpus;
                    var expected_file = TaskExpect.File{
                        .path = try allocator.dupe(u8, path_value.string),
                    };
                    if (entry.object.get("contains")) |contains_value| {
                        if (contains_value != .string) return error.InvalidCorpus;
                        expected_file.contains = try allocator.dupe(u8, contains_value.string);
                    }
                    if (entry.object.get("not_contains")) |not_contains_value| {
                        if (not_contains_value != .string) return error.InvalidCorpus;
                        expected_file.not_contains = try allocator.dupe(u8, not_contains_value.string);
                    }
                    if (entry.object.get("exists")) |exists_value| {
                        if (exists_value != .bool) return error.InvalidCorpus;
                        expected_file.exists = exists_value.bool;
                    }
                    try files.append(allocator, expected_file);
                }
                task.expect.files = try files.toOwnedSlice(allocator);
            }
            if (ex.object.get("min_steps")) |v| {
                if (v == .integer) task.expect.min_steps = @intCast(v.integer);
            }
            if (ex.object.get("has_import_neighbors")) |v| {
                if (v == .bool) task.expect.has_import_neighbors = v.bool;
            }
            if (ex.object.get("min_ledger_entries")) |v| {
                if (v == .integer) task.expect.min_ledger_entries = @intCast(v.integer);
            }
            if (ex.object.get("context_includes")) |v| {
                if (v != .array) return error.InvalidCorpus;
                var includes: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (includes.items) |item_text| allocator.free(item_text);
                    includes.deinit(allocator);
                }
                for (v.array.items) |entry| {
                    if (entry != .string) return error.InvalidCorpus;
                    try includes.append(allocator, try allocator.dupe(u8, entry.string));
                }
                task.expect.context_includes = try includes.toOwnedSlice(allocator);
            }
            if (ex.object.get("context_top_k")) |v| {
                if (v == .integer) task.expect.context_top_k = @intCast(v.integer);
            }
        }

        try tasks.append(allocator, task);
    }

    return try tasks.toOwnedSlice(allocator);
}

fn freeTasks(allocator: std.mem.Allocator, tasks: []Task) void {
    for (tasks) |*task| task.deinit(allocator);
    allocator.free(tasks);
}

fn sessionLedgerHasEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,
    min_entries: usize,
) !bool {
    var doc = try workspace.sessions.loadSession(allocator, io, session_id);
    defer workspace.sessions.deinitSession(allocator, &doc);
    if (doc.task_ledger_json.len == 0) return false;
    const stats = ai.task_ledger.statsFromJson(allocator, doc.task_ledger_json) catch return false;
    return stats.entries >= min_entries;
}

fn sessionEventsContain(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,
    needle: []const u8,
) !bool {
    const body = try workspace.sessions.readEvents(allocator, io, session_id);
    defer allocator.free(body);
    return std.mem.indexOf(u8, body, needle) != null;
}

const CheckpointExpectation = struct {
    ok: bool,
    steps: usize,
    reason: []const u8,
};

fn latestResumableCheckpointOk(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    min_ledger_entries: usize,
) !CheckpointExpectation {
    const offer_opt = try workspace.sessions.findLatestResumable(allocator, io, workspace_path);
    var offer = offer_opt orelse return .{
        .ok = false,
        .steps = 0,
        .reason = "missing resumable checkpoint",
    };
    defer workspace.sessions.deinitResumable(allocator, &offer);

    var doc = try workspace.sessions.loadSession(allocator, io, offer.session_id);
    defer workspace.sessions.deinitSession(allocator, &doc);

    if (doc.conversation_json.len == 0) return .{
        .ok = false,
        .steps = doc.steps.len,
        .reason = "checkpoint missing conversation state",
    };
    if (doc.task_ledger_json.len == 0) return .{
        .ok = false,
        .steps = doc.steps.len,
        .reason = "checkpoint missing task ledger",
    };
    if (min_ledger_entries > 0) {
        const stats = ai.task_ledger.statsFromJson(allocator, doc.task_ledger_json) catch return .{
            .ok = false,
            .steps = doc.steps.len,
            .reason = "checkpoint task ledger malformed",
        };
        if (stats.entries < min_ledger_entries) return .{
            .ok = false,
            .steps = doc.steps.len,
            .reason = "checkpoint task ledger too small",
        };
    }
    return .{
        .ok = true,
        .steps = doc.steps.len,
        .reason = "step limit checkpoint saved",
    };
}

const EvalWorkspace = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_dir: std.Io.Dir,
    directory_name: []u8,
    absolute_path: []u8,
    root: workspace.WorkspaceRoot,

    fn create(allocator: std.mem.Allocator, io: std.Io) !EvalWorkspace {
        const timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const directory_name = try std.fmt.allocPrint(allocator, ".zig-cache/eval/forge-ai-flow-{d}-{d}", .{ timestamp, std.Thread.getCurrentId() });
        errdefer allocator.free(directory_name);
        var parent_dir = std.Io.Dir.cwd();
        parent_dir.deleteTree(io, directory_name) catch {};
        try parent_dir.createDirPath(io, directory_name);
        errdefer parent_dir.deleteTree(io, directory_name) catch {};
        var dir = try parent_dir.openDir(io, directory_name, .{ .access_sub_paths = true, .iterate = true });
        errdefer dir.close(io);
        const root = workspace.WorkspaceRoot.init(dir, ".");

        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_len = try root.dir.realPath(io, &abs_buf);
        const absolute_path = try allocator.dupe(u8, abs_buf[0..abs_len]);
        errdefer allocator.free(absolute_path);

        return .{
            .allocator = allocator,
            .io = io,
            .parent_dir = parent_dir,
            .directory_name = directory_name,
            .absolute_path = absolute_path,
            .root = root,
        };
    }

    fn deinit(self: *EvalWorkspace) void {
        self.root.close(self.io);
        self.parent_dir.deleteTree(self.io, self.directory_name) catch {};
        self.allocator.free(self.directory_name);
        self.allocator.free(self.absolute_path);
        self.* = undefined;
    }
};

fn seedWorkspace(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, files: std.StringHashMapUnmanaged([]const u8)) !void {
    var it = files.iterator();
    while (it.next()) |entry| {
        const path = try workspace.WorkspacePath.parse(entry.key_ptr.*);
        if (std.fs.path.dirname(entry.key_ptr.*)) |dir_name| {
            try workspace.atomic.createDirPath(io, root, dir_name);
        }
        try workspace.atomic.replaceFile(io, root, path, entry.value_ptr.*);
    }
    _ = allocator;
}

fn proposalStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    proposal_rel: ?[]const u8,
) !struct { bool, []const u8, []const u8 } {
    const rel = proposal_rel orelse return error.InvalidCorpus;
    var proposal = workspace.OwnedProposal.readPath(allocator, io, root, rel) catch return error.InvalidCorpus;
    defer proposal.deinit();
    const edit = proposal.workspaceEdit();
    edit.validate() catch return .{ false, "proposal missing or malformed", rel };
    if (edit.files.len == 0) return .{ false, "proposal missing or malformed", rel };
    return .{ true, "ok", rel };
}

fn applyProposalInPlace(allocator: std.mem.Allocator, io: std.Io, root: workspace.WorkspaceRoot, proposal_rel: []const u8) !bool {
    var proposal = workspace.OwnedProposal.readPath(allocator, io, root, proposal_rel) catch return false;
    defer proposal.deinit();
    const edit = proposal.workspaceEdit();
    edit.validate() catch return false;
    _ = workspace.execution.applyApproved(allocator, io, root, edit, proposal_rel) catch return false;
    return true;
}

fn postconditionOk(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    expect: TaskExpect,
) !struct { bool, []const u8 } {
    if (expect.files.len > 0) {
        for (expect.files) |file| {
            const ok, const why = try filePostconditionOk(allocator, io, root, file);
            if (!ok) return .{ false, why };
        }
        return .{ true, "postcondition satisfied" };
    }
    if (expect.path.len == 0) return .{ true, "postcondition satisfied" };
    return filePostconditionOk(allocator, io, root, .{
        .path = expect.path,
        .contains = expect.contains,
    });
}

fn filePostconditionOk(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    expect: TaskExpect.File,
) !struct { bool, []const u8 } {
    var snap = workspace.FileSnapshot.read(allocator, io, root, try workspace.WorkspacePath.parse(expect.path)) catch {
        return if (expect.exists) .{ false, "missing expected file" } else .{ true, "postcondition satisfied" };
    };
    defer snap.deinit();
    if (!expect.exists) return .{ false, "file should not exist" };
    if (expect.contains.len > 0 and std.mem.indexOf(u8, snap.content, expect.contains) == null) {
        return .{ false, "expected content not found" };
    }
    if (expect.not_contains.len > 0 and std.mem.indexOf(u8, snap.content, expect.not_contains) != null) {
        return .{ false, "unexpected content found" };
    }
    return .{ true, "postcondition satisfied" };
}

const ContextExpectation = struct {
    ok: bool,
    reason: []const u8,
    hits: usize = 0,
    best_rank: usize = 0,
    blocks: usize = 0,
};

fn contextIncludesExpected(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    expect: TaskExpect,
) !ContextExpectation {
    var ctx_builder = ai.context_loader.build(allocator, io, root, .{
        .max_bytes = 512 * 1024,
        .intent = intent,
        .include_import_graph = true,
        .include_semantic_search = true,
        .auto_semantic_search = true,
        .include_web = false,
        .include_agent_memory = false,
        .include_diagnostics = false,
        .include_lsp_context = false,
    }) catch return .{ .ok = false, .reason = "context retrieval failed" };
    defer ctx_builder.deinit();

    var hits: usize = 0;
    var best_rank: usize = 0;
    for (expect.context_includes) |needle| {
        var found = false;
        var rank: usize = 0;
        for (ctx_builder.blocks.items, 0..) |block, index| {
            if (std.mem.indexOf(u8, block.name, needle) != null or std.mem.indexOf(u8, block.content, needle) != null) {
                found = true;
                rank = index + 1;
                break;
            }
        }
        if (!found) return .{ .ok = false, .reason = "context missing expected file or symbol", .hits = hits, .best_rank = best_rank, .blocks = ctx_builder.blocks.items.len };
        hits += 1;
        if (best_rank == 0 or rank < best_rank) best_rank = rank;
        if (expect.context_top_k > 0 and rank > expect.context_top_k) {
            return .{ .ok = false, .reason = "context expected item ranked too low", .hits = hits, .best_rank = best_rank, .blocks = ctx_builder.blocks.items.len };
        }
    }
    return .{ .ok = true, .reason = "context includes expected evidence", .hits = hits, .best_rank = best_rank, .blocks = ctx_builder.blocks.items.len };
}

fn contextExpectationOk(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    intent: []const u8,
    active_file: ?[]const u8,
    expect: TaskExpect,
) !ContextExpectation {
    var hits: usize = 0;
    var best_rank: usize = 0;
    var blocks: usize = 0;
    if (expect.has_import_neighbors) {
        var ctx_builder = ai.context_loader.build(allocator, io, root, .{
            .max_bytes = 256 * 1024,
            .intent = intent,
            .active_file = active_file,
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
        }) catch return .{ .ok = false, .reason = "context build failed" };
        defer ctx_builder.deinit();
        blocks += ctx_builder.blocks.items.len;

        var found_imports = false;
        for (ctx_builder.blocks.items, 0..) |block, index| {
            if (block.block_type == .imports) {
                found_imports = true;
                hits += 1;
                best_rank = index + 1;
                break;
            }
        }
        if (!found_imports) return .{ .ok = false, .reason = "missing import neighbors in context", .hits = hits, .best_rank = best_rank, .blocks = blocks };
    }
    if (expect.context_includes.len > 0) {
        var result = try contextIncludesExpected(allocator, io, root, intent, expect);
        result.hits += hits;
        if (result.best_rank == 0 or (best_rank > 0 and best_rank < result.best_rank)) result.best_rank = best_rank;
        result.blocks += blocks;
        return result;
    }
    return .{ .ok = true, .reason = "context expectation satisfied", .hits = hits, .best_rank = best_rank, .blocks = blocks };
}

fn persistRecords(allocator: std.mem.Allocator, io: std.Io, out_path: []const u8, records: []const Record) !void {
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, std.fs.path.dirname(out_path) orelse ".forge/evals");
    var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, out_path, .{ .truncate = true });
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var out = file.writer(io, &buf);
    for (records) |rec| {
        const line = try std.json.Stringify.valueAlloc(allocator, rec, .{});
        defer allocator.free(line);
        try out.interface.writeAll(line);
        try out.interface.writeAll("\n");
    }
    try out.interface.flush();
}

fn persistSummary(allocator: std.mem.Allocator, io: std.Io, results_path: []const u8, summary: Summary) !void {
    const base = if (std.mem.endsWith(u8, results_path, ".jsonl"))
        results_path[0 .. results_path.len - ".jsonl".len]
    else
        results_path;
    const summary_path = try std.fmt.allocPrint(allocator, "{s}.summary.json", .{base});
    defer allocator.free(summary_path);
    var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, summary_path, .{ .truncate = true });
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var out = file.writer(io, &buf);
    const json = try std.json.Stringify.valueAlloc(allocator, summary, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try out.interface.writeAll(json);
    try out.interface.writeAll("\n");
    try out.interface.flush();
}

fn loadBaseline(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?f64 {
    var file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("success_rate")) |v| {
        return switch (v) {
            .float => v.float,
            .integer => @floatFromInt(v.integer),
            else => null,
        };
    }
    return null;
}

fn timestampIsoUtc(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    // Best-effort stable timestamp without pulling in heavy formatting; keep ms.
    return std.fmt.allocPrint(allocator, "{d}", .{ms});
}

fn gitCommitShort(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    _ = io;
    const captured = try kernel.process.runCapture(allocator, .{
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
        .cwd = ".",
        .max_bytes = 64,
    });
    defer allocator.free(captured.output);
    const trimmed = std.mem.trim(u8, captured.output, &std.ascii.whitespace);
    return try allocator.dupe(u8, trimmed);
}

fn countSuccess(records: []const Record) usize {
    var n: usize = 0;
    for (records) |r| {
        if (r.task_success) n += 1;
    }
    return n;
}

fn rateBool(records: []const Record, comptime field: []const u8) f64 {
    var n: usize = 0;
    for (records) |r| {
        const v = @field(r, field);
        if (v) n += 1;
    }
    return if (records.len == 0) 0 else @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(records.len));
}

fn avgUsize(records: []const Record, comptime field: []const u8) f64 {
    var total: usize = 0;
    for (records) |r| total += @field(r, field);
    return if (records.len == 0) 0 else @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(records.len));
}

fn avgU8(records: []const Record, comptime field: []const u8) f64 {
    var total: usize = 0;
    for (records) |r| total += @intCast(@field(r, field));
    return if (records.len == 0) 0 else @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(records.len));
}

fn percentile(values: []const f64, fraction: f64) f64 {
    if (values.len == 0) return 0;
    const tmp = std.heap.page_allocator.alloc(f64, values.len) catch return values[0];
    defer std.heap.page_allocator.free(tmp);
    @memcpy(tmp, values);
    std.mem.sort(f64, tmp, {}, comptime std.sort.asc(f64));
    const n: f64 = @floatFromInt(values.len);
    const raw_pos = @ceil(n * fraction) - 1.0;
    var idx_i64: i64 = @intFromFloat(raw_pos);
    if (idx_i64 < 0) idx_i64 = 0;
    var idx: usize = @intCast(idx_i64);
    if (idx >= values.len) idx = values.len - 1;
    return tmp[idx];
}

fn percentileUsize(values: []const usize, fraction: f64) f64 {
    if (values.len == 0) return 0;
    const tmp = std.heap.page_allocator.alloc(usize, values.len) catch return @floatFromInt(values[0]);
    defer std.heap.page_allocator.free(tmp);
    @memcpy(tmp, values);
    std.mem.sort(usize, tmp, {}, comptime std.sort.asc(usize));
    const n: f64 = @floatFromInt(values.len);
    const raw_pos = @ceil(n * fraction) - 1.0;
    var idx_i64: i64 = @intFromFloat(raw_pos);
    if (idx_i64 < 0) idx_i64 = 0;
    var idx: usize = @intCast(idx_i64);
    if (idx >= values.len) idx = values.len - 1;
    return @floatFromInt(tmp[idx]);
}

fn contextHitRate(records: []const Record) f64 {
    var total: usize = 0;
    var success: usize = 0;
    for (records) |record| {
        if (record.context_blocks == 0 and record.context_hits == 0) continue;
        total += 1;
        if (record.context_hits > 0 and record.task_success) success += 1;
    }
    return if (total == 0) 0 else @as(f64, @floatFromInt(success)) / @as(f64, @floatFromInt(total));
}

fn collectContextRanks(allocator: std.mem.Allocator, records: []const Record) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    for (records) |record| {
        if (record.context_best_rank > 0) try out.append(allocator, record.context_best_rank);
    }
    return try out.toOwnedSlice(allocator);
}

fn round4(v: f64) f64 {
    return @as(f64, @floatFromInt(@as(i64, @intFromFloat(@round(v * 10000.0))))) / 10000.0;
}

fn round2(v: f64) f64 {
    return @as(f64, @floatFromInt(@as(i64, @intFromFloat(@round(v * 100.0))))) / 100.0;
}

fn millisDelta(start_ms: i64, end_ms: i64) f64 {
    if (end_ms <= start_ms) return 0;
    return @floatFromInt(end_ms - start_ms);
}

fn makeFailedRecord(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    repetition: u32,
    provider: []const u8,
    model: []const u8,
    latency_ms: f64,
    reason: []const u8,
) !Record {
    return makeRecord(allocator, task_id, repetition, provider, model, latency_ms, false, false, false, false, false, 0, 0, .{}, reason);
}

fn makeRecord(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    repetition: u32,
    provider: []const u8,
    model: []const u8,
    latency_ms: f64,
    command_success: bool,
    proposal_valid: bool,
    apply_success: bool,
    validation_pass: bool,
    task_success: bool,
    steps: usize,
    repair_attempts: u8,
    usage: ai.provider.TokenUsage,
    reason: []const u8,
) !Record {
    return .{
        .task_id = try allocator.dupe(u8, task_id),
        .repetition = repetition,
        .provider = try allocator.dupe(u8, provider),
        .model = try allocator.dupe(u8, model),
        .latency_ms = latency_ms,
        .command_success = command_success,
        .proposal_valid = proposal_valid,
        .apply_success = apply_success,
        .validation_pass = validation_pass,
        .task_success = task_success,
        .steps = steps,
        .repair_attempts = repair_attempts,
        .reported_tokens = .{
            .prompt = usage.prompt_tokens,
            .completion = usage.completion_tokens,
            .total = usage.total_tokens,
        },
        .reason = try allocator.dupe(u8, reason),
    };
}

test "ai-flow evaluator loads corpus and writes summary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);

    const code = try run(allocator, io, &environ, .{
        .provider = "fake",
        .repeat = 1,
        .max_steps = 4,
        .output = ".zig-cache/eval/test.jsonl",
        .corpus = "fixtures/eval/agent_reliability.json",
        .min_success_rate = 1.0,
    }, &out);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"success_rate\"") != null);
}

test "ai-flow evaluator loads retrieval context corpus" {
    const allocator = std.testing.allocator;
    const tasks = try loadCorpus(allocator, std.testing.io, "fixtures/eval/retrieval_context.json");
    defer freeTasks(allocator, tasks);
    try std.testing.expect(tasks.len >= 30);
    try std.testing.expect(tasks[0].context_only);
    try std.testing.expect(tasks[0].expect.context_includes.len > 0);
}

test "ai-flow evaluator runs retrieval context corpus" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);

    const code = try run(allocator, io, &environ, .{
        .provider = "fake",
        .repeat = 1,
        .max_steps = 4,
        .output = ".zig-cache/eval/retrieval_context.test.jsonl",
        .corpus = "fixtures/eval/retrieval_context.json",
        .min_success_rate = 0.8,
    }, &out);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"success_rate\":1") != null);
}

test "ai-flow evaluator runs multi-file edit corpus" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);

    const tasks = try loadCorpus(allocator, io, "fixtures/eval/multi_file_edits.json");
    defer freeTasks(allocator, tasks);
    try std.testing.expect(tasks.len >= 6);
    try std.testing.expect(tasks[0].expect.files.len >= 2);

    const code = try run(allocator, io, &environ, .{
        .provider = "fake",
        .repeat = 1,
        .max_steps = 4,
        .output = ".zig-cache/eval/multi_file_edits.test.jsonl",
        .corpus = "fixtures/eval/multi_file_edits.json",
        .min_success_rate = 1.0,
    }, &out);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"success_rate\":1") != null);
}

test "ai-flow evaluator loads zig real agent corpus" {
    const allocator = std.testing.allocator;
    const tasks = try loadCorpus(allocator, std.testing.io, "fixtures/eval/zig_real_agent.json");
    defer freeTasks(allocator, tasks);
    try std.testing.expect(tasks.len >= 4);
    try std.testing.expect(tasks[1].expect.min_steps >= 20);
    try std.testing.expect(tasks[2].expect.expect_repair);
    try std.testing.expect(tasks[3].expect.files.len >= 3);
}

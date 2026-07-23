const std = @import("std");
const workspace = @import("forge-workspace");
const provider_mod = @import("../provider.zig");
const context = @import("../context.zig");
const agent_event = @import("../agent_event.zig");

pub const EventLogger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, session_id: []const u8) EventLogger {
        return .{ .allocator = allocator, .io = io, .session_id = session_id };
    }

    pub fn deinit(_: *EventLogger) void {}

    fn appendJson(self: *EventLogger, json: []const u8) !void {
        try workspace.sessions.appendEvent(self.allocator, self.io, self.session_id, json);
    }

    pub fn sessionStarted(self: *EventLogger, config: anytype, intent: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.session_started),
            intent: []const u8,
            mode: []const u8,
            capability: []const u8,
            max_steps: u32,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .intent = intent,
            .mode = @tagName(config.mode),
            .capability = @tagName(config.capability_profile),
            .max_steps = config.max_steps,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn contextManifestBuilt(self: *EventLogger, builder: *const context.ContextBuilder) !void {
        var has_import_neighbors = false;
        for (builder.blocks.items) |block| {
            if (block.block_type == .imports) {
                has_import_neighbors = true;
                break;
            }
        }
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.context_manifest_built),
            budget_bytes: usize,
            used_bytes: usize,
            blocks: usize,
            has_import_neighbors: bool,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .budget_bytes = builder.max_bytes,
            .used_bytes = builder.used_bytes,
            .blocks = builder.blocks.items.len,
            .has_import_neighbors = has_import_neighbors,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn telemetry(self: *EventLogger, payload: struct {
        phase: []const u8,
        duration_ms: i64,
        bytes: usize = 0,
        items: usize = 0,
        detail: []const u8 = "",
    }) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.telemetry),
            phase: []const u8,
            duration_ms: i64,
            bytes: usize,
            items: usize,
            detail: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .phase = payload.phase,
            .duration_ms = payload.duration_ms,
            .bytes = payload.bytes,
            .items = payload.items,
            .detail = payload.detail,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn contextCompacted(self: *EventLogger, reason: []const u8, before_bytes: usize, after_bytes: usize, step_index: u32, attempt: u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.context_compacted),
            reason: []const u8,
            step: u32,
            attempt: u8,
            before_bytes: usize,
            after_bytes: usize,
            saved_bytes: usize,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .reason = reason,
            .step = step_index,
            .attempt = attempt,
            .before_bytes = before_bytes,
            .after_bytes = after_bytes,
            .saved_bytes = if (before_bytes > after_bytes) before_bytes - after_bytes else 0,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn toolCall(self: *EventLogger, step: u32, tool: []const u8, args_json: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.tool_call),
            step: u32,
            tool: []const u8,
            reason: []const u8,
            args_preview: []const u8,
            args_json: []const u8,
        };
        const preview = argsPreview(args_json);
        const reason = toolReason(tool);
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .step = step,
            .tool = tool,
            .reason = reason,
            .args_preview = preview,
            .args_json = args_json,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn toolResult(self: *EventLogger, step: u32, kind: []const u8, summary: []const u8, run_id: ?[]const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.tool_result),
            step: u32,
            kind: []const u8,
            summary: []const u8,
            run_id: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .step = step,
            .kind = kind,
            .summary = summary,
            .run_id = run_id orelse "",
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn proposalCreated(self: *EventLogger, proposal_path: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.proposal_created),
            proposal_path: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{ .proposal_path = proposal_path }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn validationStarted(self: *EventLogger, attempt: u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.validation_started),
            attempt: u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{ .attempt = attempt }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn validationResult(self: *EventLogger, attempt: u8, passed: bool, task_count: u32, failed_count: u32, hint_paths: []const []const u8, report: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.validation_result),
            attempt: u8,
            passed: bool,
            task_count: u32,
            failed_count: u32,
            hint_paths: []const []const u8,
            report: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .attempt = attempt,
            .passed = passed,
            .task_count = task_count,
            .failed_count = failed_count,
            .hint_paths = hint_paths,
            .report = if (report.len > 2048) report[0..2048] else report,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn subagentStarted(self: *EventLogger, role: []const u8, label: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.subagent_started),
            role: []const u8,
            label: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .role = role,
            .label = label,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn subagentResult(self: *EventLogger, role: []const u8, label: []const u8, text: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.subagent_result),
            role: []const u8,
            label: []const u8,
            text_preview: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .role = role,
            .label = label,
            .text_preview = if (text.len > 2048) text[0..2048] else text,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn finalAnswer(self: *EventLogger, text: []const u8) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.final_answer),
            text: []const u8,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{ .text = text }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }

    pub fn runCompleted(self: *EventLogger, payload: anytype) !void {
        const Json = struct {
            schema_version: u32 = agent_event.schema_version,
            type: []const u8 = agent_event.typeName(.run_completed),
            steps: usize,
            repair_attempts: u8,
            proposal_path: []const u8,
            response_text: []const u8,
            reported_tokens: provider_mod.TokenUsage,
        };
        const json = try std.json.Stringify.valueAlloc(self.allocator, Json{
            .steps = payload.steps.len,
            .repair_attempts = payload.repair_attempts,
            .proposal_path = payload.proposal_rel orelse "",
            .response_text = payload.response_text orelse "",
            .reported_tokens = payload.usage,
        }, .{});
        defer self.allocator.free(json);
        try self.appendJson(json);
    }
};

fn toolReason(tool: []const u8) []const u8 {
    if (std.mem.eql(u8, tool, "read_file")) return "Gather line-level evidence from a specific file.";
    if (std.mem.eql(u8, tool, "codebase_search")) return "Semantic retrieval to find relevant symbols/files.";
    if (std.mem.eql(u8, tool, "search")) return "Keyword search to locate relevant lines quickly.";
    if (std.mem.eql(u8, tool, "list_tree")) return "Inspect workspace structure to find likely files.";
    if (std.mem.eql(u8, tool, "run_command")) return "Run a command to validate or gather runtime evidence.";
    if (std.mem.eql(u8, tool, "apply_proposal")) return "Apply a proposed change via transaction.";
    return "Execute a tool to gather missing evidence.";
}

fn argsPreview(args_json: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    return if (trimmed.len > 160) trimmed[0..160] else trimmed;
}

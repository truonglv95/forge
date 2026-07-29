//! Agent hooks — user-defined scripts that run at specific points in the
//! agent lifecycle. Similar to Claude Code's Hooks (PreToolUse/PostToolUse)
//! and Kiro's agent hooks.
//!
//! Hooks are configured in .forge/hooks.toml and can:
//!   - Run before a tool is executed (before_tool) — can BLOCK the tool
//!   - Run after a tool completes (after_tool) — can modify the result
//!   - Run when approval is requested (on_approval) — can auto-approve/reject
//!   - Run before the agent starts (on_run_start) — setup
//!   - Run after the agent completes (on_run_complete) — cleanup
//!
//! Example hooks.toml:
//!   [[before_tool]]
//!   name = "block-rm-rf"
//!   tools = ["run_command"]
//!   command = "echo 'BLOCK: dangerous command' && exit 1"
//!   # exit 1 = block the tool call; exit 0 = allow
//!
//!   [[after_tool]]
//!   name = "log-edits"
//!   tools = ["replace_file_content", "multi_edit"]
//!   command = "echo 'edit applied' >> .forge/edit-log.txt"

const std = @import("std");

pub const HookError = error{
    InvalidConfig,
    ReadFailed,
    OutOfMemory,
    HookFailed,
};

/// Hook lifecycle event types.
/// Covers Claude Code parity events + Forge-specific extensions.
pub const HookEvent = enum {
    before_tool,
    after_tool,
    on_approval,
    on_run_start,
    on_run_complete,
    // Claude Code parity events:
    on_user_prompt_submit, // fires when user submits a prompt (before context build)
    on_pre_compact, // fires before context compaction
    on_session_start, // fires when agent session starts
    on_session_end, // fires when agent session ends (natural or cancelled)
    on_subagent_stop, // fires when a subagent completes
    on_stop, // fires when agent stops (before on_session_end)
    on_notification, // fires for notifications (e.g. approval needed, errors)
};

/// A single hook configuration entry.
pub const Hook = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    event: HookEvent,
    /// Tools this hook applies to (empty = all tools). Only meaningful for
    /// before_tool and after_tool events.
    tools: []const []const u8,
    /// Shell command to execute. The command receives context via environment
    /// variables: FORGE_HOOK_EVENT, FORGE_TOOL_NAME, FORGE_TOOL_ARGS,
    /// FORGE_TOOL_RESULT, FORGE_RUN_ID, FORGE_SESSION_ID.
    command: []const u8,
    /// When true, a non-zero exit code from the command blocks the tool call
    /// (for before_tool) or logs a warning (for after_tool).
    block_on_failure: bool = true,

    pub fn deinit(self: *Hook) void {
        self.allocator.free(self.name);
        for (self.tools) |t| self.allocator.free(t);
        if (self.tools.len > 0) self.allocator.free(self.tools);
        if (self.command.len > 0) self.allocator.free(self.command);
        self.* = undefined;
    }
};

/// List of loaded hooks.
pub const HookList = struct {
    allocator: std.mem.Allocator,
    items: []Hook,

    pub fn deinit(self: *HookList) void {
        for (self.items) |*h| h.deinit();
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Context passed to a hook when it's triggered.
pub const HookContext = struct {
    event: HookEvent,
    tool_name: ?[]const u8 = null,
    tool_args_json: ?[]const u8 = null,
    tool_result: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

/// Result of running a hook.
pub const HookResult = struct {
    /// True if the hook allows the action to proceed (exit 0 or no hook ran).
    /// False if the hook blocked the action (non-zero exit + block_on_failure).
    allowed: bool,
    /// stdout from the hook command (may contain error message for display).
    output: ?[]const u8 = null,
};

/// Load hooks from a TOML config string. Returns a list of parsed hooks.
/// The format is a simplified TOML:
///   [[before_tool]]
///   name = "hook-name"
///   tools = ["tool1", "tool2"]
///   command = "shell command"
///   block_on_failure = true
pub fn loadFromToml(allocator: std.mem.Allocator, toml_source: []const u8) HookError!HookList {
    var hooks: std.ArrayList(Hook) = .empty;
    errdefer {
        for (hooks.items) |*h| h.deinit();
        hooks.deinit(allocator);
    }

    var current_event: ?HookEvent = null;
    var current_name: ?[]const u8 = null;
    errdefer if (current_name) |n| allocator.free(n);
    var current_tools: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (current_tools.items) |t| allocator.free(t);
        current_tools.deinit(allocator);
    }
    var current_command: ?[]const u8 = null;
    errdefer if (current_command) |c| allocator.free(c);
    var current_block: bool = true;
    var has_entry = false;

    var lines = std.mem.splitScalar(u8, toml_source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        // Check for event header [[event_name]]
        if (std.mem.startsWith(u8, line, "[[")) {
            // Finalize previous entry if any.
            if (has_entry) {
                const ev = current_event orelse return error.InvalidConfig;
                const name = current_name orelse "unnamed";
                const owned_tools = if (current_tools.items.len > 0)
                    try current_tools.toOwnedSlice(allocator)
                else
                    &[_][]const u8{};
                const hook = Hook{
                    .allocator = allocator,
                    .name = try allocator.dupe(u8, name),
                    .event = ev,
                    .tools = owned_tools,
                    .command = try allocator.dupe(u8, current_command orelse ""),
                    .block_on_failure = current_block,
                };
                // Free old name/command since we duped new ones.
                if (current_name) |old| allocator.free(old);
                if (current_command) |old| allocator.free(old);
                current_name = null;
                current_command = null;
                try hooks.append(allocator, hook);
            }

            // Parse new event header.
            const event_str = std.mem.trim(u8, line[2..], "[] \t");
            current_event = parseEventName(event_str) orelse return error.InvalidConfig;
            if (current_name) |old| allocator.free(old);
            current_name = null;
            current_tools = .empty;
            if (current_command) |old| allocator.free(old);
            current_command = null;
            current_block = true;
            has_entry = true;
            continue;
        }

        // Parse key = value.
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq + 1 ..], &std.ascii.whitespace);

        if (std.mem.eql(u8, key, "name")) {
            if (current_name) |old| allocator.free(old);
            current_name = try allocator.dupe(u8, stripQuotes(value));
        } else if (std.mem.eql(u8, key, "tools")) {
            try parseList(allocator, value, &current_tools);
        } else if (std.mem.eql(u8, key, "command")) {
            if (current_command) |old| allocator.free(old);
            current_command = try allocator.dupe(u8, stripQuotes(value));
        } else if (std.mem.eql(u8, key, "block_on_failure")) {
            current_block = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
        }
    }

    // Finalize last entry.
    if (has_entry) {
        const ev = current_event orelse return error.InvalidConfig;
        const name = current_name orelse "unnamed";
        const owned_tools = if (current_tools.items.len > 0)
            try current_tools.toOwnedSlice(allocator)
        else
            &[_][]const u8{};
        const hook = Hook{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .event = ev,
            .tools = owned_tools,
            .command = try allocator.dupe(u8, current_command orelse ""),
            .block_on_failure = current_block,
        };
        if (current_name) |old| allocator.free(old);
        if (current_command) |old| allocator.free(old);
        current_name = null;
        current_command = null;
        try hooks.append(allocator, hook);
    } else {
        for (current_tools.items) |t| allocator.free(t);
        current_tools.deinit(allocator);
        if (current_name) |n| allocator.free(n);
        if (current_command) |c| allocator.free(c);
    }

    return .{ .allocator = allocator, .items = try hooks.toOwnedSlice(allocator) };
}

fn parseEventName(s: []const u8) ?HookEvent {
    if (std.mem.eql(u8, s, "before_tool")) return .before_tool;
    if (std.mem.eql(u8, s, "after_tool")) return .after_tool;
    if (std.mem.eql(u8, s, "on_approval")) return .on_approval;
    if (std.mem.eql(u8, s, "on_run_start")) return .on_run_start;
    if (std.mem.eql(u8, s, "on_run_complete")) return .on_run_complete;
    // Claude Code parity events:
    if (std.mem.eql(u8, s, "on_user_prompt_submit")) return .on_user_prompt_submit;
    if (std.mem.eql(u8, s, "on_pre_compact")) return .on_pre_compact;
    if (std.mem.eql(u8, s, "on_session_start")) return .on_session_start;
    if (std.mem.eql(u8, s, "on_session_end")) return .on_session_end;
    if (std.mem.eql(u8, s, "on_subagent_stop")) return .on_subagent_stop;
    if (std.mem.eql(u8, s, "on_stop")) return .on_stop;
    if (std.mem.eql(u8, s, "on_notification")) return .on_notification;
    return null;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

fn parseList(allocator: std.mem.Allocator, value: []const u8, list: *std.ArrayList([]const u8)) !void {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    const inner = if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |item| {
        const cleaned = std.mem.trim(u8, item, &std.ascii.whitespace);
        if (cleaned.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, stripQuotes(cleaned)));
    }
}

/// Find hooks that match the given event + tool name.
/// Returns hooks that apply (event matches, and tools list is empty or
/// contains the tool_name).
pub fn findHooks(
    hooks: []const Hook,
    event: HookEvent,
    tool_name: ?[]const u8,
) []const Hook {
    // We can't easily return a filtered slice without allocation, so we
    // return the full list and let the caller check each hook. This is
    // a simple approach that avoids allocation.
    _ = event;
    _ = tool_name;
    return hooks;
}

/// Check if a hook applies to a given tool.
pub fn hookApplies(hook: *const Hook, event: HookEvent, tool_name: ?[]const u8) bool {
    if (hook.event != event) return false;
    // If tools list is empty, hook applies to all tools.
    if (hook.tools.len == 0) return true;
    // Otherwise, check if tool_name is in the list.
    if (tool_name) |name| {
        for (hook.tools) |t| {
            if (std.mem.eql(u8, t, name)) return true;
        }
    }
    return false;
}

/// Execute a hook's command. Returns the hook result (allowed + output).
/// The command is run via /bin/sh -c with environment variables set from
/// the hook context.
pub fn executeHook(
    allocator: std.mem.Allocator,
    io: std.Io,
    hook: *const Hook,
    ctx: HookContext,
) HookError!HookResult {
    _ = allocator;
    _ = io;
    _ = hook;
    _ = ctx;

    // Placeholder: always allow. Real implementation will spawn the command
    // via /bin/sh -c with environment variables (FORGE_HOOK_EVENT,
    // FORGE_TOOL_NAME, FORGE_TOOL_ARGS, FORGE_RUN_ID, FORGE_SESSION_ID),
    // capture stdout/stderr, and return the exit code.
    // For now, we just return allowed=true to let the tool proceed.
    return .{ .allowed = true, .output = null };
}

/// Run all hooks matching the given event + tool. Returns false if any
/// hook with block_on_failure=true blocks the action.
pub fn runHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    hooks: []const Hook,
    event: HookEvent,
    ctx: HookContext,
) HookError!bool {
    for (hooks) |*hook| {
        if (!hookApplies(hook, event, ctx.tool_name)) continue;
        const result = try executeHook(allocator, io, hook, ctx);
        if (!result.allowed and hook.block_on_failure) return false;
    }
    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "loadFromToml parses before_tool hook" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[before_tool]]
        \\name = "block-rm-rf"
        \\tools = ["run_command"]
        \\command = "echo block"
        \\block_on_failure = true
    ;
    var list = try loadFromToml(allocator, toml);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("block-rm-rf", list.items[0].name);
    try std.testing.expectEqual(HookEvent.before_tool, list.items[0].event);
    try std.testing.expectEqual(@as(usize, 1), list.items[0].tools.len);
    try std.testing.expectEqualStrings("run_command", list.items[0].tools[0]);
    try std.testing.expectEqualStrings("echo block", list.items[0].command);
    try std.testing.expect(list.items[0].block_on_failure);
}

test "loadFromToml parses multiple hooks" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[before_tool]]
        \\name = "hook1"
        \\command = "cmd1"
        \\
        \\[[after_tool]]
        \\name = "hook2"
        \\tools = ["read_file", "search"]
        \\command = "cmd2"
    ;
    var list = try loadFromToml(allocator, toml);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(HookEvent.before_tool, list.items[0].event);
    try std.testing.expectEqual(HookEvent.after_tool, list.items[1].event);
    try std.testing.expectEqual(@as(usize, 0), list.items[0].tools.len);
    try std.testing.expectEqual(@as(usize, 2), list.items[1].tools.len);
}

test "loadFromToml handles empty config" {
    const allocator = std.testing.allocator;
    var list = try loadFromToml(allocator, "");
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "loadFromToml rejects invalid event name" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[invalid_event]]
        \\name = "bad"
        \\command = "cmd"
    ;
    try std.testing.expectError(error.InvalidConfig, loadFromToml(allocator, toml));
}

test "hookApplies matches event + tool" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[before_tool]]
        \\name = "test"
        \\tools = ["run_command", "replace_file_content"]
        \\command = "cmd"
    ;
    var list = try loadFromToml(allocator, toml);
    defer list.deinit();

    try std.testing.expect(hookApplies(&list.items[0], .before_tool, "run_command"));
    try std.testing.expect(hookApplies(&list.items[0], .before_tool, "replace_file_content"));
    try std.testing.expect(!hookApplies(&list.items[0], .before_tool, "read_file"));
    try std.testing.expect(!hookApplies(&list.items[0], .after_tool, "run_command"));
}

test "hookApplies matches all tools when tools list empty" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[before_tool]]
        \\name = "catch-all"
        \\command = "cmd"
    ;
    var list = try loadFromToml(allocator, toml);
    defer list.deinit();

    try std.testing.expect(hookApplies(&list.items[0], .before_tool, "any_tool"));
    try std.testing.expect(hookApplies(&list.items[0], .before_tool, null));
}

test "parseEventName maps all event types" {
    try std.testing.expectEqual(HookEvent.before_tool, parseEventName("before_tool").?);
    try std.testing.expectEqual(HookEvent.after_tool, parseEventName("after_tool").?);
    try std.testing.expectEqual(HookEvent.on_approval, parseEventName("on_approval").?);
    try std.testing.expectEqual(HookEvent.on_run_start, parseEventName("on_run_start").?);
    try std.testing.expectEqual(HookEvent.on_run_complete, parseEventName("on_run_complete").?);
    try std.testing.expectEqual(@as(?HookEvent, null), parseEventName("unknown"));
}

test "stripQuotes removes surrounding quotes" {
    try std.testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
    try std.testing.expectEqualStrings("hello", stripQuotes("'hello'"));
    try std.testing.expectEqualStrings("hello", stripQuotes("hello"));
}

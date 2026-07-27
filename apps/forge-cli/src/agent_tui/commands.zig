const std = @import("std");
const ai = @import("forge-ai");

pub const Command = union(enum) {
    wipe_history,
    policy,
    tools_trust_all,
    tools_list,
    mode: ai.tools.Mode,
    mode_cycle,
    context,
    diff,
    events: ?[]const u8,
    timeline,
    mock,
    help,
    help_overlay,
    exit_app,
    resume_session: ?[]const u8,
    sessions,
    // TUI parity commands (Phase 13) — bring CLI workflows to TUI
    spec_list,
    spec_show: ?[]const u8,
    runs_list,
    runs_status,
    complete_prompt: ?[]const u8,
    // Phase 24: Additional commands for TUI completeness
    model_show,
    model_set: ?[]const u8,
    cost,
    capability,
    save: ?[]const u8,
    provider_show,
    review,
    // Phase 27: Context inspector
    inspect,
    // Phase 36: Search within conversation
    search: ?[]const u8,
    // Phase 37: Edit last user message
    edit_last,
    // Phase 41: Undo/redo agent actions
    undo,
    redo,
    // Phase 42: Selective clear
    clear_history,
    clear_context,
    // Phase 46-50: Additional TUI commands
    theme: ?[]const u8,
    config,
    help_detailed: ?[]const u8,
    export_markdown: ?[]const u8,
    // Phase 52-55: More TUI features
    bookmark: ?[]const u8,
    bookmark_list,
    copy_line: ?[]const u8,
    branch: ?[]const u8,
    // Phase 57-60: Advanced TUI features
    filter: ?[]const u8,
    stats,
    compact,
    pin: ?[]const u8,
    not_command,
};

fn matchesSlash(input: []const u8, name: []const u8) bool {
    if (input.len < 1 + name.len or input[0] != '/') return false;
    if (!std.mem.eql(u8, input[1..][0..name.len], name)) return false;
    return input.len == 1 + name.len or input[1 + name.len] == ' ';
}

pub fn parseSlashCommand(input: []const u8) Command {
    if (input.len == 0 or input[0] != '/') return .not_command;

    if (matchesSlash(input, "cls")) return .wipe_history;
    // /clear is handled below with selective options (Phase 42)
    if (matchesSlash(input, "policy")) return .policy;
    if (matchesSlash(input, "tools")) {
        if (std.mem.eql(u8, input, "/tools")) return .tools_list;
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .tools_list;
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        if (std.mem.eql(u8, args, "trust-all")) return .tools_trust_all;
        if (std.mem.eql(u8, args, "list")) return .tools_list;
        return .help;
    }
    if (matchesSlash(input, "context")) return .context;
    if (matchesSlash(input, "diff")) return .diff;
    if (matchesSlash(input, "timeline") or matchesSlash(input, "tl")) return .timeline;
    if (matchesSlash(input, "mock")) return .mock;
    if (matchesSlash(input, "help") or matchesSlash(input, "?")) {
        if (std.mem.eql(u8, input, "/help") or std.mem.eql(u8, input, "/?")) return .help;
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .help;
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .help_detailed = if (args.len > 0) args else null };
    }
    if (matchesSlash(input, "quit") or matchesSlash(input, "exit")) return .exit_app;
    if (matchesSlash(input, "sessions") or matchesSlash(input, "list")) return .sessions;

    // Phase 24: Additional commands for TUI completeness
    if (matchesSlash(input, "model") or matchesSlash(input, "m")) {
        if (std.mem.eql(u8, input, "/model") or std.mem.eql(u8, input, "/m")) return .model_show;
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .model_show;
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .model_set = if (args.len > 0) args else null };
    }
    if (matchesSlash(input, "cost") or matchesSlash(input, "usage")) return .cost;
    if (matchesSlash(input, "capability") or matchesSlash(input, "caps")) return .capability;
    if (matchesSlash(input, "provider") or matchesSlash(input, "prov")) return .provider_show;
    if (matchesSlash(input, "save")) {
        if (std.mem.eql(u8, input, "/save")) return .{ .save = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .save = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .save = if (args.len > 0) args else null };
    }
    if (matchesSlash(input, "review") or matchesSlash(input, "rev")) return .review;
    if (matchesSlash(input, "inspect") or matchesSlash(input, "insp")) return .inspect;
    // Phase 36: Search within conversation
    if (matchesSlash(input, "search") or matchesSlash(input, "find") or matchesSlash(input, "s")) {
        if (std.mem.eql(u8, input, "/search") or std.mem.eql(u8, input, "/find") or std.mem.eql(u8, input, "/s")) return .{ .search = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .search = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .search = if (args.len > 0) args else null };
    }
    // Phase 37: Edit last user message
    if (matchesSlash(input, "edit") or matchesSlash(input, "e")) return .edit_last;
    // Phase 41: Undo/redo
    if (matchesSlash(input, "undo") or matchesSlash(input, "u")) return .undo;
    if (matchesSlash(input, "redo")) return .redo;
    // Phase 46-50: Additional commands
    if (matchesSlash(input, "theme")) {
        if (std.mem.eql(u8, input, "/theme")) return .{ .theme = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .theme = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .theme = if (args.len > 0) args else null };
    }
    if (matchesSlash(input, "config") or matchesSlash(input, "cfg")) return .config;
    if (matchesSlash(input, "export")) {
        if (std.mem.eql(u8, input, "/export")) return .{ .export_markdown = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .export_markdown = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .export_markdown = if (args.len > 0) args else null };
    }
    // Phase 52: Bookmark messages
    if (matchesSlash(input, "bookmark") or matchesSlash(input, "bm")) {
        if (std.mem.eql(u8, input, "/bookmark") or std.mem.eql(u8, input, "/bm")) return .bookmark_list;
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .bookmark_list;
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        if (std.mem.eql(u8, args, "list")) return .bookmark_list;
        return .{ .bookmark = if (args.len > 0) args else null };
    }
    // Phase 53: Copy specific line to clipboard
    if (matchesSlash(input, "copy") or matchesSlash(input, "cp")) {
        if (std.mem.eql(u8, input, "/copy") or std.mem.eql(u8, input, "/cp")) return .{ .copy_line = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .copy_line = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .copy_line = if (args.len > 0) args else null };
    }
    // Phase 55: Create git branch from conversation state
    if (matchesSlash(input, "branch")) {
        if (std.mem.eql(u8, input, "/branch")) return .{ .branch = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .branch = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .branch = if (args.len > 0) args else null };
    }
    // Phase 57: Filter conversation by role
    if (matchesSlash(input, "filter") or matchesSlash(input, "ft")) {
        if (std.mem.eql(u8, input, "/filter") or std.mem.eql(u8, input, "/ft")) return .{ .filter = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .filter = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .filter = if (args.len > 0) args else null };
    }
    // Phase 58: Show conversation statistics
    if (matchesSlash(input, "stats") or matchesSlash(input, "statistics")) return .stats;
    // Phase 59: Compact conversation
    if (matchesSlash(input, "compact")) return .compact;
    // Phase 60: Pin messages
    if (matchesSlash(input, "pin")) {
        if (std.mem.eql(u8, input, "/pin")) return .{ .pin = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .pin = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .pin = if (args.len > 0) args else null };
    }
    // Phase 42: Selective clear
    if (matchesSlash(input, "clear")) {
        if (std.mem.eql(u8, input, "/clear") or std.mem.eql(u8, input, "/cls")) return .wipe_history;
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .wipe_history;
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        if (std.mem.eql(u8, args, "history")) return .clear_history;
        if (std.mem.eql(u8, args, "context")) return .clear_context;
        return .wipe_history;
    }

    // TUI parity commands (Phase 13)
    // /spec [list|show <id>] — Kiro-style spec management
    if (matchesSlash(input, "spec") or matchesSlash(input, "specs")) {
        if (std.mem.eql(u8, input, "/spec") or std.mem.eql(u8, input, "/specs")) return .spec_list;
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .spec_list;
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        if (args.len == 0 or std.mem.eql(u8, args, "list")) return .spec_list;
        if (std.mem.startsWith(u8, args, "show ")) {
            return .{ .spec_show = std.mem.trim(u8, args[5..], &std.ascii.whitespace) };
        }
        if (std.mem.startsWith(u8, args, "show")) {
            const id = std.mem.trim(u8, args[4..], &std.ascii.whitespace);
            return .{ .spec_show = if (id.len > 0) id else null };
        }
        return .spec_list;
    }
    // /runs [list|status] — Antigravity-style background run monitoring
    if (matchesSlash(input, "runs") or matchesSlash(input, "run")) {
        if (std.mem.eql(u8, input, "/runs") or std.mem.eql(u8, input, "/run")) return .runs_list;
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .runs_list;
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        if (std.mem.eql(u8, args, "status")) return .runs_status;
        return .runs_list;
    }
    // /complete <prompt> — inline completion request
    if (matchesSlash(input, "complete") or matchesSlash(input, "comp")) {
        if (std.mem.eql(u8, input, "/complete") or std.mem.eql(u8, input, "/comp")) return .{ .complete_prompt = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .complete_prompt = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        return .{ .complete_prompt = if (args.len > 0) args else null };
    }
    if (matchesSlash(input, "events") or matchesSlash(input, "ev")) {
        if (std.mem.eql(u8, input, "/events") or std.mem.eql(u8, input, "/ev")) return .{ .events = null };
        const space_index = std.mem.indexOfScalar(u8, input, ' ') orelse return .{ .events = null };
        const args = std.mem.trim(u8, input[space_index + 1 ..], &std.ascii.whitespace);
        if (args.len == 0) return .{ .events = null };
        return .{ .events = args };
    }

    if (input.len >= 5 and input[0] == '/' and input[1] == 'm' and input[2] == 'o' and input[3] == 'd' and input[4] == 'e') {
        if (input.len == 5) return .mode_cycle;
        if (input.len > 5 and input[5] == ' ') {
            const args = std.mem.trim(u8, input[6..], &std.ascii.whitespace);
            if (args.len == 0) return .mode_cycle;
            return .{ .mode = parseModeName(args) orelse return .help };
        }
    }

    if (input.len >= 7 and input[0] == '/' and input[1] == 'r' and input[2] == 'e' and input[3] == 's' and input[4] == 'u' and input[5] == 'm' and input[6] == 'e') {
        if (input.len == 7) return .{ .resume_session = null };
        if (input.len > 7 and input[7] == ' ') {
            const args = std.mem.trim(u8, input[8..], &std.ascii.whitespace);
            if (args.len == 0) return .{ .resume_session = null };
            return .{ .resume_session = args };
        }
    }
    if (matchesSlash(input, "r")) {
        return .{ .resume_session = null };
    }

    return .help;
}

pub fn parseModeName(name: []const u8) ?ai.tools.Mode {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "ask")) return ai.tools.Mode.ask;
    if (std.mem.eql(u8, trimmed, "plan")) return ai.tools.Mode.plan;
    if (std.mem.eql(u8, trimmed, "agent")) return ai.tools.Mode.agent;
    return null;
}

pub fn modeLabel(mode: ai.tools.Mode) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .plan => "plan",
        .agent => "agent",
    };
}

pub fn nextMode(mode: ai.tools.Mode) ai.tools.Mode {
    return switch (mode) {
        .ask => .plan,
        .plan => .agent,
        .agent => .ask,
    };
}

pub fn helpText() []const u8 {
    return
    \\Commands: /clear /policy /tools /mode /context /diff /events /timeline /resume /sessions /spec /runs /complete /model /cost /capability /provider /save /review /inspect /search /edit /undo /redo /theme /config /export /bookmark /copy /branch /filter /stats /compact /pin /help [cmd] /quit
    \\Keys: Tab=autocomplete | Ctrl+M=mode | Ctrl+R=review | Ctrl+J=newline | Ctrl+Y=copy code | ?=help | Esc=close | PgUp/PgDn=scroll | Ctrl+C=cancel/quit
    ;
}

/// Full help overlay text shown when user presses '?' or runs /help overlay.
pub fn helpOverlayText() []const u8 {
    return
    \\╔══════════════════════════════════════════════════════════════╗
    \\║                  FORGE TUI — Keyboard Shortcuts               ║
    \\╠══════════════════════════════════════════════════════════════╣
    \\║  Input Editing                                               ║
    \\║    Enter          Submit message / command                   ║
    \\║    Tab            Autocomplete command / toggle explorer     ║
    \\║    Ctrl+U         Clear input line                           ║
    \\║    Ctrl+W         Delete word backward                       ║
    \\║    Up/Down        History navigation (when input empty)      ║
    \\║    Left/Right     Move cursor                                ║
    \\║    Home/End       Jump to start/end                          ║
    \\║                                                               ║
    \\║  Agent Control                                               ║
    \\║    Ctrl+M         Cycle mode (ask → plan → agent)            ║
    \\║    Ctrl+C         Cancel agent / quit (press twice)          ║
    \\║    Ctrl+R         Review last tool output                    ║
    \\║    Ctrl+L         Clear screen                               ║
    \\║                                                               ║
    \\║  Navigation                                                  ║
    \\║    Esc           Close events/timeline/help overlay          ║
    \\║    PgUp/PgDn      Scroll chat history                        ║
    \\║    ?              Show this help overlay                     ║
    \\║                                                               ║
    \\║  Slash Commands                                             ║
    \\║    /clear         Clear conversation                         ║
    \\║    /mode [name]   Switch mode (ask/plan/agent)               ║
    \\║    /model [name]  Show or set model                          ║
    \\║    /context       Show context manifest                      ║
    \\║    /cost          Show token usage                           ║
    \\║    /capability    Show provider capabilities                 ║
    \\║    /provider      Show current provider                      ║
    \\║    /tools list    List available tools                       ║
    \\║    /spec [list]   List specs (Kiro-style)                    ║
    \\║    /runs [status] List background runs                       ║
    \\║    /complete [p]  Request inline completion                  ║
    \\║    /review        Run code review on git diff                ║
    \\║    /save [path]   Save conversation                          ║
    \\║    /diff          Show proposal diff                         ║
    \\║    /events        Show event log                             ║
    \\║    /timeline      Show agent timeline                        ║
    \\║    /sessions      List saved sessions                        ║
    \\║    /resume [id]   Resume a session                           ║
    \\║    /help          Show quick help                            ║
    \\║    /quit          Exit Forge TUI                             ║
    \\╚══════════════════════════════════════════════════════════════╝
    ;
}

test "matchesSlash" {
    const slash_clear = [_]u8{ '/', 'c', 'l', 'e', 'a', 'r' };
    try std.testing.expect(matchesSlash(&slash_clear, "clear"));
    try std.testing.expect(matchesSlash("/policy", "policy"));
}

test "parse slash commands" {
    const slash_clear = [_]u8{ '/', 'c', 'l', 'e', 'a', 'r' };
    try std.testing.expect(parseSlashCommand(&slash_clear) == .wipe_history);
    try std.testing.expect(parseSlashCommand("/cls") == .wipe_history);
    try std.testing.expect(parseSlashCommand("/clear") == .wipe_history);
    try std.testing.expect(parseSlashCommand("/policy") == .policy);
    try std.testing.expect(parseSlashCommand("/tools trust-all") == .tools_trust_all);
    try std.testing.expect(parseSlashCommand("/timeline") == .timeline);
    try std.testing.expect(parseSlashCommand("/tl") == .timeline);
    try std.testing.expect(parseSlashCommand("/mock") == .mock);
    try std.testing.expect(parseSlashCommand("/help") == .help);
    try std.testing.expect(parseSlashCommand("/quit") == .exit_app);
    try std.testing.expect(parseSlashCommand("/exit") == .exit_app);
    try std.testing.expect(parseSlashCommand("/sessions") == .sessions);
    {
        const cmd = parseSlashCommand("/events");
        try std.testing.expect(cmd == .events);
        try std.testing.expect(cmd.events == null);
    }
    {
        const cmd = parseSlashCommand("/events sess_1");
        try std.testing.expect(cmd == .events);
        try std.testing.expectEqualStrings("sess_1", cmd.events.?);
    }
    try std.testing.expect(parseSlashCommand("/mode") == .mode_cycle);
    try std.testing.expect(parseSlashCommand("hello") == .not_command);
}

test "parseModeName" {
    try std.testing.expectEqual(ai.tools.Mode.ask, parseModeName("ask").?);
    try std.testing.expectEqual(ai.tools.Mode.plan, parseModeName("plan").?);
    try std.testing.expectEqual(ai.tools.Mode.agent, parseModeName("agent").?);
    try std.testing.expect(parseModeName("invalid") == null);
}

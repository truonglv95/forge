const std = @import("std");
const ai = @import("forge-ai");

pub const Command = union(enum) {
    wipe_history,
    policy,
    mode: ai.tools.Mode,
    mode_cycle,
    context,
    diff,
    help,
    exit_app,
    resume_session: ?[]const u8,
    sessions,
    not_command,
};

fn matchesSlash(input: []const u8, name: []const u8) bool {
    if (input.len < 1 + name.len or input[0] != '/') return false;
    if (!std.mem.eql(u8, input[1..][0..name.len], name)) return false;
    return input.len == 1 + name.len or input[1 + name.len] == ' ';
}

pub fn parseSlashCommand(input: []const u8) Command {
    if (input.len == 0 or input[0] != '/') return .not_command;

    if (matchesSlash(input, "cls") or matchesSlash(input, "clear")) return .wipe_history;
    if (matchesSlash(input, "policy")) return .policy;
    if (matchesSlash(input, "context")) return .context;
    if (matchesSlash(input, "diff")) return .diff;
    if (matchesSlash(input, "help") or matchesSlash(input, "?")) return .help;
    if (matchesSlash(input, "quit") or matchesSlash(input, "exit")) return .exit_app;
    if (matchesSlash(input, "sessions") or matchesSlash(input, "list")) return .sessions;

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
    \\Commands: /clear|/cls /policy /mode [ask|plan|agent] /context /diff /resume [id] /sessions /help /quit
    \\Keys: Tab policy | Ctrl+M mode | PgUp/PgDn scroll | d/a/n proposal | Ctrl+C cancel/quit
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
    try std.testing.expect(parseSlashCommand("/help") == .help);
    try std.testing.expect(parseSlashCommand("/quit") == .exit_app);
    try std.testing.expect(parseSlashCommand("/sessions") == .sessions);
    try std.testing.expect(parseSlashCommand("/mode") == .mode_cycle);
    try std.testing.expect(parseSlashCommand("hello") == .not_command);
}

test "parseModeName" {
    try std.testing.expectEqual(ai.tools.Mode.ask, parseModeName("ask").?);
    try std.testing.expectEqual(ai.tools.Mode.plan, parseModeName("plan").?);
    try std.testing.expectEqual(ai.tools.Mode.agent, parseModeName("agent").?);
    try std.testing.expect(parseModeName("invalid") == null);
}

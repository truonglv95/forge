const std = @import("std");

pub const GlobalFlags = struct {
    workspace: ?[]const u8 = null,
    json: bool = false,
    no_color: bool = false,
    quiet: bool = false,
    non_interactive: bool = false,
    dry_run: bool = false,
    yes: bool = false,
    auto_approve: bool = false,
    trust_all: bool = false,
    once: bool = false,
    max_polls: u32 = 0,
    max_steps: u32 = 0,
    fetch: bool = false,
    files: []const []const u8 = &.{},
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    budget_bytes: usize = 0,
    capability: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    events: ?[]const u8 = null,
    repeat: u32 = 1,
    output: ?[]const u8 = null,
    corpus: ?[]const u8 = null,
    conversation: ?[]const u8 = null,
    min_success_rate: f64 = 0.0,
    baseline: ?[]const u8 = null,
    max_success_regression: f64 = 0.0,
    body: ?[]const u8 = null,
    section: ?[]const u8 = null,
    intent: ?[]const u8 = null,
    // Inline completion flags (RFC-0013)
    file: ?[]const u8 = null,
    line: ?u32 = null,
    character: ?u32 = null,
    max_tokens: u32 = 64,
    timeout_ms: u64 = 3000,
    // Chat REPL flags (RFC-0017)
    pipe: bool = false,
    resume_session: ?[]const u8 = null,
    // Background agent flags (RFC-0015)
    background: bool = false,
    follow: bool = false,
    timeout_seconds: u64 = 0,
    // Provider routing flags (RFC-0016)
    context_bytes: ?usize = null,
    require_tools: bool = false,
    require_streaming: bool = false,
    prefer_local: bool = false,
    max_price_per_mtok: ?u32 = null,
    strengths: ?[]const u8 = null,
};

pub const Command = enum {
    help,
    version,
    doctor,
    inspect,
    search,
    watch,
    diff,
    apply,
    undo,
    history,
    task,
    check,
    index,
    context,
    ask,
    run,
    agent,
    plan,
    parsers,
    eval,
    ecosystem,
    unknown,
    ext,
    spec,
    complete,
    providers,
    models,
    chat,
};

pub const CliArgs = struct {
    flags: GlobalFlags,
    command: Command,
    positional: []const []const u8,

    pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !CliArgs {
        var flags = GlobalFlags{};
        var command: Command = .help;
        var positional: std.ArrayList([]const u8) = .empty;
        var files: std.ArrayList([]const u8) = .empty;
        errdefer files.deinit(allocator);

        var i: usize = 1; // Skip executable name
        var cmd_found = false;

        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "--json")) {
                    flags.json = true;
                } else if (std.mem.eql(u8, arg, "--no-color")) {
                    flags.no_color = true;
                } else if (std.mem.eql(u8, arg, "--quiet")) {
                    flags.quiet = true;
                } else if (std.mem.eql(u8, arg, "--non-interactive")) {
                    flags.non_interactive = true;
                } else if (std.mem.eql(u8, arg, "--dry-run")) {
                    flags.dry_run = true;
                } else if (std.mem.eql(u8, arg, "--yes")) {
                    flags.yes = true;
                } else if (std.mem.eql(u8, arg, "--auto-approve")) {
                    flags.auto_approve = true;
                } else if (std.mem.eql(u8, arg, "--trust-all")) {
                    flags.trust_all = true;
                    flags.auto_approve = true;
                } else if (std.mem.eql(u8, arg, "--once")) {
                    flags.once = true;
                } else if (std.mem.eql(u8, arg, "--file")) {
                    i += 1;
                    if (i < args.len) try files.append(allocator, args[i]);
                } else if (std.mem.eql(u8, arg, "--max-polls")) {
                    i += 1;
                    if (i < args.len) flags.max_polls = try std.fmt.parseInt(u32, args[i], 10);
                } else if (std.mem.eql(u8, arg, "--max-steps")) {
                    i += 1;
                    if (i < args.len) flags.max_steps = try std.fmt.parseInt(u32, args[i], 10);
                } else if (std.mem.eql(u8, arg, "--fetch")) {
                    flags.fetch = true;
                } else if (std.mem.eql(u8, arg, "--workspace")) {
                    i += 1;
                    if (i < args.len) {
                        flags.workspace = args[i];
                    }
                } else if (std.mem.eql(u8, arg, "--provider")) {
                    i += 1;
                    if (i < args.len) flags.provider = args[i];
                } else if (std.mem.eql(u8, arg, "--model")) {
                    i += 1;
                    if (i < args.len) flags.model = args[i];
                } else if (std.mem.eql(u8, arg, "--budget-bytes")) {
                    i += 1;
                    if (i < args.len) flags.budget_bytes = try std.fmt.parseInt(usize, args[i], 10);
                } else if (std.mem.eql(u8, arg, "--capability")) {
                    i += 1;
                    if (i < args.len) flags.capability = args[i];
                } else if (std.mem.eql(u8, arg, "--mode")) {
                    i += 1;
                    if (i < args.len) flags.mode = args[i];
                } else if (std.mem.eql(u8, arg, "--events")) {
                    i += 1;
                    if (i < args.len) flags.events = args[i];
                } else if (std.mem.eql(u8, arg, "--repeat")) {
                    i += 1;
                    if (i < args.len) flags.repeat = try std.fmt.parseInt(u32, args[i], 10);
                } else if (std.mem.eql(u8, arg, "--output")) {
                    i += 1;
                    if (i < args.len) flags.output = args[i];
                } else if (std.mem.eql(u8, arg, "--corpus")) {
                    i += 1;
                    if (i < args.len) flags.corpus = args[i];
                } else if (std.mem.eql(u8, arg, "--min-success-rate")) {
                    i += 1;
                    if (i < args.len) flags.min_success_rate = try std.fmt.parseFloat(f64, args[i]);
                } else if (std.mem.eql(u8, arg, "--baseline")) {
                    i += 1;
                    if (i < args.len) flags.baseline = args[i];
                } else if (std.mem.eql(u8, arg, "--max-success-regression")) {
                    i += 1;
                    if (i < args.len) flags.max_success_regression = try std.fmt.parseFloat(f64, args[i]);
                } else if (std.mem.eql(u8, arg, "-c")) {
                    i += 1;
                    if (i < args.len) flags.conversation = args[i];
                } else if (std.mem.startsWith(u8, arg, "--conversation=")) {
                    flags.conversation = arg["--conversation=".len..];
                } else if (std.mem.eql(u8, arg, "--body")) {
                    i += 1;
                    if (i < args.len) flags.body = args[i];
                } else if (std.mem.startsWith(u8, arg, "--body=")) {
                    flags.body = arg["--body=".len..];
                } else if (std.mem.eql(u8, arg, "--section")) {
                    i += 1;
                    if (i < args.len) flags.section = args[i];
                } else if (std.mem.startsWith(u8, arg, "--section=")) {
                    flags.section = arg["--section=".len..];
                } else if (std.mem.eql(u8, arg, "--intent")) {
                    i += 1;
                    if (i < args.len) flags.intent = args[i];
                } else if (std.mem.startsWith(u8, arg, "--intent=")) {
                    flags.intent = arg["--intent=".len..];
                } else if (std.mem.eql(u8, arg, "--line")) {
                    i += 1;
                    if (i < args.len) flags.line = std.fmt.parseInt(u32, args[i], 10) catch null;
                } else if (std.mem.startsWith(u8, arg, "--line=")) {
                    flags.line = std.fmt.parseInt(u32, arg["--line=".len..], 10) catch null;
                } else if (std.mem.eql(u8, arg, "--char") or std.mem.eql(u8, arg, "--character")) {
                    i += 1;
                    if (i < args.len) flags.character = std.fmt.parseInt(u32, args[i], 10) catch null;
                } else if (std.mem.startsWith(u8, arg, "--char=")) {
                    flags.character = std.fmt.parseInt(u32, arg["--char=".len..], 10) catch null;
                } else if (std.mem.startsWith(u8, arg, "--character=")) {
                    flags.character = std.fmt.parseInt(u32, arg["--character=".len..], 10) catch null;
                } else if (std.mem.eql(u8, arg, "--max-tokens")) {
                    i += 1;
                    if (i < args.len) flags.max_tokens = std.fmt.parseInt(u32, args[i], 10) catch 64;
                } else if (std.mem.startsWith(u8, arg, "--max-tokens=")) {
                    flags.max_tokens = std.fmt.parseInt(u32, arg["--max-tokens=".len..], 10) catch 64;
                } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
                    i += 1;
                    if (i < args.len) flags.timeout_ms = std.fmt.parseInt(u64, args[i], 10) catch 3000;
                } else if (std.mem.startsWith(u8, arg, "--timeout-ms=")) {
                    flags.timeout_ms = std.fmt.parseInt(u64, arg["--timeout-ms=".len..], 10) catch 3000;
                } else if (std.mem.eql(u8, arg, "--context-bytes")) {
                    i += 1;
                    if (i < args.len) flags.context_bytes = std.fmt.parseInt(usize, args[i], 10) catch null;
                } else if (std.mem.startsWith(u8, arg, "--context-bytes=")) {
                    flags.context_bytes = std.fmt.parseInt(usize, arg["--context-bytes=".len..], 10) catch null;
                } else if (std.mem.eql(u8, arg, "--max-price-per-mtok")) {
                    i += 1;
                    if (i < args.len) flags.max_price_per_mtok = std.fmt.parseInt(u32, args[i], 10) catch null;
                } else if (std.mem.startsWith(u8, arg, "--max-price-per-mtok=")) {
                    flags.max_price_per_mtok = std.fmt.parseInt(u32, arg["--max-price-per-mtok=".len..], 10) catch null;
                } else if (std.mem.eql(u8, arg, "--strengths")) {
                    i += 1;
                    if (i < args.len) flags.strengths = args[i];
                } else if (std.mem.startsWith(u8, arg, "--strengths=")) {
                    flags.strengths = arg["--strengths=".len..];
                } else if (std.mem.eql(u8, arg, "--resume")) {
                    i += 1;
                    if (i < args.len) flags.resume_session = args[i];
                } else if (std.mem.startsWith(u8, arg, "--resume=")) {
                    flags.resume_session = arg["--resume=".len..];
                } else if (std.mem.eql(u8, arg, "--background")) {
                    flags.background = true;
                } else if (std.mem.eql(u8, arg, "--follow")) {
                    flags.follow = true;
                } else if (std.mem.eql(u8, arg, "--timeout")) {
                    i += 1;
                    if (i < args.len) flags.timeout_seconds = std.fmt.parseInt(u64, args[i], 10) catch 0;
                } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
                    flags.timeout_seconds = std.fmt.parseInt(u64, arg["--timeout=".len..], 10) catch 0;
                } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    command = .help;
                    cmd_found = true;
                } else if (std.mem.eql(u8, arg, "--version")) {
                    command = .version;
                    cmd_found = true;
                } else if (std.mem.eql(u8, arg, "--file")) {
                    // Already handled above for --file (additive). Skip duplicate.
                    // (No-op: --file is handled in the first branch.)
                } else if (std.mem.eql(u8, arg, "--pipe")) {
                    flags.pipe = true;
                } else if (std.mem.eql(u8, arg, "--prefer-local")) {
                    flags.prefer_local = true;
                } else if (std.mem.eql(u8, arg, "--require-tools")) {
                    flags.require_tools = true;
                } else if (std.mem.eql(u8, arg, "--require-streaming")) {
                    flags.require_streaming = true;
                }
            } else if (!cmd_found) {
                if (std.mem.eql(u8, arg, "doctor")) command = .doctor else if (std.mem.eql(u8, arg, "inspect")) command = .inspect else if (std.mem.eql(u8, arg, "search")) command = .search else if (std.mem.eql(u8, arg, "watch")) command = .watch else if (std.mem.eql(u8, arg, "diff")) command = .diff else if (std.mem.eql(u8, arg, "apply")) command = .apply else if (std.mem.eql(u8, arg, "undo")) command = .undo else if (std.mem.eql(u8, arg, "history")) command = .history else if (std.mem.eql(u8, arg, "task")) command = .task else if (std.mem.eql(u8, arg, "check")) command = .check else if (std.mem.eql(u8, arg, "index")) command = .index else if (std.mem.eql(u8, arg, "context")) command = .context else if (std.mem.eql(u8, arg, "ask")) command = .ask else if (std.mem.eql(u8, arg, "run")) command = .run else if (std.mem.eql(u8, arg, "agent")) command = .agent else if (std.mem.eql(u8, arg, "plan")) command = .plan else if (std.mem.eql(u8, arg, "parsers")) command = .parsers else if (std.mem.eql(u8, arg, "eval")) command = .eval else if (std.mem.eql(u8, arg, "ecosystem")) command = .ecosystem else if (std.mem.eql(u8, arg, "ext")) command = .ext else if (std.mem.eql(u8, arg, "spec")) command = .spec else if (std.mem.eql(u8, arg, "complete")) command = .complete else if (std.mem.eql(u8, arg, "providers")) command = .providers else if (std.mem.eql(u8, arg, "models")) command = .models else if (std.mem.eql(u8, arg, "chat")) command = .chat else if (std.mem.eql(u8, arg, "help")) command = .help else if (std.mem.eql(u8, arg, "version")) command = .version else command = .unknown;
                cmd_found = true;
            } else {
                try positional.append(allocator, arg);
            }
        }

        // Default to help if no command was given and it's not a flags-only call
        if (!cmd_found and args.len > 1) {
            // We just leave it as help for now unless it's a version flag
        }

        flags.files = try files.toOwnedSlice(allocator);

        return CliArgs{
            .flags = flags,
            .command = command,
            .positional = try positional.toOwnedSlice(allocator),
        };
    }
};

test "CliArgs parses subcommands and flags" {
    const allocator = std.testing.allocator;
    const args_list = &[_][]const u8{ "forge", "--json", "search", "keyword", "--workspace", "/tmp" };

    const parsed = try CliArgs.parse(allocator, args_list);
    defer allocator.free(parsed.positional);

    try std.testing.expect(parsed.flags.json == true);
    try std.testing.expectEqualStrings("/tmp", parsed.flags.workspace.?);
    try std.testing.expect(parsed.command == .search);
    try std.testing.expectEqualStrings("keyword", parsed.positional[0]);
}

test "CliArgs parses conversation resume flag" {
    const allocator = std.testing.allocator;
    {
        const args_list = &[_][]const u8{ "forge", "agent", "-c", "sess_demo" };
        const parsed = try CliArgs.parse(allocator, args_list);
        defer allocator.free(parsed.positional);
        defer allocator.free(parsed.flags.files);
        try std.testing.expectEqualStrings("sess_demo", parsed.flags.conversation.?);
    }
    {
        const args_list = &[_][]const u8{ "forge", "agent", "--conversation=sess_demo" };
        const parsed = try CliArgs.parse(allocator, args_list);
        defer allocator.free(parsed.positional);
        defer allocator.free(parsed.flags.files);
        try std.testing.expectEqualStrings("sess_demo", parsed.flags.conversation.?);
    }
}

test "CliArgs parses event stream flag" {
    const allocator = std.testing.allocator;
    const args_list = &[_][]const u8{ "forge", "agent", "run", "task", "--events", "ndjson" };

    const parsed = try CliArgs.parse(allocator, args_list);
    defer allocator.free(parsed.positional);
    defer allocator.free(parsed.flags.files);

    try std.testing.expect(parsed.command == .agent);
    try std.testing.expectEqualStrings("ndjson", parsed.flags.events.?);
}

test "CliArgs parses trust-all as auto approval" {
    const allocator = std.testing.allocator;
    const args_list = &[_][]const u8{ "forge", "agent", "run", "fix it", "--trust-all" };

    const parsed = try CliArgs.parse(allocator, args_list);
    defer allocator.free(parsed.positional);
    defer allocator.free(parsed.flags.files);

    try std.testing.expect(parsed.flags.trust_all);
    try std.testing.expect(parsed.flags.auto_approve);
}

test "CliArgs parses ecosystem command" {
    const allocator = std.testing.allocator;
    const args_list = &[_][]const u8{ "forge", "ecosystem", "inspect" };

    const parsed = try CliArgs.parse(allocator, args_list);
    defer allocator.free(parsed.positional);
    defer allocator.free(parsed.flags.files);

    try std.testing.expect(parsed.command == .ecosystem);
    try std.testing.expectEqualStrings("inspect", parsed.positional[0]);
}

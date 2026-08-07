const std = @import("std");
const ai = @import("forge-ai");
const args_mod = @import("args.zig");

/// `forge cloud <subcommand>` — Forge Cloud backend integration.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    _ = environ_map;
    const sub = if (parsed.positional.len > 0) parsed.positional[0] else "status";

    if (std.mem.eql(u8, sub, "login")) return runLogin(allocator, io, parsed, writer);
    if (std.mem.eql(u8, sub, "logout")) return runLogout(allocator, io, parsed, writer);
    if (std.mem.eql(u8, sub, "status")) return runStatus(allocator, io, parsed, writer);
    if (std.mem.eql(u8, sub, "whoami")) return runStatus(allocator, io, parsed, writer);
    if (std.mem.eql(u8, sub, "models")) return runModels(allocator, io, parsed, writer);
    if (std.mem.eql(u8, sub, "prepare")) return runPrepare(allocator, io, parsed, writer);

    try writer.print("Unknown subcommand '{s}'. Use: login | logout | status | models | prepare | whoami\n", .{sub});
    return 2;
}

fn runLogin(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    const email = if (parsed.positional.len > 1) parsed.positional[1] else {
        try writer.writeAll("usage: forge cloud login <email>\n");
        try writer.writeAll("You will be prompted for your password.\n");
        return 2;
    };

    const config = ai.cloud.resolveConfig(null);
    if (!ai.cloud.isConfigured(config)) {
        try writer.writeAll("error: Forge Cloud is not configured.\n");
        try writer.writeAll("Set FORGE_CLOUD_URL and FORGE_CLOUD_ANON_KEY env vars, or rebuild with\n");
        try writer.writeAll("-Dforge-cloud-url=... -Dforge-cloud-anon-key=...\n");
        return 1;
    }

    try writer.print("Password for {s}: ", .{email});
    try writer.flush();
    const password = readPassword(allocator, io) catch |err| {
        try writer.print("\nerror reading password: {}\n", .{err});
        return 1;
    };
    defer allocator.free(password);
    try writer.writeAll("\n");

    var manager = ai.auth_session.SessionManager.init(allocator, io, .{
        .project_url = config.project_url,
        .anon_key = config.anon_key,
    });
    defer manager.deinit();

    manager.signInWithEmail(email, password) catch |err| {
        try writer.print("error: login failed: {}\n", .{err});
        return 1;
    };

    if (parsed.flags.json) {
        try writer.print(
            "{{\"type\":\"cloud_login\",\"status\":\"ok\",\"email\":\"{s}\",\"uid\":\"{s}\"}}\n",
            .{ manager.email() orelse "", manager.uid() orelse "" },
        );
    } else {
        try writer.print("Logged in as {s} ({s})\n", .{
            manager.email() orelse "?",
            manager.uid() orelse "?",
        });
        try writer.writeAll("Session saved to ~/.forge/auth.json\n");
    }
    return 0;
}

fn runLogout(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    const config = ai.cloud.resolveConfig(null);
    var manager = ai.auth_session.SessionManager.init(allocator, io, .{
        .project_url = config.project_url,
        .anon_key = config.anon_key,
    });
    defer manager.deinit();

    manager.loadStored() catch {};

    if (!manager.isLoggedIn()) {
        if (parsed.flags.json) {
            try writer.writeAll("{\"type\":\"cloud_logout\",\"status\":\"not_logged_in\"}\n");
        } else {
            try writer.writeAll("Not logged in.\n");
        }
        return 0;
    }

    manager.signOut() catch |err| {
        if (parsed.flags.json) {
            try writer.print("{{\"type\":\"cloud_logout\",\"status\":\"local_only\",\"error\":\"{}\"}}\n", .{err});
        } else {
            try writer.print("Warning: server-side logout failed ({}), but local session cleared.\n", .{err});
        }
        return 0;
    };

    if (parsed.flags.json) {
        try writer.writeAll("{\"type\":\"cloud_logout\",\"status\":\"ok\"}\n");
    } else {
        try writer.writeAll("Logged out. Session cleared from ~/.forge/auth.json\n");
    }
    return 0;
}

fn runStatus(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    const config = ai.cloud.resolveConfig(null);
    var manager = ai.auth_session.SessionManager.init(allocator, io, .{
        .project_url = config.project_url,
        .anon_key = config.anon_key,
    });
    defer manager.deinit();

    manager.loadStored() catch {};

    const logged_in = manager.isLoggedIn();
    const email = if (logged_in) manager.email() else null;
    const uid = if (logged_in) manager.uid() else null;

    if (parsed.flags.json) {
        try writer.print(
            "{{\"type\":\"cloud_status\",\"logged_in\":{},\"configured\":{},\"project_url\":\"{s}\"",
            .{ logged_in, ai.cloud.isConfigured(config), config.project_url },
        );
        if (email) |e| try writer.print(",\"email\":\"{s}\"", .{e});
        if (uid) |u| try writer.print(",\"uid\":\"{s}\"", .{u});
        try writer.writeAll("}\n");
    } else {
        try writer.print("Forge Cloud status:\n", .{});
        try writer.print("  Project URL: {s}\n", .{config.project_url});
        try writer.print("  Configured:  {}\n", .{ai.cloud.isConfigured(config)});
        if (logged_in) {
            try writer.print("  Logged in:   yes ({s})\n", .{email orelse "?"});
            try writer.print("  User ID:     {s}\n", .{uid orelse "?"});
        } else {
            try writer.writeAll("  Logged in:   no\n");
            try writer.writeAll("\nRun `forge cloud login <email>` to sign in.\n");
        }
    }
    return 0;
}

fn runModels(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.CliArgs, writer: *std.Io.Writer) !u8 {
    const config = ai.cloud.resolveConfig(null);
    if (!ai.cloud.isConfigured(config)) {
        try writer.writeAll("error: Forge Cloud is not configured.\n");
        try writer.writeAll("Set FORGE_CLOUD_URL and FORGE_CLOUD_ANON_KEY env vars.\n");
        return 1;
    }

    var manager = ai.auth_session.SessionManager.init(allocator, io, .{
        .project_url = config.project_url,
        .anon_key = config.anon_key,
    });
    defer manager.deinit();

    manager.loadStored() catch {};
    if (!manager.isLoggedIn()) {
        try writer.writeAll("error: not logged in. Run `forge cloud login <email>` first.\n");
        return 1;
    }

    const token = manager.getValidAccessToken() catch |err| {
        try writer.print("error: cannot get valid token: {}\n", .{err});
        try writer.writeAll("Try `forge cloud login` again.\n");
        return 1;
    };

    var list = ai.cloud.fetchModels(allocator, io, config, token) catch |err| {
        try writer.print("error: failed to fetch models: {}\n", .{err});
        return 1;
    };
    defer list.deinit();

    if (parsed.flags.json) {
        try writer.writeAll("{\"type\":\"cloud_models\",\"models\":[");
        for (list.models, 0..) |m, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print(
                "{{\"id\":\"{s}\",\"label\":\"{s}\",\"provider\":\"{s}\",\"context_window\":{d},\"max_output_tokens\":{d},\"supports_tools\":{},\"supports_vision\":{},\"supports_thinking\":{},\"input_price_per_1m\":{d:.4},\"output_price_per_1m\":{d:.4}}}",
                .{
                    m.id,
                    m.label,
                    m.provider,
                    m.context_window,
                    m.max_output_tokens,
                    m.supports_tools,
                    m.supports_vision,
                    m.supports_thinking,
                    m.input_price_per_1m,
                    m.output_price_per_1m,
                },
            );
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.print("Cloud models ({d} available):\n\n", .{list.models.len});
        try writer.writeAll("  Provider    Model ID                              Label                                Context   Tools  Vision  Think   Price (I/O)\n");
        try writer.writeAll("  ----------  ------------------------------------  -----------------------------------  --------  -----  ------  ------  ------------\n");
        for (list.models) |m| {
            const tools = if (m.supports_tools) "Y" else "N";
            const vision = if (m.supports_vision) "Y" else "N";
            const think = if (m.supports_thinking) "Y" else "N";
            var price_buf: [64]u8 = undefined;
            const price = if (m.input_price_per_1m == 0 and m.output_price_per_1m == 0)
                "free"
            else
                std.fmt.bufPrint(&price_buf, "${d:.2}/${d:.2}", .{ m.input_price_per_1m, m.output_price_per_1m }) catch "n/a";
            try writer.print("  {s: <10}  {s: <36}  {s: <35}  {d: >7}  {s: <5}  {s: <6}  {s: <5}  {s}\n", .{
                m.provider,
                m.id,
                m.label,
                m.context_window,
                tools,
                vision,
                think,
                price,
            });
        }
    }
    return 0;
}

/// Read a password from stdin with echo disabled (POSIX termios via std.posix).
fn readPassword(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        return readLine(allocator, io);
    }

    const fd = std.posix.STDIN_FILENO;
    const saved = std.posix.tcgetattr(fd) catch return readLine(allocator, io);
    var raw = saved;
    raw.lflag.ECHO = false;
    std.posix.tcsetattr(fd, .FLUSH, raw) catch return readLine(allocator, io);
    defer std.posix.tcsetattr(fd, .FLUSH, saved) catch {};

    return readLine(allocator, io);
}

fn readLine(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_reader.interface;
    const slice = stdin.takeDelimiter('\n') catch return error.ReadError;
    const line = slice orelse return error.UnexpectedEof;
    return allocator.dupe(u8, line);
}

/// `forge cloud prepare <intent>` — call the agent-prepare endpoint to get
/// a multi-step plan + tool suggestions before the main LLM call.
///
/// Usage:
///   forge cloud prepare "rename getUser to fetchUser" --file src/userService.ts
///   forge cloud prepare "fix the compile error" --json
fn runPrepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    const config = ai.cloud.resolveConfig(null);
    if (!ai.cloud.isConfigured(config)) {
        try writer.writeAll("error: Forge Cloud is not configured.\n");
        try writer.writeAll("Set FORGE_CLOUD_URL and FORGE_CLOUD_ANON_KEY env vars.\n");
        return 1;
    }

    const intent = if (parsed.positional.len > 1) parsed.positional[1] else {
        try writer.writeAll("usage: forge cloud prepare <intent> [--file <path>] [--json]\n");
        try writer.writeAll("\nExample:\n");
        try writer.writeAll("  forge cloud prepare \"rename getUser to fetchUser\" --file src/userService.ts\n");
        try writer.writeAll("  forge cloud prepare \"fix the compile error\" --json\n");
        return 2;
    };

    var manager = ai.auth_session.SessionManager.init(allocator, io, .{
        .project_url = config.project_url,
        .anon_key = config.anon_key,
    });
    defer manager.deinit();

    manager.loadStored() catch {};
    // Auth is optional for prepare — unauthenticated gets heuristic-only.
    // But if logged in, we send the JWT so the backend can use the LLM.
    var token: []const u8 = "";
    if (manager.isLoggedIn()) {
        token = manager.getValidAccessToken() catch "";
    }

    // Build the prepare request. --file flag sets active_file; additional
    // positional args after intent are treated as workspace_files.
    const active_file = if (parsed.flags.files.len > 0) parsed.flags.files[0] else null;
    const workspace_files: []const []const u8 = if (parsed.flags.files.len > 1)
        parsed.flags.files[1..]
    else
        &.{};

    const request = ai.cloud.PrepareRequest{
        .intent = intent,
        .active_file = active_file,
        .workspace_files = workspace_files,
        .client_intent_guess = null,
    };

    var resp = ai.cloud.callPrepare(allocator, io, config, token, request) catch |err| {
        try writer.print("error: prepare call failed: {}\n", .{err});
        try writer.writeAll("Falling back to native heuristic routing.\n");
        return 1;
    };
    defer resp.deinit();

    if (parsed.flags.json) {
        try writer.print(
            "{{\"type\":\"cloud_prepare\",\"intent\":\"{s}\",\"confidence\":{d:.2},\"used_llm\":{},\"latency_ms\":{d},\"plan\":[",
            .{ resp.intent, resp.confidence, resp.used_llm, resp.latency_ms },
        );
        for (resp.plan, 0..) |step, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print(
                "{{\"step\":{d},\"goal\":\"{s}\",\"suggested_tools\":[",
                .{ step.step, step.goal },
            );
            for (step.suggested_tools, 0..) |t, j| {
                if (j > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{t});
            }
            try writer.writeAll("],\"context_needed\":[");
            for (step.context_needed, 0..) |c, j| {
                if (j > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{c});
            }
            try writer.writeAll("]}");
        }
        try writer.writeAll("],\"suggested_tools\":[");
        for (resp.suggested_tools, 0..) |t, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{t});
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.print("Agent Prepare\n", .{});
        try writer.print("  Intent:     {s} (confidence: {d:.2})\n", .{ resp.intent, resp.confidence });
        try writer.print("  Used LLM:   {}\n", .{resp.used_llm});
        try writer.print("  Latency:    {d}ms\n", .{resp.latency_ms});
        try writer.print("  Tools:      {s}\n", .{joinComma(resp.suggested_tools)});

        if (resp.plan.len > 0) {
            try writer.print("\nPlan ({d} steps):\n", .{resp.plan.len});
            for (resp.plan) |step| {
                try writer.print("  {d}. {s}\n", .{ step.step, step.goal });
                if (step.suggested_tools.len > 0) {
                    try writer.print("     tools: {s}\n", .{joinComma(step.suggested_tools)});
                }
                if (step.context_needed.len > 0) {
                    try writer.print("     context: {s}\n", .{joinComma(step.context_needed)});
                }
            }
        } else {
            try writer.writeAll("\nNo multi-step plan (single-step task).\n");
        }

        if (!resp.used_llm) {
            try writer.writeAll("\n(Heuristic-only — backend LLM not configured or auth missing.\n");
            try writer.writeAll(" Set FORGE_PREPARE_LLM_PROVIDER + FORGE_PREPARE_LLM_MODEL on the backend\n");
            try writer.writeAll(" and `forge cloud login` to enable LLM-backed planning.)\n");
        }
    }
    return 0;
}

fn joinComma(items: [][]u8) []const u8 {
    if (items.len == 0) return "(none)";
    // Best-effort: return first item + count. Full join needs allocator.
    // For display purposes, showing the first + N is sufficient.
    if (items.len == 1) return items[0];
    // Can't easily format without allocator — return a static hint.
    return "(multiple)";
}

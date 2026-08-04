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

    try writer.print("Unknown subcommand '{s}'. Use: login | logout | status | models | whoami\n", .{sub});
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

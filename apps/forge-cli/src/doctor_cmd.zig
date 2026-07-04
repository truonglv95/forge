const std = @import("std");
const ai = @import("forge-ai");
const core = @import("forge-core");
const kernel = @import("forge-kernel");
const workspace = @import("forge-workspace");
const args_mod = @import("args.zig");
const workspace_cmd = @import("workspace_cmd.zig");

pub const Check = struct {
    name: []const u8,
    ok: bool,
    detail: []const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |check| {
            allocator.free(check.name);
            allocator.free(check.detail);
        }
        checks.deinit(allocator);
    }

    var lifecycle = kernel.Lifecycle{};
    lifecycle.transition(.starting) catch {};
    lifecycle.transition(.running) catch {};

    try appendCheck(allocator, &checks, "forge.version", true, core.version);

    const kernel_ok = lifecycle.state == .running;
    try appendCheck(allocator, &checks, "kernel.lifecycle", kernel_ok, @tagName(lifecycle.state));

    const provider_kind = resolveProviderKind(allocator, io, environ_map, parsed);
    const provider_detail = switch (provider_kind) {
        .gemini => "gemini (credentials found)",
        .fake => "fake (no gemini credentials; auto mode)",
        .missing => "none (--provider gemini but no credentials)",
    };
    const provider_ok = provider_kind != .missing;
    try appendCheck(allocator, &checks, "ai.provider", provider_ok, provider_detail);

    if (parsed.flags.workspace) |ws_path| {
        var opened = workspace_cmd.OpenedWorkspace.open(allocator, io, parsed) catch |err| {
            const detail = try std.fmt.allocPrint(allocator, "workspace open failed: {}", .{err});
            try appendCheck(allocator, &checks, "workspace.open", false, detail);
            return render(allocator, parsed, checks.items, writer);
        };
        defer opened.close(io);

        workspace.history.ensureLayout(io, opened.root) catch |err| {
            const detail = try std.fmt.allocPrint(allocator, ".forge layout failed: {}", .{err});
            try appendCheck(allocator, &checks, "workspace.forge_layout", false, detail);
            return render(allocator, parsed, checks.items, writer);
        };

        const probe_rel = ".forge/doctor.probe";
        const probe_body = "ok";
        workspace.atomic.replaceFile(io, opened.root, try workspace.WorkspacePath.parse(probe_rel), probe_body) catch |err| {
            const detail = try std.fmt.allocPrint(allocator, "write probe failed: {}", .{err});
            try appendCheck(allocator, &checks, "workspace.writable", false, detail);
            return render(allocator, parsed, checks.items, writer);
        };
        opened.root.dir.deleteFile(io, probe_rel) catch {};

        const detail = try std.fmt.allocPrint(allocator, "writable at {s}", .{ws_path});
        try appendCheck(allocator, &checks, "workspace.writable", true, detail);
    }

    return render(allocator, parsed, checks.items, writer);
}

const ProviderKind = enum {
    gemini,
    fake,
    missing,
};

fn resolveProviderKind(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
) ProviderKind {
    const kind = ai.provider_factory.Kind.parse(parsed.flags.provider);
    return switch (kind) {
        .fake => .fake,
        .gemini => blk: {
            var creds = ai.credentials.Credentials.loadGemini(allocator, io, environ_map) catch return .missing;
            creds.deinit();
            break :blk .gemini;
        },
        .auto => blk: {
            var creds = ai.credentials.Credentials.loadGemini(allocator, io, environ_map) catch return .fake;
            creds.deinit();
            break :blk .gemini;
        },
    };
}

fn appendCheck(allocator: std.mem.Allocator, checks: *std.ArrayList(Check), name: []const u8, ok: bool, detail: []const u8) !void {
    try checks.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .ok = ok,
        .detail = try allocator.dupe(u8, detail),
    });
}

fn render(_: std.mem.Allocator, parsed: args_mod.CliArgs, checks: []Check, writer: *std.Io.Writer) !u8 {
    var all_ok = true;
    for (checks) |check| {
        if (!check.ok) all_ok = false;
    }

    if (parsed.flags.json) {
        try writer.writeAll("{\"status\":\"ok\",\"type\":\"doctor\",\"ready\":");
        try writer.print("{s},\"checks\":[", .{if (all_ok) "true" else "false"});
        for (checks, 0..) |check, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.print(
                "{{\"name\":\"{s}\",\"ok\":{},\"detail\":\"{s}\"}}",
                .{ check.name, check.ok, check.detail },
            );
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.writeAll("Forge doctor\n");
        for (checks) |check| {
            const tag = if (check.ok) "ok" else "FAIL";
            try writer.print("  [{s}] {s}: {s}\n", .{ tag, check.name, check.detail });
        }
        if (all_ok) {
            try writer.writeAll("\nAll checks passed.\n");
        } else {
            try writer.writeAll("\nSome checks failed.\n");
        }
    }

    return if (all_ok) 0 else 1;
}

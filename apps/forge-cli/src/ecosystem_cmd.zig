const std = @import("std");
const workspace = @import("forge-workspace");
const ai = @import("forge-ai");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: *const @import("args.zig").CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    const workspace_path = parsed.flags.workspace orelse ".";
    var root = try workspace.WorkspaceRoot.open(io, workspace_path);
    defer root.close(io);

    const sub = if (parsed.positional.len > 0) parsed.positional[0] else "inspect";
    if (std.mem.eql(u8, sub, "inspect")) return try inspect(allocator, io, root, writer);
    if (std.mem.eql(u8, sub, "list")) return try list(allocator, io, root, writer);
    if (std.mem.eql(u8, sub, "init")) return try initManifest(allocator, io, root, parsed.flags.dry_run, writer);

    try writer.writeAll("usage: forge ecosystem <inspect|list|init> [--dry-run]\n");
    return 2;
}

fn inspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    writer: *std.Io.Writer,
) !u8 {
    var parsed = try loadOrExplain(allocator, io, root, writer);
    defer parsed.deinit();
    try ai.ecosystem.formatSummary(writer, &parsed.value);
    return 0;
}

fn list(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    writer: *std.Io.Writer,
) !u8 {
    var parsed = try loadOrExplain(allocator, io, root, writer);
    defer parsed.deinit();
    const manifest = &parsed.value;

    try writer.print("tools ({d})\n", .{manifest.tools.len});
    for (manifest.tools) |tool| try writer.print("  {s}\t{s}\n", .{ tool.id, tool.title });

    try writer.print("context sources ({d})\n", .{manifest.context_sources.len});
    for (manifest.context_sources) |source| try writer.print("  {s}\t{s}\t{s}\n", .{ source.id, source.kind, source.title });

    try writer.print("skill packs ({d})\n", .{manifest.skill_packs.len});
    for (manifest.skill_packs) |pack| {
        try writer.print("  {s}\t{s}\n", .{ pack.id, pack.title });
        for (pack.workflows) |flow| try writer.print("    workflow {s}\t{s}\n", .{ flow.id, flow.title });
    }

    try writer.print("eval packs ({d})\n", .{manifest.eval_packs.len});
    for (manifest.eval_packs) |eval| try writer.print("  {s}\t{s}\t{s}\n", .{ eval.id, eval.title, eval.corpus });

    try writer.print("provider hints ({d})\n", .{manifest.provider_hints.len});
    for (manifest.provider_hints) |hint| try writer.print("  {s}\t{s}/{s}\t{s}\n", .{ hint.id, hint.provider, hint.model, hint.role });
    return 0;
}

fn initManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    dry_run: bool,
    writer: *std.Io.Writer,
) !u8 {
    var template = std.Io.Writer.Allocating.init(allocator);
    defer template.deinit();
    try ai.ecosystem.writeTemplate(&template.writer);
    if (dry_run) {
        try writer.writeAll(template.writer.buffered());
        return 0;
    }
    try workspace.atomic.createDirPath(io, root, ".forge/ai");
    const wp = try workspace.WorkspacePath.parse(ai.ecosystem.default_workspace_manifest);
    try workspace.atomic.replaceFile(io, root, wp, template.writer.buffered());
    try writer.print("created {s}\n", .{ai.ecosystem.default_workspace_manifest});
    return 0;
}

fn loadOrExplain(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    writer: *std.Io.Writer,
) !ai.ecosystem.ParsedManifest {
    if (try ai.ecosystem.loadLocal(allocator, io, root)) |manifest| return manifest;
    try writer.print(
        "AI ecosystem manifest not found. Run `forge ecosystem init` to create {s}.\n",
        .{ai.ecosystem.default_workspace_manifest},
    );
    return error.ManifestMissing;
}

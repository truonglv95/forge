const std = @import("std");
const workspace = @import("forge-workspace");
const executor_types = @import("executor_types.zig");
const args_mod = @import("args.zig");

const AgentToolError = executor_types.AgentToolError;
const Context = executor_types.Context;
const Outcome = executor_types.Outcome;
const checkCancel = executor_types.checkCancel;
const requireTool = executor_types.requireTool;

pub fn replaceFileContent(ctx: Context, args: args_mod.ReplaceFileContentArgs) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .propose_edit);

    const wp = workspace.WorkspacePath.parse(args.path) catch return error.WorkspaceFailed;
    var snap = workspace.FileSnapshot.read(ctx.allocator, ctx.io, ctx.root, wp) catch return error.WorkspaceFailed;
    defer snap.deinit();

    var text_edits: std.ArrayList(workspace.edit.TextEdit) = .empty;
    defer text_edits.deinit(ctx.allocator);
    for (args.edits) |e| {
        text_edits.append(ctx.allocator, .{
            .start = 0,
            .end = 0,
            .search = e.search,
            .replacement = e.replace,
        }) catch return error.WorkspaceFailed;
    }

    const file_edit = workspace.edit.FileEdit{
        .path = args.path,
        .operation = .modify,
        .expected_hash = workspace.edit.contentHash(snap.content),
        .edits = text_edits.items,
    };

    const ws_edit = workspace.edit.WorkspaceEdit{
        .files = &.{file_edit},
    };

    var applied_tx: ?u64 = null;
    if (ctx.direct_apply_edits) {
        const proposal_json = formatInlineProposalJson(ctx.allocator, ws_edit) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(proposal_json);
        applied_tx = workspace.execution.applyApprovedContent(ctx.allocator, ctx.io, ctx.root, ws_edit, "agent-inline", proposal_json) catch return error.WorkspaceFailed;
    } else if (ctx.edit_callback) |cb| {
        cb(ctx.edit_context, ws_edit);
    }

    const summary = blk: {
        const first = if (args.edits.len > 0) summarizeEditPreview(args.edits[0].replace) else "";
        if (applied_tx) |tx_id| {
            break :blk std.fmt.allocPrint(
                ctx.allocator,
                "Applied edit `{s}` tx={d} blocks={d}: {s}",
                .{ args.path, tx_id, args.edits.len, first },
            ) catch return error.WorkspaceFailed;
        }
        if (first.len > 0) {
            break :blk std.fmt.allocPrint(
                ctx.allocator,
                "Write `{s}` hash={x} blocks={d}: {s}",
                .{ args.path, snap.hash, args.edits.len, first },
            ) catch return error.WorkspaceFailed;
        }
        break :blk std.fmt.allocPrint(ctx.allocator, "Write `{s}` hash={x} blocks={d}", .{ args.path, snap.hash, args.edits.len }) catch return error.WorkspaceFailed;
    };
    return .{ .summary = summary };
}

pub fn multiEdit(ctx: Context, args: args_mod.MultiEditArgs) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .multi_edit);

    if (args.files.len == 0) return error.WorkspaceFailed;

    var file_edits: std.ArrayList(workspace.edit.FileEdit) = .empty;
    defer file_edits.deinit(ctx.allocator);
    var owned_text_edits: std.ArrayList([]workspace.edit.TextEdit) = .empty;
    defer {
        for (owned_text_edits.items) |slice| ctx.allocator.free(slice);
        owned_text_edits.deinit(ctx.allocator);
    }

    for (args.files) |fe| {
        const wp = workspace.WorkspacePath.parse(fe.path) catch return error.WorkspaceFailed;
        var snap = workspace.FileSnapshot.read(ctx.allocator, ctx.io, ctx.root, wp) catch return error.WorkspaceFailed;
        defer snap.deinit();
        const expected_hash = workspace.edit.contentHash(snap.content);

        const text_edits = ctx.allocator.alloc(workspace.edit.TextEdit, fe.edits.len) catch return error.WorkspaceFailed;
        for (fe.edits, 0..) |e, i| {
            text_edits[i] = .{ .start = 0, .end = 0, .search = e.search, .replacement = e.replace };
        }
        owned_text_edits.append(ctx.allocator, text_edits) catch return error.WorkspaceFailed;
        file_edits.append(ctx.allocator, .{
            .path = fe.path,
            .operation = .modify,
            .expected_hash = expected_hash,
            .edits = text_edits,
        }) catch return error.WorkspaceFailed;
    }

    var applied_tx: ?u64 = null;
    if (ctx.direct_apply_edits) {
        const ws_edit = workspace.edit.WorkspaceEdit{ .files = file_edits.items };
        const proposal_json = formatInlineProposalJson(ctx.allocator, ws_edit) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(proposal_json);
        applied_tx = workspace.execution.applyApprovedContent(ctx.allocator, ctx.io, ctx.root, ws_edit, "agent-inline", proposal_json) catch return error.WorkspaceFailed;
    } else if (ctx.edit_callback) |cb| {
        cb(ctx.edit_context, .{ .files = file_edits.items });
    }

    var total_edits: usize = 0;
    for (args.files) |fe| total_edits += fe.edits.len;
    const summary = if (applied_tx) |tx_id|
        std.fmt.allocPrint(ctx.allocator, "Applied multi-edit tx={d}: {d} file(s), {d} block(s) total: {s}", .{ tx_id, args.files.len, total_edits, args.files[0].path }) catch return error.WorkspaceFailed
    else
        std.fmt.allocPrint(ctx.allocator, "Multi-edit {d} file(s), {d} block(s) total: {s}", .{ args.files.len, total_edits, args.files[0].path }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

pub fn diffPreview(ctx: Context, path: []const u8, search_block: []const u8, replace_block: []const u8) AgentToolError!Outcome {
    try checkCancel(ctx);
    try requireTool(ctx, .diff_preview);

    const diff_text = @import("../diff_tool.zig").previewSearchReplace(ctx.allocator, ctx.io, ctx.root, path, search_block, replace_block) catch {
        const summary = std.fmt.allocPrint(ctx.allocator, "diff_preview: search block not found in {s}", .{path}) catch return error.WorkspaceFailed;
        return .{ .summary = summary };
    };
    defer ctx.allocator.free(diff_text);

    const summary = std.fmt.allocPrint(ctx.allocator, "Diff preview for {s}:\n{s}", .{ path, diff_text }) catch return error.WorkspaceFailed;
    return .{ .summary = summary };
}

fn formatInlineProposalJson(allocator: std.mem.Allocator, ws_edit: workspace.edit.WorkspaceEdit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema_version\":1,\"summary\":\"agent inline edit\",\"files\":[");
    for (ws_edit.files, 0..) |file, file_index| {
        if (file_index > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"path\":");
        try appendJsonString(allocator, &out, file.path);
        try out.appendSlice(allocator, ",\"operation\":");
        try appendJsonString(allocator, &out, @tagName(file.operation));
        if (file.expected_hash) |hash| {
            const hash_text = try std.fmt.allocPrint(allocator, ",\"expected_hash\":{d}", .{hash});
            defer allocator.free(hash_text);
            try out.appendSlice(allocator, hash_text);
        } else {
            try out.appendSlice(allocator, ",\"expected_hash\":null");
        }
        try out.appendSlice(allocator, ",\"edits\":[");
        for (file.edits, 0..) |edit, edit_index| {
            if (edit_index > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, "{\"start\":");
            const range_text = try std.fmt.allocPrint(allocator, "{d},\"end\":{d},", .{ edit.start, edit.end });
            defer allocator.free(range_text);
            try out.appendSlice(allocator, range_text);
            if (edit.search) |search_text| {
                try out.appendSlice(allocator, "\"search\":");
                try appendJsonString(allocator, &out, search_text);
                try out.append(allocator, ',');
            }
            try out.appendSlice(allocator, "\"replacement\":");
            try appendJsonString(allocator, &out, edit.replacement);
            try out.append(allocator, '}');
        }
        try out.appendSlice(allocator, "]}");
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn summarizeEditPreview(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return "";
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != '\n' and trimmed[end] != '\r') : (end += 1) {}
    return trimmed[0..@min(end, 96)];
}

pub fn unsafeEditShrinkReason(
    ctx: Context,
    path: []const u8,
    start_line: usize,
    end_line: usize,
    replacement: []const u8,
) AgentToolError!?[]u8 {
    const wp = workspace.WorkspacePath.parse(path) catch return null;
    var snap = workspace.FileSnapshot.read(ctx.allocator, ctx.io, ctx.root, wp) catch return null;
    defer snap.deinit();

    const old_lines = countLines(snap.content);
    if (old_lines == 0) return null;
    const replacement_lines = countLines(replacement);
    const removed_lines = if (start_line == 0 and end_line == 0)
        old_lines
    else if (end_line >= start_line)
        end_line - start_line + 1
    else
        0;

    if (removed_lines < 20) return null;
    if (replacement_lines * 2 + 10 >= removed_lines) return null;

    return std.fmt.allocPrint(
        ctx.allocator,
        "Edit rejected for safety: requested replacement of {d} line(s) in `{s}` with only {d} line(s). Read the exact target range and retry with a narrower line range.",
        .{ removed_lines, path, replacement_lines },
    ) catch return error.WorkspaceFailed;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n' and count > 0) count -= 1;
    return count;
}

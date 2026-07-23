const std = @import("std");
const executor_types = @import("executor_types.zig");

const AgentToolError = executor_types.AgentToolError;
const Context = executor_types.Context;
const Outcome = executor_types.Outcome;
const checkCancel = executor_types.checkCancel;
const requireTool = executor_types.requireTool;

pub fn definition(ctx: Context, path: []const u8, line: u32, character: u32) AgentToolError!Outcome {
    try requireTool(ctx, .lsp_definition);
    try checkCancel(ctx);

    if (ctx.lsp_request_callback) |callback| {
        const params_json = std.fmt.allocPrint(ctx.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}", .{ path, line, character }) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(params_json);

        if (callback(ctx.lsp_context, ctx.allocator, "textDocument/definition", params_json)) |res| {
            return .{ .summary = res };
        }
    }
    return .{ .summary = ctx.allocator.dupe(u8, "Language server definition not available") catch return error.WorkspaceFailed };
}

pub fn hover(ctx: Context, path: []const u8, line: u32, character: u32) AgentToolError!Outcome {
    try requireTool(ctx, .lsp_hover);
    try checkCancel(ctx);

    if (ctx.lsp_request_callback) |callback| {
        const params_json = std.fmt.allocPrint(ctx.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}", .{ path, line, character }) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(params_json);

        if (callback(ctx.lsp_context, ctx.allocator, "textDocument/hover", params_json)) |res| {
            return .{ .summary = res };
        }
    }
    return .{ .summary = ctx.allocator.dupe(u8, "Language server hover not available") catch return error.WorkspaceFailed };
}

pub fn documentSymbols(ctx: Context, path: []const u8) AgentToolError!Outcome {
    try requireTool(ctx, .lsp_document_symbols);
    try checkCancel(ctx);

    if (ctx.lsp_request_callback) |callback| {
        const params_json = std.fmt.allocPrint(ctx.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{path}) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(params_json);

        if (callback(ctx.lsp_context, ctx.allocator, "textDocument/documentSymbol", params_json)) |res| {
            return .{ .summary = res };
        }
    }
    return .{ .summary = ctx.allocator.dupe(u8, "Language server document symbols not available") catch return error.WorkspaceFailed };
}

pub fn diagnostics(ctx: Context, path: []const u8) AgentToolError!Outcome {
    try requireTool(ctx, .lsp_diagnostics);
    try checkCancel(ctx);

    if (ctx.lsp_request_callback) |callback| {
        const params_json = std.fmt.allocPrint(ctx.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{path}) catch return error.WorkspaceFailed;
        defer ctx.allocator.free(params_json);

        if (callback(ctx.lsp_context, ctx.allocator, "textDocument/diagnostic", params_json)) |res| {
            return .{ .summary = res };
        }
    }
    return .{ .summary = ctx.allocator.dupe(u8, "Language server diagnostics not available (or uses push diagnostics)") catch return error.WorkspaceFailed };
}

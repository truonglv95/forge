const std = @import("std");
const tool_executor = @import("../tool_executor.zig");
const mcp_registry = @import("../mcp_registry.zig");
const args = @import("args.zig");

pub const DispatchError = tool_executor.AgentToolError || error{
    UnknownTool,
    ParseFailed,
};

pub fn execute(
    allocator: std.mem.Allocator,
    tool_ctx: tool_executor.Context,
    mcp: ?*mcp_registry.Registry,
    call: args.ToolCall,
) DispatchError![]u8 {
    std.debug.print("DEBUG TOOL ARGS [{s}]: {s}\n", .{ call.name, call.args_json });
    if (mcp) |reg| {
        if (reg.hasTool(call.name)) {
            return reg.callTool(call.name, call.args_json) catch return error.WorkspaceFailed;
        }
    }
    if (std.mem.eql(u8, call.name, "search")) {
        const search_args = args.parseSearchArgs(allocator, call.args_json) catch return error.ParseFailed;
        defer args.freeSearchArgs(allocator, search_args);
        const out = tool_executor.search(tool_ctx, search_args) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        defer allocator.free(out.observation);
        defer if (out.first_match_path) |path| allocator.free(path);
        return allocator.dupe(u8, out.observation) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "codebase_search")) {
        const query = args.parseCodebaseQuery(allocator, call.args_json) catch return error.ParseFailed;
        defer allocator.free(query);
        const out = tool_executor.codebaseSearch(tool_ctx, query) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        defer if (out.formatted) |formatted| allocator.free(formatted);
        if (out.formatted) |formatted| {
            return allocator.dupe(u8, formatted) catch return error.WorkspaceFailed;
        }
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "lsp_workspace_symbol")) {
        const symbol_args = args.parseLspWorkspaceSymbolArgs(allocator, call.args_json) catch return error.ParseFailed;
        defer allocator.free(symbol_args.query);
        const out = tool_executor.lspWorkspaceSymbol(tool_ctx, symbol_args.query) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "lsp_find_references")) {
        const ref_args = args.parseLspFindReferencesArgs(allocator, call.args_json) catch return error.ParseFailed;
        defer allocator.free(ref_args.path);
        const out = tool_executor.lspFindReferences(tool_ctx, ref_args.path, ref_args.line, ref_args.character) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "list_tree")) {
        const tree_args = args.parseListTreeArgs(allocator, call.args_json) catch return error.ParseFailed;
        defer allocator.free(tree_args.path);
        const out = tool_executor.listTree(tool_ctx, tree_args.path, tree_args.depth) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "find_files")) {
        const ff_args = args.parseFindFilesArgs(allocator, call.args_json) catch return error.ParseFailed;
        defer args.freeFindFilesArgs(allocator, ff_args);
        const out = tool_executor.findFiles(tool_ctx, ff_args.pattern, ff_args.path, ff_args.head_limit) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "read_file")) {
        const read_args = args.parseReadFileArgs(allocator, call.args_json) catch return error.ParseFailed;
        defer allocator.free(read_args.path);
        const out = tool_executor.readFile(tool_ctx, read_args.path, read_args.start_line, read_args.end_line) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "remember")) {
        const remember_args = args.parseRememberArgs(allocator, call.args_json) catch return error.ParseFailed;
        defer args.freeRememberArgs(allocator, remember_args);
        const out = tool_executor.remember(tool_ctx, remember_args.content, remember_args.kind, remember_args.tags) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "fetch_url")) {
        const url = args.parseFetchUrl(allocator, call.args_json) catch return error.ParseFailed;
        defer allocator.free(url);
        const out = tool_executor.fetchUrl(tool_ctx, url) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        defer if (out.content) |content| allocator.free(content);
        if (out.content) |content| {
            return allocator.dupe(u8, content) catch return error.WorkspaceFailed;
        }
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "run_command")) {
        const command = args.parseRunCommand(allocator, call.args_json) catch return error.ParseFailed;
        defer allocator.free(command);
        const out = tool_executor.runCommand(tool_ctx, command) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    if (std.mem.eql(u8, call.name, "replace_file_content")) {
        const edit_args = args.parseReplaceFileContentArgs(allocator, call.args_json) catch return error.ParseFailed;
        defer {
            allocator.free(edit_args.path);
            for (edit_args.edits) |edit| {
                allocator.free(edit.search);
                allocator.free(edit.replace);
            }
            allocator.free(edit_args.edits);
        }
        const out = tool_executor.replaceFileContent(tool_ctx, edit_args) catch |err| return mapTool(err);
        defer allocator.free(out.summary);
        return allocator.dupe(u8, out.summary) catch return error.WorkspaceFailed;
    }
    return error.UnknownTool;
}

fn mapTool(err: tool_executor.AgentToolError) DispatchError {
    return err;
}

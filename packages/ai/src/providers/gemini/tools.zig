//! Backward-compatible re-exports. New code should use `tools/registry`, `tools/args`, and `tools/dispatch`.

const registry = @import("../../tools/registry.zig");
const args = @import("../../tools/args.zig");

pub const function_declarations_json = registry.native_declarations_json;

pub const FunctionCall = args.ToolCall;
pub const ReplaceFileContentArgs = args.ReplaceFileContentArgs;
pub const RememberArgs = args.RememberArgs;

pub const isToolAllowed = registry.isToolAllowed;
pub const allowedNativeTool = registry.allowedNativeTool;

pub const parseSearchTerm = args.parseSearchTerm;
pub const parseCodebaseQuery = args.parseCodebaseQuery;
pub const parseReadPath = args.parseReadPath;
pub const parseFetchUrl = args.parseFetchUrl;
pub const parseRunCommand = args.parseRunCommand;
pub const parseReplaceFileContentArgs = args.parseReplaceFileContentArgs;
pub const parseRememberArgs = args.parseRememberArgs;
pub const freeRememberArgs = args.freeRememberArgs;

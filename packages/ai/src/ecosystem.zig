const std = @import("std");
const workspace = @import("forge-workspace");

pub const default_workspace_manifest = ".forge/ai/ecosystem.json";
pub const default_project_manifest = "forge.ai.json";

pub const PermissionRisk = enum { low, medium, high };
pub const PermissionMode = enum { automatic, review, every_time };

pub const PermissionGrant = struct {
    id: []const u8,
    description: []const u8 = "",
    risk: []const u8 = "low",
    approval: []const u8 = "automatic",
};

pub const ToolContract = struct {
    id: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    transport: []const u8 = "native",
    entry: []const u8 = "",
    input_schema: ?std.json.Value = null,
    output_schema: ?std.json.Value = null,
    permissions: []const []const u8 = &.{},
};

pub const ContextSourceContract = struct {
    id: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    kind: []const u8 = "local",
    entry: []const u8 = "",
    refresh: []const u8 = "manual",
    max_bytes: usize = 128 * 1024,
    permissions: []const []const u8 = &.{},
};

pub const AgentWorkflowContract = struct {
    id: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    mode: []const u8 = "agent",
    tools: []const []const u8 = &.{},
    context_sources: []const []const u8 = &.{},
    prompt: []const u8 = "",
    eval_pack: ?[]const u8 = null,
};

pub const SkillPackContract = struct {
    id: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    languages: []const []const u8 = &.{},
    frameworks: []const []const u8 = &.{},
    workflows: []const AgentWorkflowContract = &.{},
};

pub const EvalPackContract = struct {
    id: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    corpus: []const u8 = "",
    min_success_rate: f64 = 0.0,
};

pub const ProviderHint = struct {
    id: []const u8,
    provider: []const u8,
    model: []const u8 = "",
    role: []const u8 = "default",
    context_window: usize = 0,
};

pub const MarketplaceContract = struct {
    enabled: bool = true,
    source: []const u8 = "local",
};

pub const Manifest = struct {
    schema_version: u32 = 1,
    package_id: []const u8,
    name: []const u8,
    version: []const u8 = "0.0.0",
    description: []const u8 = "",
    permissions: []const PermissionGrant = &.{},
    tools: []const ToolContract = &.{},
    context_sources: []const ContextSourceContract = &.{},
    skill_packs: []const SkillPackContract = &.{},
    eval_packs: []const EvalPackContract = &.{},
    provider_hints: []const ProviderHint = &.{},
    marketplace: MarketplaceContract = .{},
};

pub const ParsedManifest = std.json.Parsed(Manifest);

pub const ValidationError = error{
    UnsupportedSchema,
    MissingId,
    DuplicateId,
    UnknownPermission,
    UnknownTool,
    UnknownContextSource,
    UnknownEvalPack,
    InvalidPolicy,
    InvalidJson,
    OutOfMemory,
};

pub const Summary = struct {
    tools: usize = 0,
    context_sources: usize = 0,
    skill_packs: usize = 0,
    workflows: usize = 0,
    eval_packs: usize = 0,
    provider_hints: usize = 0,
    permissions: usize = 0,
};

pub fn parseManifest(allocator: std.mem.Allocator, source: []const u8) ValidationError!ParsedManifest {
    var parsed = std.json.parseFromSlice(Manifest, allocator, source, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    errdefer parsed.deinit();
    try validate(&parsed.value);
    return parsed;
}

pub fn loadLocal(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
) !?ParsedManifest {
    const paths = [_][]const u8{
        default_workspace_manifest,
        default_project_manifest,
        "extensions/ai/ecosystem.json",
    };
    for (paths) |rel| {
        const wp = workspace.WorkspacePath.parse(rel) catch continue;
        var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch continue;
        defer snap.deinit();
        return try parseManifest(allocator, snap.content);
    }
    return null;
}

pub fn validate(manifest: *const Manifest) ValidationError!void {
    if (manifest.schema_version != 1) return error.UnsupportedSchema;
    if (manifest.package_id.len == 0 or manifest.name.len == 0) return error.MissingId;

    var seen: IdSet = undefined;
    try seen.initFromManifest(manifest);

    for (manifest.permissions) |perm| {
        if (perm.id.len == 0) return error.MissingId;
        _ = parseRisk(perm.risk) orelse return error.InvalidPolicy;
        _ = parseApproval(perm.approval) orelse return error.InvalidPolicy;
    }

    for (manifest.tools) |tool| {
        if (tool.id.len == 0) return error.MissingId;
        for (tool.permissions) |perm_id| if (!seen.hasPermission(perm_id)) return error.UnknownPermission;
    }

    for (manifest.context_sources) |source| {
        if (source.id.len == 0) return error.MissingId;
        for (source.permissions) |perm_id| if (!seen.hasPermission(perm_id)) return error.UnknownPermission;
    }

    for (manifest.skill_packs) |pack| {
        if (pack.id.len == 0) return error.MissingId;
        for (pack.workflows) |flow| try validateWorkflow(flow, &seen);
    }
}

fn validateWorkflow(flow: AgentWorkflowContract, seen: *const IdSet) ValidationError!void {
    if (flow.id.len == 0) return error.MissingId;
    for (flow.tools) |tool_id| if (!seen.hasTool(tool_id)) return error.UnknownTool;
    for (flow.context_sources) |source_id| if (!seen.hasContextSource(source_id)) return error.UnknownContextSource;
    if (flow.eval_pack) |eval_id| {
        if (!seen.hasEvalPack(eval_id)) return error.UnknownEvalPack;
    }
}

pub fn summarize(manifest: *const Manifest) Summary {
    var workflows: usize = 0;
    for (manifest.skill_packs) |pack| workflows += pack.workflows.len;
    return .{
        .tools = manifest.tools.len,
        .context_sources = manifest.context_sources.len,
        .skill_packs = manifest.skill_packs.len,
        .workflows = workflows,
        .eval_packs = manifest.eval_packs.len,
        .provider_hints = manifest.provider_hints.len,
        .permissions = manifest.permissions.len,
    };
}

pub fn formatSummary(writer: *std.Io.Writer, manifest: *const Manifest) !void {
    const summary = summarize(manifest);
    try writer.print(
        \\AI ecosystem: {s} ({s})
        \\tools={d} context_sources={d} skill_packs={d} workflows={d} eval_packs={d} providers={d} permissions={d}
        \\
    , .{
        manifest.name,
        manifest.package_id,
        summary.tools,
        summary.context_sources,
        summary.skill_packs,
        summary.workflows,
        summary.eval_packs,
        summary.provider_hints,
        summary.permissions,
    });
}

pub fn writeTemplate(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\{
        \\  "schema_version": 1,
        \\  "package_id": "local.forge-ai",
        \\  "name": "Local Forge AI Ecosystem",
        \\  "version": "0.1.0",
        \\  "description": "Local tools, context sources, skill packs, eval packs, providers, and permissions.",
        \\  "permissions": [
        \\    {"id": "workspace.read", "description": "Read workspace files", "risk": "low", "approval": "automatic"},
        \\    {"id": "workspace.write", "description": "Edit workspace files", "risk": "high", "approval": "review"},
        \\    {"id": "network.fetch", "description": "Fetch public URLs", "risk": "medium", "approval": "every_time"}
        \\  ],
        \\  "tools": [
        \\    {"id": "forge.read_file", "title": "Read file", "transport": "native", "permissions": ["workspace.read"]},
        \\    {"id": "forge.replace_file_content", "title": "Edit file", "transport": "native", "permissions": ["workspace.write"]}
        \\  ],
        \\  "context_sources": [
        \\    {"id": "forge.semantic", "title": "Semantic codebase search", "kind": "index", "refresh": "incremental", "permissions": ["workspace.read"]}
        \\  ],
        \\  "skill_packs": [
        \\    {
        \\      "id": "forge.default-coding",
        \\      "title": "Default Coding Agent",
        \\      "languages": ["zig"],
        \\      "workflows": [
        \\        {
        \\          "id": "forge.implement",
        \\          "title": "Implement a focused code change",
        \\          "mode": "agent",
        \\          "tools": ["forge.read_file", "forge.replace_file_content"],
        \\          "context_sources": ["forge.semantic"],
        \\          "eval_pack": "forge.basic-agent"
        \\        }
        \\      ]
        \\    }
        \\  ],
        \\  "eval_packs": [
        \\    {"id": "forge.basic-agent", "title": "Basic agent reliability", "corpus": "fixtures/eval/agent_reliability.json", "min_success_rate": 0.8}
        \\  ],
        \\  "provider_hints": [
        \\    {"id": "local-large", "provider": "ollama", "model": "qwen3.5:35b", "role": "coding", "context_window": 131072}
        \\  ],
        \\  "marketplace": {"enabled": true, "source": "local"}
        \\}
        \\
    );
}

pub fn parseRisk(value: []const u8) ?PermissionRisk {
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    return null;
}

pub fn parseApproval(value: []const u8) ?PermissionMode {
    if (std.mem.eql(u8, value, "automatic")) return .automatic;
    if (std.mem.eql(u8, value, "review")) return .review;
    if (std.mem.eql(u8, value, "every_time")) return .every_time;
    return null;
}

const IdSet = struct {
    manifest: *const Manifest,

    fn initFromManifest(self: *IdSet, manifest: *const Manifest) ValidationError!void {
        self.* = .{ .manifest = manifest };
        try ensureUniquePermissions(manifest.permissions);
        try ensureUniqueTools(manifest.tools);
        try ensureUniqueContextSources(manifest.context_sources);
        try ensureUniqueEvalPacks(manifest.eval_packs);
    }

    fn hasPermission(self: *const IdSet, id: []const u8) bool {
        for (self.manifest.permissions) |perm| {
            if (std.mem.eql(u8, perm.id, id)) return true;
        }
        return false;
    }

    fn hasTool(self: *const IdSet, id: []const u8) bool {
        for (self.manifest.tools) |tool| {
            if (std.mem.eql(u8, tool.id, id)) return true;
        }
        return false;
    }

    fn hasContextSource(self: *const IdSet, id: []const u8) bool {
        for (self.manifest.context_sources) |source| {
            if (std.mem.eql(u8, source.id, id)) return true;
        }
        return false;
    }

    fn hasEvalPack(self: *const IdSet, id: []const u8) bool {
        for (self.manifest.eval_packs) |eval| {
            if (std.mem.eql(u8, eval.id, id)) return true;
        }
        return false;
    }
};

fn ensureUniquePermissions(items: []const PermissionGrant) ValidationError!void {
    for (items, 0..) |item, i| {
        if (item.id.len == 0) return error.MissingId;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (std.mem.eql(u8, item.id, items[j].id)) return error.DuplicateId;
        }
    }
}

fn ensureUniqueTools(items: []const ToolContract) ValidationError!void {
    for (items, 0..) |item, i| {
        if (item.id.len == 0) return error.MissingId;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (std.mem.eql(u8, item.id, items[j].id)) return error.DuplicateId;
        }
    }
}

fn ensureUniqueContextSources(items: []const ContextSourceContract) ValidationError!void {
    for (items, 0..) |item, i| {
        if (item.id.len == 0) return error.MissingId;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (std.mem.eql(u8, item.id, items[j].id)) return error.DuplicateId;
        }
    }
}

fn ensureUniqueEvalPacks(items: []const EvalPackContract) ValidationError!void {
    for (items, 0..) |item, i| {
        if (item.id.len == 0) return error.MissingId;
        var j = i + 1;
        while (j < items.len) : (j += 1) {
            if (std.mem.eql(u8, item.id, items[j].id)) return error.DuplicateId;
        }
    }
}

test "ecosystem manifest validates all seven foundation contracts" {
    const allocator = std.testing.allocator;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeTemplate(&out.writer);

    var parsed = try parseManifest(allocator, out.writer.buffered());
    defer parsed.deinit();

    const summary = summarize(&parsed.value);
    try std.testing.expectEqual(@as(usize, 2), summary.tools);
    try std.testing.expectEqual(@as(usize, 1), summary.context_sources);
    try std.testing.expectEqual(@as(usize, 1), summary.skill_packs);
    try std.testing.expectEqual(@as(usize, 1), summary.workflows);
    try std.testing.expectEqual(@as(usize, 1), summary.eval_packs);
    try std.testing.expectEqual(@as(usize, 1), summary.provider_hints);
    try std.testing.expectEqual(@as(usize, 3), summary.permissions);
}

test "ecosystem manifest rejects unknown workflow tool" {
    const allocator = std.testing.allocator;
    const bad =
        \\{
        \\  "schema_version": 1,
        \\  "package_id": "bad",
        \\  "name": "Bad",
        \\  "skill_packs": [
        \\    {"id":"pack","workflows":[{"id":"flow","tools":["missing.tool"]}]}
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.UnknownTool, parseManifest(allocator, bad));
}

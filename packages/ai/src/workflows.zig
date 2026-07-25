//! Custom AI Workflows — user-defined automation stored in .forge/workflows/.
//! Each workflow is a TOML file defining steps with prompts, tools, and
//! conditions. Users can run workflows from the command palette.
const std = @import("std");

pub const WorkflowStep = struct {
    name: []const u8,
    prompt: []const u8,
    tool: ?[]const u8 = null, // Optional tool to execute (e.g. "search", "edit_file")
    condition: ?[]const u8 = null, // Optional condition expression
    mode: AgentMode = .agent, // Agent mode for this step

    pub fn deinit(self: *WorkflowStep, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.prompt);
        if (self.tool) |t| allocator.free(t);
        if (self.condition) |c| allocator.free(c);
    }
};

pub const AgentMode = enum {
    ask, // Read-only
    plan, // Plan only
    agent, // Full agent with tools
};

pub const Workflow = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    description: []const u8,
    steps: []WorkflowStep,
    tags: []const []const u8,

    pub fn deinit(self: *Workflow) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        for (self.steps) |*step| step.deinit(self.allocator);
        self.allocator.free(self.steps);
        for (self.tags) |tag| self.allocator.free(tag);
        self.allocator.free(self.tags);
    }
};

pub const WorkflowRegistry = struct {
    allocator: std.mem.Allocator,
    workflows: std.ArrayList(Workflow),

    pub fn init(allocator: std.mem.Allocator) WorkflowRegistry {
        return .{
            .allocator = allocator,
            .workflows = .empty,
        };
    }

    pub fn deinit(self: *WorkflowRegistry) void {
        for (self.workflows.items) |*wf| wf.deinit();
        self.workflows.deinit(self.allocator);
    }

    /// Register a workflow. Takes ownership of all fields.
    pub fn register(self: *WorkflowRegistry, workflow: Workflow) !void {
        try self.workflows.append(self.allocator, workflow);
    }

    /// Find a workflow by ID.
    pub fn find(self: *const WorkflowRegistry, id: []const u8) ?*const Workflow {
        for (self.workflows.items) |*wf| {
            if (std.mem.eql(u8, wf.id, id)) return wf;
        }
        return null;
    }

    /// List all workflow IDs and names.
    pub fn list(self: *const WorkflowRegistry) []const Workflow {
        return self.workflows.items;
    }

    /// Get built-in default workflows.
    pub fn defaultWorkflows(allocator: std.mem.Allocator) ![]Workflow {
        var wf_list: std.ArrayList(Workflow) = .empty;
        errdefer {
            for (wf_list.items) |*wf| wf.deinit();
            wf_list.deinit(allocator);
        }

        // Review PR workflow
        try wf_list.append(allocator, try createWorkflow(allocator, "review-pr", "Review Pull Request", "Analyze git diff and provide code review comments", &.{
            .{ .name = "get_diff", .prompt = "Get the full git diff for the current branch", .tool = "git_diff" },
            .{ .name = "analyze", .prompt = "Analyze the diff for bugs, security issues, and improvements", .mode = .ask },
            .{ .name = "report", .prompt = "Generate a structured review report with severity ratings", .mode = .ask },
        }, &.{"review"}));

        // Update docs workflow
        try wf_list.append(allocator, try createWorkflow(allocator, "update-docs", "Update Documentation", "Scan code changes and update relevant documentation", &.{
            .{ .name = "scan_changes", .prompt = "Find all files changed since last commit", .tool = "git_diff" },
            .{ .name = "find_docs", .prompt = "Find documentation files that reference the changed code", .tool = "search" },
            .{ .name = "update", .prompt = "Update the documentation to reflect the code changes", .mode = .agent },
        }, &.{"docs"}));

        // Fix lint errors workflow
        try wf_list.append(allocator, try createWorkflow(allocator, "fix-lint", "Fix Lint Errors", "Automatically fix lint and diagnostic errors", &.{
            .{ .name = "get_errors", .prompt = "Get all diagnostic errors for the current file", .tool = "diagnostics" },
            .{ .name = "fix", .prompt = "Fix each error one by one, preserving code style", .mode = .agent },
            .{ .name = "verify", .prompt = "Verify all errors are resolved", .tool = "diagnostics" },
        }, &.{ "lint", "fix" }));

        // Generate tests workflow
        try wf_list.append(allocator, try createWorkflow(allocator, "gen-tests", "Generate Tests", "Generate unit tests for the current file", &.{
            .{ .name = "analyze", .prompt = "Analyze the current file to identify all functions and their signatures", .mode = .ask },
            .{ .name = "generate", .prompt = "Generate comprehensive test cases for each function", .mode = .agent },
        }, &.{"test"}));

        return wf_list.toOwnedSlice(allocator);
    }
};

fn createWorkflow(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    description: []const u8,
    steps: []const struct { name: []const u8, prompt: []const u8, tool: ?[]const u8 = null, condition: ?[]const u8 = null, mode: AgentMode = .agent },
    tags: []const []const u8,
) !Workflow {
    const owned_steps = try allocator.alloc(WorkflowStep, steps.len);
    for (steps, 0..) |step, i| {
        owned_steps[i] = .{
            .name = try allocator.dupe(u8, step.name),
            .prompt = try allocator.dupe(u8, step.prompt),
            .tool = if (step.tool) |t| try allocator.dupe(u8, t) else null,
            .condition = if (step.condition) |c| try allocator.dupe(u8, c) else null,
            .mode = step.mode,
        };
    }

    const owned_tags = try allocator.alloc([]const u8, tags.len);
    for (tags, 0..) |tag, i| {
        owned_tags[i] = try allocator.dupe(u8, tag);
    }

    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .steps = owned_steps,
        .tags = owned_tags,
    };
}

test "WorkflowRegistry register and find" {
    const allocator = std.testing.allocator;
    var registry = WorkflowRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(try createWorkflow(allocator, "test-wf", "Test Workflow", "A test", &.{
        .{ .name = "step1", .prompt = "Do something" },
    }, &.{"test"}));

    try std.testing.expectEqual(@as(usize, 1), registry.workflows.items.len);
    try std.testing.expect(registry.find("test-wf") != null);
    try std.testing.expect(registry.find("nonexistent") == null);
}

test "defaultWorkflows creates built-in workflows" {
    const allocator = std.testing.allocator;
    const workflows = try WorkflowRegistry.defaultWorkflows(allocator);
    defer {
        for (workflows) |*wf| {
            var w = wf.*;
            w.deinit();
        }
        allocator.free(workflows);
    }
    try std.testing.expect(workflows.len >= 4);
    try std.testing.expect(std.mem.eql(u8, workflows[0].id, "review-pr"));
}

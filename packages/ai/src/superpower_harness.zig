const std = @import("std");

/// Superpower Harness — 7-phase workflow enforcement for AI coding agents.
///
/// Inspired by obra/superpowers (89K+ GitHub stars), this module enforces a
/// structured development workflow that prevents agents from rushing through
/// steps and skipping validation. The 7 phases are:
///
///   1. Brainstorm — understand requirements, explore codebase
///   2. Spec — write detailed specification
///   3. Plan — create implementation plan
///   4. TDD — write tests first
///   5. Subagent Dev — implement via focused subagents
///   6. Review — review code changes
///   7. Finalize — clean up, update docs, commit
///
/// Usage: `forge agent run --harness superpower "implement feature X"`
///
/// The harness wraps the agent loop, injecting phase-specific system prompts
/// and validating that each phase produces expected artifacts before moving
/// to the next.
pub const Phase = enum {
    brainstorm,
    spec,
    plan,
    tdd,
    subagent_dev,
    review,
    finalize,

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .brainstorm => "Brainstorm",
            .spec => "Spec",
            .plan => "Plan",
            .tdd => "TDD",
            .subagent_dev => "Subagent Dev",
            .review => "Review",
            .finalize => "Finalize",
        };
    }

    pub fn icon(self: Phase) []const u8 {
        return switch (self) {
            .brainstorm => "\xe2\x9c\xa8", // ✨
            .spec => "\xf0\x9f\x93\x9d", // 📝
            .plan => "\xf0\x9f\x97\xba", // 🗺
            .tdd => "\xf0\x9f\xa7\xaa", // 🧪
            .subagent_dev => "\xf0\x9f\xa4\x96", // 🤖
            .review => "\xf0\x9f\x91\x81", // 👁
            .finalize => "\xe2\x9c\x85", // ✅
        };
    }

    pub fn prompt(self: Phase) []const u8 {
        return switch (self) {
            .brainstorm =>
            \\You are in the BRAINSTORM phase. Before writing any code:
            \\1. Read relevant files to understand the codebase structure
            \\2. Identify the key components that will be affected
            \\3. Consider 2-3 approaches and trade-offs
            \\4. Summarize your understanding and proposed approach
            \\Do NOT write code yet. Focus on understanding.
            ,
            .spec =>
            \\You are in the SPEC phase. Write a detailed specification:
            \\1. Create a spec document in .forge/specs/ describing the feature
            \\2. Include: requirements, API design, data flow, edge cases
            \\3. List acceptance criteria (testable conditions)
            \\4. Identify risks and dependencies
            \\Do NOT write implementation code yet.
            ,
            .plan =>
            \\You are in the PLAN phase. Create an implementation plan:
            \\1. Break down the work into ordered steps
            \\2. For each step, identify files to modify/create
            \\3. Estimate complexity and dependencies between steps
            \\4. Identify which steps can be parallelized via subagents
            \\Do NOT write code yet. Output the plan as a numbered list.
            ,
            .tdd =>
            \\You are in the TDD phase. Write tests FIRST:
            \\1. Write failing tests that validate the acceptance criteria
            \\2. Run the tests to confirm they fail for the right reason
            \\3. Do NOT implement the feature yet
            \\4. Output the test file paths and test names
            ,
            .subagent_dev =>
            \\You are in the SUBAGENT DEV phase. Implement via subagents:
            \\1. For each step in your plan, spawn a subagent if parallelizable
            \\2. Each subagent should focus on one file or one concern
            \\3. Review subagent results before proceeding to the next step
            \\4. Run tests after each step to ensure no regressions
            ,
            .review =>
            \\You are in the REVIEW phase. Review the implementation:
            \\1. Run all tests and ensure they pass
            \\2. Check for code quality issues (naming, errors, docs)
            \\3. Verify the implementation matches the spec
            \\4. Look for edge cases that weren't tested
            \\5. Output a review summary with any issues found
            ,
            .finalize =>
            \\You are in the FINALIZE phase. Clean up:
            \\1. Update documentation (README, CHANGELOG, inline docs)
            \\2. Remove any debug code or temporary files
            \\3. Stage and commit changes with a clear message
            \\4. Output a summary of what was accomplished
            ,
        };
    }

    pub fn next(self: Phase) ?Phase {
        return switch (self) {
            .brainstorm => .spec,
            .spec => .plan,
            .plan => .tdd,
            .tdd => .subagent_dev,
            .subagent_dev => .review,
            .review => .finalize,
            .finalize => null,
        };
    }
};

pub const HarnessState = struct {
    current_phase: Phase = .brainstorm,
    phase_step: u32 = 0,
    /// Whether the current phase has produced its expected artifact.
    phase_complete: bool = false,
    /// Total steps across all phases.
    total_steps: u32 = 0,
};

/// Build the system prompt for the current phase.
/// The agent loop prepends this to the user's intent.
pub fn phaseSystemPrompt(phase: Phase, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {s} Phase ({d}/7)\n\n{s}", .{ phase.icon(), phase.label(), @intFromEnum(phase) + 1, phase.prompt() });
}

/// Check if the agent's response indicates the phase is complete.
/// Simple heuristic: if the response contains phase-specific markers.
pub fn isPhaseComplete(phase: Phase, response: []const u8) bool {
    return switch (phase) {
        .brainstorm => std.mem.indexOf(u8, response, "approach") != null or std.mem.indexOf(u8, response, "Approach") != null,
        .spec => std.mem.indexOf(u8, response, ".forge/specs/") != null or std.mem.indexOf(u8, response, "acceptance criteria") != null,
        .plan => std.mem.indexOf(u8, response, "1.") != null and std.mem.indexOf(u8, response, "2.") != null,
        .tdd => std.mem.indexOf(u8, response, "test") != null or std.mem.indexOf(u8, response, "Test") != null,
        .subagent_dev => std.mem.indexOf(u8, response, "subagent") != null or std.mem.indexOf(u8, response, "implemented") != null,
        .review => std.mem.indexOf(u8, response, "review") != null or std.mem.indexOf(u8, response, "Review") != null,
        .finalize => std.mem.indexOf(u8, response, "commit") != null or std.mem.indexOf(u8, response, "summary") != null,
    };
}

test "Phase.next cycles through all 7 phases" {
    var p: Phase = .brainstorm;
    var count: u32 = 1;
    while (p.next()) |next_p| {
        p = next_p;
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 7), count);
    try std.testing.expectEqual(Phase.finalize, p);
}

test "Phase.label returns human-readable name" {
    try std.testing.expectEqualStrings("Brainstorm", Phase.brainstorm.label());
    try std.testing.expectEqualStrings("Spec", Phase.spec.label());
    try std.testing.expectEqualStrings("Finalize", Phase.finalize.label());
}

test "isPhaseComplete detects markers" {
    try std.testing.expect(isPhaseComplete(.brainstorm, "My proposed approach is..."));
    try std.testing.expect(isPhaseComplete(.spec, "Created .forge/specs/feature.md"));
    try std.testing.expect(isPhaseComplete(.tdd, "wrote test for auth"));
    try std.testing.expect(!isPhaseComplete(.brainstorm, "no markers here"));
}

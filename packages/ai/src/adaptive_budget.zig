const std = @import("std");
const routing = @import("routing.zig");
const task_ledger = @import("task_ledger.zig");

/// Adaptive step budget (RFC-0020).
///
/// Currently the agent loop uses a fixed `max_steps` (default 6 for explore,
/// 128 for agent). This module computes an adaptive step budget based on:
///
///   1. Task intent complexity (answer_question < explore < edit < debug)
///   2. Task ledger state (more steps when repairing/blocked)
///   3. Conversation history length (more steps for resumed sessions)
///
/// The adaptive budget prevents both:
///   - Premature StepLimitReached for complex debugging tasks
///   - Wasted tokens on simple questions that don't need 128 steps

pub const StepBudgetInput = struct {
    intent: routing.TaskIntent,
    /// Current task ledger phase (if available).
    ledger_phase: ?task_ledger.Phase = null,
    /// Number of entries in the task ledger.
    ledger_entries: usize = 0,
    /// Whether this is a resumed session.
    is_resume: bool = false,
    /// Explicitly requested max_steps (from --max-steps flag). When set,
    /// overrides the adaptive calculation.
    explicit_max_steps: ?u32 = null,
    /// Provider context window (affects how many steps we can afford
    /// before compaction kicks in).
    context_window: usize = 32_768,
};

pub const StepBudget = struct {
    max_steps: u32,
    /// Human-readable rationale for the chosen budget.
    rationale: []const u8,
};

pub fn computeAdaptiveBudget(input: StepBudgetInput) StepBudget {
    // Explicit override always wins.
    if (input.explicit_max_steps) |steps| {
        return .{ .max_steps = steps, .rationale = "explicit --max-steps override" };
    }

    // Base budget by intent complexity.
    var base: u32 = switch (input.intent) {
        .answer_question => 4, // simple Q&A: 1-2 tool calls + answer
        .explore_codebase => 8, // exploration: several reads + summary
        .plan_change => 6, // planning: read + plan output
        .edit_code => 16, // implementation: read + edit + validate
        .debug_failure => 24, // debugging: read + reproduce + fix + validate
        .computer_control => 12, // UI interaction: screenshot + click + verify
    };

    var rationale: []const u8 = "intent-based default";

    // Bump budget when the task ledger indicates a long-running task.
    if (input.ledger_entries > 0) {
        const stats = task_ledger.Stats{
            .phase = input.ledger_phase orelse .planning,
            .entries = input.ledger_entries,
        };
        if (stats.longTask()) {
            base = @max(base, 32);
            rationale = "long task (ledger entries >= 16)";
        }
    }

    // Bump budget when repairing or blocked.
    if (input.ledger_phase) |phase| {
        switch (phase) {
            .repairing => {
                base += 8;
                rationale = "repair phase (extra steps for fix + re-validate)";
            },
            .blocked => {
                base += 4;
                rationale = "blocked phase (extra steps for unblocking)";
            },
            else => {},
        }
    }

    // Resumed sessions get extra budget to continue where they left off.
    if (input.is_resume) {
        base += 4;
        rationale = "resumed session (continuation budget)";
    }

    // Cap at a reasonable maximum to prevent runaway loops.
    const cap: u32 = 64;
    if (base > cap) {
        base = cap;
        rationale = "capped at maximum (64 steps)";
    }

    return .{ .max_steps = base, .rationale = rationale };
}

test "answer_question gets small budget" {
    const budget = computeAdaptiveBudget(.{ .intent = .answer_question });
    try std.testing.expectEqual(@as(u32, 4), budget.max_steps);
}

test "debug_failure gets larger budget" {
    const budget = computeAdaptiveBudget(.{ .intent = .debug_failure });
    try std.testing.expect(budget.max_steps >= 24);
}

test "explicit override wins" {
    const budget = computeAdaptiveBudget(.{
        .intent = .answer_question,
        .explicit_max_steps = 100,
    });
    try std.testing.expectEqual(@as(u32, 100), budget.max_steps);
}

test "repair phase adds budget" {
    const base = computeAdaptiveBudget(.{ .intent = .edit_code });
    const repair = computeAdaptiveBudget(.{
        .intent = .edit_code,
        .ledger_phase = .repairing,
    });
    try std.testing.expect(repair.max_steps > base.max_steps);
}

test "budget is capped" {
    const budget = computeAdaptiveBudget(.{
        .intent = .debug_failure,
        .ledger_phase = .repairing,
        .is_resume = true,
        .ledger_entries = 100,
    });
    try std.testing.expect(budget.max_steps <= 64);
}

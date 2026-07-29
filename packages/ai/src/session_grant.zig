//! Session-scoped approval grant cache.
//!
//! Reduces repeated approval prompts during an agent session by remembering
//! which tools the user has already approved. This is distinct from the
//! `approve_every_time_tools` flag (which approves everything globally) —
//! the grant cache only remembers tools the user has explicitly approved at
//! least once in the current session.
//!
//! ## Threat model
//!
//! A session grant does NOT replace the per-call approval gate for high-risk
//! tools unless the caller explicitly opts into high-risk grants (for example
//! `/tools trust-all` or `--trust-all`). Without that opt-in, tools such as
//! run_command and replace_file_content are always re-evaluated.
//!
//! MCP tools default to high risk and therefore cannot be session-granted
//! unless the caller enabled high-risk grants or the tool policy is lowered by
//! trusted metadata.
//!
//! ## Usage
//!
//! ```zig
//! var grants = SessionGrants.init(allocator);
//! defer grants.deinit();
//!
//! // Wire it into the agent approval callback:
//! config.approval_callback = SessionGrants.approvalCallback;
//! config.approval_context = &grants;
//!
//! // When user approves interactively, record the grant:
//! grants.grant("fetch_url", .session) catch {};
//! ```

const std = @import("std");
const tool_registry = @import("tools/registry.zig");

/// The scope of an approval grant.
pub const GrantScope = enum {
    /// Approve only this single call (equivalent to the existing every_time behaviour).
    once,
    /// Approve all calls to this tool within the current session.
    session,
    /// Approve all calls to this tool for all future sessions (persisted to disk).
    /// NOTE: persisted grants are not yet implemented; this value is reserved for M7.
    always,
};

/// A single grant entry in the cache.
const GrantEntry = struct {
    /// Wire name of the granted tool (e.g. "fetch_url").
    tool_name: []const u8,
    scope: GrantScope,
    /// Monotonic call count at the time the grant was issued.
    issued_at_call: u32,
};

/// Per-session approval state that can be wired into the agent loop as an
/// `ApprovalCallback`.
pub const SessionGrants = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(GrantEntry) = .empty,
    call_count: u32 = 0,
    allow_high_risk: bool = false,

    pub fn init(allocator: std.mem.Allocator, allow_high_risk: bool) SessionGrants {
        return .{ .allocator = allocator, .allow_high_risk = allow_high_risk };
    }

    pub fn deinit(self: *SessionGrants) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.tool_name);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Record a grant for the given tool.
    ///
    /// High-risk tools are silently rejected — their policy cannot be
    /// session-granted to prevent privilege escalation.
    pub fn grant(self: *SessionGrants, tool_name: []const u8, scope: GrantScope) !void {
        const policy = tool_registry.policyFor(tool_name);
        // Only grant session approval for high-risk tools if explicitly allowed.
        if (policy.risk == .high and !self.allow_high_risk) return;

        // Avoid duplicate entries: update scope if already granted.
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.tool_name, tool_name)) {
                entry.scope = scope;
                entry.issued_at_call = self.call_count;
                return;
            }
        }

        const owned_name = try self.allocator.dupe(u8, tool_name);
        errdefer self.allocator.free(owned_name);
        try self.entries.append(self.allocator, .{
            .tool_name = owned_name,
            .scope = scope,
            .issued_at_call = self.call_count,
        });
    }

    /// Revoke a previously issued session grant for the given tool.
    pub fn revoke(self: *SessionGrants, tool_name: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.tool_name, tool_name)) {
                self.allocator.free(self.entries.items[i].tool_name);
                _ = self.entries.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Revoke all current session grants (e.g. on suspicious model behaviour).
    pub fn revokeAll(self: *SessionGrants) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.tool_name);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Returns true if the tool is covered by an active session grant.
    /// High-risk tools always return false regardless of entries.
    pub fn isGranted(self: *const SessionGrants, tool_name: []const u8, policy: tool_registry.Policy) bool {
        // High-risk tools are session-grantable only if explicitly allowed.
        if (policy.risk == .high and !self.allow_high_risk) return false;
        // Automatic tools never need a grant check.
        if (policy.approval == .automatic) return true;

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.tool_name, tool_name)) {
                return entry.scope == .session or entry.scope == .always;
            }
        }
        return false;
    }

    /// Whether there is any active session grant (useful for UI hints).
    pub fn hasAnyGrant(self: *const SessionGrants) bool {
        return self.entries.items.len > 0;
    }

    /// Returns all current grant entries. Caller does NOT own the slice.
    pub fn grantedTools(self: *const SessionGrants) []const GrantEntry {
        return self.entries.items;
    }

    /// `ApprovalCallback` implementation for `agent/loop.zig`.
    ///
    /// Wire up as:
    /// ```zig
    /// config.approval_callback = SessionGrants.approvalCallback;
    /// config.approval_context = &my_grants;
    /// ```
    ///
    /// Returns true (approve) when the tool has an active session grant. High-risk
    /// grants require `allow_high_risk=true`. Returns false otherwise — the caller
    /// should prompt the user interactively and call `grants.grant(tool_name,
    /// .session)` if they choose "approve for session".
    pub fn approvalCallback(
        raw_context: ?*anyopaque,
        tool_name: []const u8,
        _: []const u8,
        policy: tool_registry.Policy,
    ) bool {
        const self: *SessionGrants = @ptrCast(@alignCast(raw_context.?));
        self.call_count +|= 1;
        return self.isGranted(tool_name, policy);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "session grants approve medium-risk tool after explicit grant" {
    var grants = SessionGrants.init(std.testing.allocator, false);
    defer grants.deinit();

    const policy = tool_registry.Policy{ .risk = .medium, .approval = .every_time };

    try std.testing.expect(!grants.isGranted("fetch_url", policy));

    try grants.grant("fetch_url", .session);
    try std.testing.expect(grants.isGranted("fetch_url", policy));
}

test "session grants never approve high-risk tools" {
    var grants = SessionGrants.init(std.testing.allocator, false);
    defer grants.deinit();

    const policy = tool_registry.Policy{ .risk = .high, .approval = .every_time };

    // Attempt to grant high-risk tool — must be silently rejected.
    try grants.grant("run_command", .session);

    try std.testing.expect(!grants.isGranted("run_command", policy));
    try std.testing.expectEqual(@as(usize, 0), grants.entries.items.len);
}

test "session grants can approve high-risk tools when explicitly allowed" {
    var grants = SessionGrants.init(std.testing.allocator, true);
    defer grants.deinit();

    const policy = tool_registry.Policy{ .risk = .high, .approval = .review };

    try grants.grant("replace_file_content", .session);

    try std.testing.expect(grants.isGranted("replace_file_content", policy));
    try std.testing.expectEqual(@as(usize, 1), grants.entries.items.len);
}

test "session grants revoke removes the entry" {
    var grants = SessionGrants.init(std.testing.allocator, false);
    defer grants.deinit();

    try grants.grant("fetch_url", .session);
    try std.testing.expectEqual(@as(usize, 1), grants.entries.items.len);

    const removed = grants.revoke("fetch_url");
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(usize, 0), grants.entries.items.len);
}

test "revokeAll clears all grants" {
    var grants = SessionGrants.init(std.testing.allocator, false);
    defer grants.deinit();

    try grants.grant("fetch_url", .session);
    try grants.grant("remember", .session);
    try std.testing.expectEqual(@as(usize, 2), grants.entries.items.len);

    grants.revokeAll();
    try std.testing.expectEqual(@as(usize, 0), grants.entries.items.len);
}

test "duplicate grant updates scope without creating a duplicate entry" {
    var grants = SessionGrants.init(std.testing.allocator, false);
    defer grants.deinit();

    try grants.grant("fetch_url", .once);
    try grants.grant("fetch_url", .session);

    try std.testing.expectEqual(@as(usize, 1), grants.entries.items.len);
    try std.testing.expectEqual(GrantScope.session, grants.entries.items[0].scope);
}

test "approvalCallback returns true for granted medium-risk tool" {
    var grants = SessionGrants.init(std.testing.allocator, false);
    defer grants.deinit();

    try grants.grant("fetch_url", .session);

    const policy = tool_registry.Policy{ .risk = .medium, .approval = .every_time };
    const result = SessionGrants.approvalCallback(&grants, "fetch_url", "{}", policy);
    try std.testing.expect(result);
}

test "approvalCallback returns false for ungranted tool" {
    var grants = SessionGrants.init(std.testing.allocator, false);
    defer grants.deinit();

    const policy = tool_registry.Policy{ .risk = .medium, .approval = .every_time };
    const result = SessionGrants.approvalCallback(&grants, "fetch_url", "{}", policy);
    try std.testing.expect(!result);
}

//! Session management — wraps the Supabase Auth client with auto-refresh
//! logic. The SessionManager holds the current session and automatically
//! refreshes the access_token when it's about to expire (within a 5-minute
//! margin).
//!
//! Usage:
//!   var manager = SessionManager.init(allocator, io, config);
//!   defer manager.deinit();
//!
//!   // Try to load stored session on startup
//!   try manager.loadStored();
//!
//!   // Or sign in fresh
//!   try manager.signInWithEmail("user@example.com", "password");
//!
//!   // Get a valid access_token (auto-refreshes if needed)
//!   const token = try manager.getValidAccessToken();
//!
//!   // Sign out
//!   try manager.signOut();

const std = @import("std");
const supabase_auth = @import("supabase_auth.zig");
const token_store = @import("token_store.zig");

pub const AuthError = supabase_auth.AuthError;

/// Margin (in seconds) before token expiry to trigger a refresh.
/// 5 minutes = 300 seconds. This ensures we never send an expired
/// token to the backend — we refresh proactively.
const REFRESH_MARGIN_SECONDS: i64 = 300;

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: supabase_auth.Config,
    session: ?supabase_auth.Session,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: supabase_auth.Config,
    ) SessionManager {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .session = null,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        if (self.session) |*s| s.deinit();
        self.session = null;
    }

    /// Check if the user is currently logged in (has a session).
    pub fn isLoggedIn(self: SessionManager) bool {
        return self.session != null;
    }

    /// Get the current user's UID, or null if not logged in.
    pub fn uid(self: SessionManager) ?[]const u8 {
        if (self.session) |s| return s.uid;
        return null;
    }

    /// Get the current user's email, or null if not logged in.
    pub fn email(self: SessionManager) ?[]const u8 {
        if (self.session) |s| return s.email;
        return null;
    }

    /// Sign up a new user with email and password.
    /// On success, stores the session and persists it to disk.
    pub fn signUpWithEmail(
        self: *SessionManager,
        email_addr: []const u8,
        password: []const u8,
    ) AuthError!void {
        const session = try supabase_auth.signUpWithEmail(
            self.allocator,
            self.io,
            self.config,
            email_addr,
            password,
        );
        if (self.session) |*s| s.deinit();
        self.session = session;
        try self.persist();
    }

    /// Sign in an existing user with email and password.
    /// On success, stores the session and persists it to disk.
    pub fn signInWithEmail(
        self: *SessionManager,
        email_addr: []const u8,
        password: []const u8,
    ) AuthError!void {
        const session = try supabase_auth.signInWithEmail(
            self.allocator,
            self.io,
            self.config,
            email_addr,
            password,
        );
        if (self.session) |*s| s.deinit();
        self.session = session;
        try self.persist();
    }

    /// Sign out the current user. Revokes the session server-side and
    /// clears the stored session file.
    pub fn signOut(self: *SessionManager) AuthError!void {
        if (self.session) |s| {
            supabase_auth.signOut(
                self.allocator,
                self.io,
                self.config,
                s.access_token,
            ) catch |err| switch (err) {
                // Even if server-side revocation fails (network error,
                // already expired, etc.), we still clear the local
                // session — the user wants to sign out regardless.
                AuthError.NetworkError,
                AuthError.InvalidToken,
                AuthError.TooManyRequests,
                => {},
                else => return err,
            };
            s.deinit();
        }
        self.session = null;
        token_store.clearStoredSession(self.allocator, self.io);
    }

    /// Load a previously stored session from disk.
    /// Returns null (no error) if no session file exists.
    pub fn loadStored(self: *SessionManager) AuthError!void {
        const stored = token_store.loadStoredSession(self.allocator, self.io) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return AuthError.MalformedResponse,
        };
        if (stored) |session| {
            if (self.session) |*s| s.deinit();
            self.session = session;
        }
    }

    /// Get a valid access_token, refreshing if necessary.
    /// Returns an error if not logged in or refresh fails.
    pub fn getValidAccessToken(self: *SessionManager) AuthError![]const u8 {
        if (self.session) |*s| {
            if (!s.isExpired(self.io, REFRESH_MARGIN_SECONDS)) {
                return s.access_token;
            }
            // Token is expired or about to expire — refresh it.
            try self.refresh();
            return self.session.?.access_token;
        }
        return AuthError.InvalidToken;
    }

    /// Force a token refresh using the stored refresh_token.
    pub fn refresh(self: *SessionManager) AuthError!void {
        const old_session = self.session orelse return AuthError.InvalidToken;
        const new_session = try supabase_auth.refreshToken(
            self.allocator,
            self.io,
            self.config,
            old_session.refresh_token,
        );
        old_session.deinit();
        self.session = new_session;
        try self.persist();
    }

    /// Persist the current session to disk.
    pub fn persist(self: *SessionManager) AuthError!void {
        if (self.session) |s| {
            token_store.saveSession(self.allocator, self.io, s) catch return AuthError.AccessDenied;
        }
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────
//
// Note: SessionManager tests that require HTTP (signInWithEmail, refresh,
// signOut) are integration tests that need a real Supabase project.
// Unit tests here only cover the non-network logic.

test "REFRESH_MARGIN_SECONDS is 5 minutes" {
    try std.testing.expectEqual(@as(i64, 300), REFRESH_MARGIN_SECONDS);
}

test "SessionManager struct has expected fields" {
    // Verify the struct layout compiles — no runtime test needed.
    const T = SessionManager;
    _ = T.init;
    _ = T.deinit;
    _ = T.isLoggedIn;
    _ = T.uid;
    _ = T.email;
    _ = T.signUpWithEmail;
    _ = T.signInWithEmail;
    _ = T.signOut;
    _ = T.loadStored;
    _ = T.getValidAccessToken;
    _ = T.refresh;
    _ = T.persist;
}

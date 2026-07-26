//! Supabase Auth REST client — pure HTTP, no SDK required.
//!
//! Implements the Supabase GoTrue Auth REST API for email/password
//! sign-up, sign-in, token refresh, sign-out, and user lookup.
//! Designed for use from Zig desktop apps (Forge IDE) that can only
//! do HTTP — no Firebase/Supabase JS SDK available.
//!
//! All endpoints require two headers:
//!   apikey: <SUPABASE_ANON_KEY>   — the project's anon/public key
//!   Authorization: Bearer <jwt>   — user's JWT (or anon key for sign-up/sign-in)
//!
//! Reference: https://supabase.com/docs/guides/auth

const std = @import("std");
const workspace = @import("forge-workspace");

/// Authentication errors.
pub const AuthError = error{
    NetworkError,
    InvalidCredentials,
    EmailAlreadyInUse,
    EmailNotConfirmed,
    TooManyRequests,
    TokenExpired,
    InvalidToken,
    UserNotFound,
    MalformedResponse,
    OutOfMemory,
    AccessDenied,
};

/// A user session returned by sign-in / sign-up / refresh.
/// The `access_token` is a JWT that expires in `expires_in` seconds.
/// The `refresh_token` is long-lived and can be used to get a new
/// access_token without re-entering credentials.
pub const Session = struct {
    allocator: std.mem.Allocator,
    uid: []u8,
    email: []u8,
    access_token: []u8,
    refresh_token: []u8,
    /// Unix timestamp (seconds) when the access_token expires.
    expires_at: i64,

    pub fn deinit(self: *Session) void {
        // Secure-zero the tokens before freeing (they're sensitive).
        std.crypto.secureZero(u8, self.access_token);
        std.crypto.secureZero(u8, self.refresh_token);
        self.allocator.free(self.uid);
        self.allocator.free(self.email);
        self.allocator.free(self.access_token);
        self.allocator.free(self.refresh_token);
        self.* = undefined;
    }

    /// Check if the access_token has expired (or will expire within
    /// `margin_seconds`). Returns true if a refresh is needed.
    pub fn isExpired(self: Session, io: std.Io, margin_seconds: i64) bool {
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        return now >= self.expires_at - margin_seconds;
    }
};

/// Supabase project configuration.
pub const Config = struct {
    /// Project URL, e.g. "https://abcdefgh.supabase.co"
    project_url: []const u8,
    /// Anon/public API key from Supabase dashboard.
    anon_key: []const u8,
};

/// Sign up a new user with email and password.
/// Returns a Session on success. The user may need to confirm their
/// email before they can sign in (depending on Supabase project settings).
pub fn signUpWithEmail(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    email: []const u8,
    password: []const u8,
) AuthError!Session {
    const url = try std.fmt.allocPrint(allocator, "{s}/auth/v1/signup", .{config.project_url});
    defer allocator.free(url);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"email":"{s}","password":"{s}"}}
    , .{ email, password });
    defer allocator.free(payload);

    return doAuthRequest(allocator, io, config, url, payload);
}

/// Sign in an existing user with email and password.
/// Returns a Session on success.
pub fn signInWithEmail(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    email: []const u8,
    password: []const u8,
) AuthError!Session {
    const url = try std.fmt.allocPrint(allocator, "{s}/auth/v1/token?grant_type=password", .{config.project_url});
    defer allocator.free(url);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"email":"{s}","password":"{s}"}}
    , .{ email, password });
    defer allocator.free(payload);

    return doAuthRequest(allocator, io, config, url, payload);
}

/// Refresh an expired access_token using a refresh_token.
/// Returns a new Session with fresh tokens.
pub fn refreshToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    refresh_token: []const u8,
) AuthError!Session {
    const url = try std.fmt.allocPrint(allocator, "{s}/auth/v1/token?grant_type=refresh_token", .{config.project_url});
    defer allocator.free(url);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"refresh_token":"{s}"}}
    , .{refresh_token});
    defer allocator.free(payload);

    return doAuthRequest(allocator, io, config, url, payload);
}

/// Sign out the current user (revoke the session server-side).
/// After this, the refresh_token is no longer valid.
pub fn signOut(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    access_token: []const u8,
) AuthError!void {
    const url = try std.fmt.allocPrint(allocator, "{s}/auth/v1/logout", .{config.project_url});
    defer allocator.free(url);

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    const headers = [_]std.http.Header{
        .{ .name = "apikey", .value = config.anon_key },
        .{ .name = "Authorization", .value = auth_header },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &headers,
        .response_writer = &response_alloc.writer,
    }) catch return AuthError.NetworkError;

    switch (result.status) {
        .no_content, .ok => return,
        .unauthorized, .forbidden => return AuthError.InvalidToken,
        .too_many_requests => return AuthError.TooManyRequests,
        else => return AuthError.NetworkError,
    }
}

/// Get the current user's profile (requires a valid access_token).
/// Returns the raw JSON response body (caller must free).
pub fn getUser(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    access_token: []const u8,
) AuthError![]u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/auth/v1/user", .{config.project_url});
    defer allocator.free(url);

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    const headers = [_]std.http.Header{
        .{ .name = "apikey", .value = config.anon_key },
        .{ .name = "Authorization", .value = auth_header },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &headers,
        .response_writer = &response_alloc.writer,
    }) catch return AuthError.NetworkError;

    switch (result.status) {
        .ok => {},
        .unauthorized, .forbidden => return AuthError.InvalidToken,
        .too_many_requests => return AuthError.TooManyRequests,
        else => return AuthError.NetworkError,
    }

    const body = response_alloc.writer.buffer[0..response_alloc.writer.end];
    if (body.len == 0) return AuthError.MalformedResponse;
    return allocator.dupe(u8, body) catch AuthError.OutOfMemory;
}

// ─── Internal ──────────────────────────────────────────────────────────

fn doAuthRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    url: []const u8,
    payload: []const u8,
) AuthError!Session {
    std.debug.print("[auth] doAuthRequest: url={s}\n", .{url});
    std.debug.print("[auth] anon_key.len={}\n", .{config.anon_key.len});
    std.debug.print("[auth] anon_key prefix={s}\n", .{if (config.anon_key.len > 20) config.anon_key[0..20] else config.anon_key});

    // anon_key must be non-empty — all Supabase Auth REST calls require it.
    if (config.anon_key.len == 0) {
        std.debug.print("[auth] ERROR: anon_key is empty!\n", .{});
        return AuthError.MalformedResponse;
    }

    var response_alloc = std.Io.Writer.Allocating.init(allocator);
    defer response_alloc.deinit();

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Supabase Auth requires:
    //   apikey: <anon_key>
    //   Authorization: Bearer <anon_key>
    const auth_value = std.fmt.allocPrint(allocator, "Bearer {s}", .{config.anon_key}) catch
        return AuthError.OutOfMemory;
    defer allocator.free(auth_value);

    const headers = [_]std.http.Header{
        .{ .name = "apikey", .value = config.anon_key },
        .{ .name = "Authorization", .value = auth_value },
    };

    std.debug.print("[auth] sending POST to {s}\n", .{url});
    std.debug.print("[auth] payload: {s}\n", .{payload});

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &headers,
        .response_writer = &response_alloc.writer,
    }) catch |err| {
        std.debug.print("[auth] fetch error: {}\n", .{err});
        return AuthError.NetworkError;
    };

    const body = response_alloc.writer.buffer[0..response_alloc.writer.end];
    std.debug.print("[auth] response status: {}\n", .{result.status});
    std.debug.print("[auth] response body len: {}\n", .{body.len});
    if (body.len > 0 and body.len < 500) {
        std.debug.print("[auth] response body: {s}\n", .{body});
    }

    if (body.len == 0) return AuthError.MalformedResponse;

    return switch (result.status) {
        .ok => parseSessionResponse(allocator, io, body),
        .unauthorized, .forbidden => AuthError.InvalidCredentials,
        .too_many_requests => AuthError.TooManyRequests,
        .conflict => AuthError.EmailAlreadyInUse,
        .not_found => AuthError.UserNotFound,
        else => AuthError.NetworkError,
    };
}

/// Parse the JSON response from sign-up/sign-in/refresh endpoints.
/// Expected shape:
///   {
///     "access_token": "eyJ...",
///     "token_type": "bearer",
///     "expires_in": 3600,
///     "refresh_token": "...",
///     "user": { "id": "...", "email": "..." }
///   }
fn parseSessionResponse(allocator: std.mem.Allocator, io: std.Io, body: []const u8) AuthError!Session {
    const Parsed = struct {
        access_token: []const u8,
        refresh_token: []const u8,
        expires_in: i64,
        user: struct {
            id: []const u8,
            email: []const u8,
        },
    };

    var parsed = std.json.parseFromSlice(Parsed, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return AuthError.MalformedResponse;
    defer parsed.deinit();

    const v = parsed.value;
    if (v.access_token.len == 0 or v.refresh_token.len == 0) {
        return AuthError.MalformedResponse;
    }

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const expires_at = now + v.expires_in;

    return Session{
        .allocator = allocator,
        .uid = allocator.dupe(u8, v.user.id) catch return AuthError.OutOfMemory,
        .email = allocator.dupe(u8, v.user.email) catch return AuthError.OutOfMemory,
        .access_token = allocator.dupe(u8, v.access_token) catch return AuthError.OutOfMemory,
        .refresh_token = allocator.dupe(u8, v.refresh_token) catch return AuthError.OutOfMemory,
        .expires_at = expires_at,
    };
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "parseSessionResponse extracts tokens and user info" {
    const body =
        \\{
        \\  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test",
        \\  "token_type": "bearer",
        \\  "expires_in": 3600,
        \\  "refresh_token": "refresh-abc-123",
        \\  "user": {
        \\    "id": "user-uid-123",
        \\    "email": "test@example.com",
        \\    "aud": "authenticated",
        \\    "role": "authenticated"
        \\  }
        \\}
    ;

    var session = try parseSessionResponse(std.testing.allocator, std.testing.io, body);
    defer session.deinit();

    try std.testing.expectEqualStrings("user-uid-123", session.uid);
    try std.testing.expectEqualStrings("test@example.com", session.email);
    try std.testing.expectEqualStrings("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test", session.access_token);
    try std.testing.expectEqualStrings("refresh-abc-123", session.refresh_token);
    try std.testing.expect(session.expires_at > std.Io.Timestamp.now(std.testing.io, .real).toSeconds());
}

test "parseSessionResponse rejects missing access_token" {
    const body =
        \\{
        \\  "access_token": "",
        \\  "refresh_token": "abc",
        \\  "expires_in": 3600,
        \\  "user": { "id": "x", "email": "x@x.com" }
        \\}
    ;
    try std.testing.expectError(AuthError.MalformedResponse, parseSessionResponse(std.testing.allocator, std.testing.io, body));
}

test "parseSessionResponse rejects malformed JSON" {
    const body = "not json at all";
    try std.testing.expectError(AuthError.MalformedResponse, parseSessionResponse(std.testing.allocator, std.testing.io, body));
}

test "Session.isExpired returns false for future expiry" {
    const io = std.testing.io;
    var session = Session{
        .allocator = std.testing.allocator,
        .uid = try std.testing.allocator.dupe(u8, "uid"),
        .email = try std.testing.allocator.dupe(u8, "e@e.com"),
        .access_token = try std.testing.allocator.dupe(u8, "token"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh"),
        .expires_at = std.Io.Timestamp.now(io, .real).toSeconds() + 3600,
    };
    defer session.deinit();

    try std.testing.expect(!session.isExpired(io, 60));
}

test "Session.isExpired returns true for past expiry" {
    const io = std.testing.io;
    var session = Session{
        .allocator = std.testing.allocator,
        .uid = try std.testing.allocator.dupe(u8, "uid"),
        .email = try std.testing.allocator.dupe(u8, "e@e.com"),
        .access_token = try std.testing.allocator.dupe(u8, "token"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh"),
        .expires_at = std.Io.Timestamp.now(io, .real).toSeconds() - 100,
    };
    defer session.deinit();

    try std.testing.expect(session.isExpired(io, 60));
}

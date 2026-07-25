//! Secure token storage — persists the user session to disk so it
//! survives app restarts. The session file is stored at
//! `~/.forge/auth.json` with restrictive permissions (0600).
//!
//! The file contains the refresh_token (long-lived) and access_token
//! (short-lived). On app startup, we load the session and refresh the
//! access_token if it has expired.

const std = @import("std");
const workspace = @import("forge-workspace");
const supabase_auth = @import("supabase_auth.zig");

pub const AuthError = supabase_auth.AuthError;

/// Load a stored session from `~/.forge/auth.json`.
/// Returns `null` if no session file exists (user not logged in).
/// Returns an error if the file exists but is corrupt.
pub fn loadStoredSession(
    allocator: std.mem.Allocator,
    io: std.Io,
) !?supabase_auth.Session {
    const path = try workspace.global_store.joinHome(allocator, "auth.json");
    defer allocator.free(path);

    const content = workspace.global_store.readAbsoluteFile(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    if (content.len == 0) return null;

    return try parseSessionFile(allocator, content);
}

/// Save a session to `~/.forge/auth.json` with restrictive permissions.
/// Creates the `~/.forge/` directory if it doesn't exist.
pub fn saveSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: supabase_auth.Session,
) !void {
    const path = try workspace.global_store.joinHome(allocator, "auth.json");
    defer allocator.free(path);

    // Ensure ~/.forge/ directory exists
    const forge_home = try workspace.global_store.joinHome(allocator, "");
    defer allocator.free(forge_home);
    workspace.global_store.mkdirAllAbsolute(forge_home) catch {};

    // Serialize session to JSON
    const json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "uid": "{s}",
        \\  "email": "{s}",
        \\  "access_token": "{s}",
        \\  "refresh_token": "{s}",
        \\  "expires_at": {d}
        \\}}
        \\
    , .{
        session.uid,
        session.email,
        session.access_token,
        session.refresh_token,
        session.expires_at,
    });
    defer allocator.free(json);

    try workspace.global_store.replaceAbsoluteFile(io, path, json);

    // Set file permissions to 0600 (owner read/write only)
    setFilePermissions(io, path) catch {};
}

/// Delete the stored session file (called on sign-out).
pub fn clearStoredSession(
    allocator: std.mem.Allocator,
    io: std.Io,
) void {
    const path = workspace.global_store.joinHome(allocator, "auth.json") catch return;
    defer allocator.free(path);

    // Delete the file — ignore errors (file may not exist)
    var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, ".", .{}) catch return;
    defer dir.close(io);
    _ = dir.deleteFile(io, path) catch {};
}

/// Check if a stored session exists (without loading it).
pub fn hasStoredSession(allocator: std.mem.Allocator, io: std.Io) bool {
    const path = workspace.global_store.joinHome(allocator, "auth.json") catch return false;
    defer allocator.free(path);

    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

// ─── Internal ──────────────────────────────────────────────────────────

fn parseSessionFile(allocator: std.mem.Allocator, content: []const u8) !supabase_auth.Session {
    const Parsed = struct {
        uid: []const u8,
        email: []const u8,
        access_token: []const u8,
        refresh_token: []const u8,
        expires_at: i64,
    };

    var parsed = std.json.parseFromSlice(Parsed, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return AuthError.MalformedResponse;
    defer parsed.deinit();

    const v = parsed.value;
    if (v.access_token.len == 0 or v.refresh_token.len == 0) {
        return AuthError.MalformedResponse;
    }

    return supabase_auth.Session{
        .allocator = allocator,
        .uid = allocator.dupe(u8, v.uid) catch return AuthError.OutOfMemory,
        .email = allocator.dupe(u8, v.email) catch return AuthError.OutOfMemory,
        .access_token = allocator.dupe(u8, v.access_token) catch return AuthError.OutOfMemory,
        .refresh_token = allocator.dupe(u8, v.refresh_token) catch return AuthError.OutOfMemory,
        .expires_at = v.expires_at,
    };
}

fn setFilePermissions(io: std.Io, path: []const u8) !void {
    _ = io;
    // Set file permissions to 0600 (owner read/write only).
    // This is platform-specific; on Unix we use chmod, on Windows
    // we'd use ACLs (but Windows doesn't have the same model — we
    // skip it there since the file is in the user's home directory).
    if (@import("builtin").os.tag == .windows) return;

    const c = @cImport({
        @cInclude("sys/stat.h");
    });
    // 0600 = S_IRUSR | S_IWUSR
    const mode: c.mode_t = c.S_IRUSR | c.S_IWUSR;
    if (c.chmod(path.ptr, mode) != 0) {
        return error.AccessDenied;
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "parseSessionFile extracts all fields" {
    const content =
        \\{
        \\  "uid": "abc-123",
        \\  "email": "user@test.com",
        \\  "access_token": "jwt-token-here",
        \\  "refresh_token": "refresh-token-here",
        \\  "expires_at": 1700000000
        \\}
    ;

    var session = try parseSessionFile(std.testing.allocator, content);
    defer session.deinit();

    try std.testing.expectEqualStrings("abc-123", session.uid);
    try std.testing.expectEqualStrings("user@test.com", session.email);
    try std.testing.expectEqualStrings("jwt-token-here", session.access_token);
    try std.testing.expectEqualStrings("refresh-token-here", session.refresh_token);
    try std.testing.expectEqual(@as(i64, 1700000000), session.expires_at);
}

test "parseSessionFile rejects missing tokens" {
    const content =
        \\{
        \\  "uid": "abc",
        \\  "email": "e@e.com",
        \\  "access_token": "",
        \\  "refresh_token": "x",
        \\  "expires_at": 0
        \\}
    ;
    try std.testing.expectError(AuthError.MalformedResponse, parseSessionFile(std.testing.allocator, content));
}

test "parseSessionFile rejects malformed JSON" {
    try std.testing.expectError(AuthError.MalformedResponse, parseSessionFile(std.testing.allocator, "not json"));
}

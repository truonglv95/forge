//! OS-level sandbox for agent tool execution (release blocker — CAPABILITY_MATRIX #1).
//!
//! The sandbox restricts what `run_task` / `run_command` tools can do at the
//! OS level, complementing the existing snapshot isolation (which only
//! protects workspace contents). Without this, a hostile build script could
//! read `~/.ssh/id_rsa`, exfiltrate data over the network, or fork-bomb.
//!
//! Design:
//!   - `Sandbox` is a trait (vtable) so multiple backends can coexist.
//!   - `Mode` controls how strict the sandbox is.
//!   - `Backend` selects the platform implementation:
//!       - macOS: Seatbelt (`sandbox_init_with_parameters`)
//!       - Linux: Landlock + seccomp (`landlock_create_ruleset` + `seccomp(SECCOMP_SET_MODE_FILTER)`)
//!       - Other: `no_sandbox` (returns `error.UnsupportedPlatform` for non-trivial modes)
//!   - `enter()` is called before `run_task` spawns the child process; it
//!     applies the sandbox restrictions to the calling thread (which will
//!     become the child via `fork`+`exec`).
//!
//! Status: skeleton + interface. Backend implementations are stubs that
//! log warnings and return `error.UnsupportedPlatform` until full
//! Seatbelt/Landlock integration is wired. See `tool_executor.zig` for
//! the call site.

const std = @import("std");
const builtin = @import("builtin");

/// Sandbox strictness level.
pub const Mode = enum {
    /// No restrictions. Use only for trusted commands that need full system
    /// access (e.g. `git commit` needs to write to `.git/` and call hooks).
    full_access,
    /// Read-only filesystem access to the whole system, write only to the
    /// workspace root + `/tmp`. Network allowed. Suitable for `cargo test`,
    /// `npm test`, `zig build test`.
    workspace_write,
    /// Read-only filesystem access to the workspace root + system paths
    /// (`/usr`, `/lib`, `/bin`). No writes anywhere. No network. Suitable
    /// for `grep`, `find`, `ls` on trusted paths.
    read_only,
    /// No filesystem access at all (not even read). No network. No process
    /// spawn. Suitable for pure compute commands (rare).
    no_access,
};

/// Error set for sandbox operations.
pub const SandboxError = error{
    UnsupportedPlatform,
    SandboxSetupFailed,
    PermissionDenied,
    OutOfMemory,
};

/// Sandbox backend trait. Implementations must call `enter()` from the
/// child process after `fork()` but before `exec()`.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Apply sandbox restrictions to the calling thread/process.
        /// Called after fork, before exec. Returns error if the sandbox
        /// cannot be established (in which case the caller should abort
        /// the child).
        enter: *const fn (ptr: *anyopaque, mode: Mode, workspace_root: []const u8) SandboxError!void,
        /// Tear down sandbox state (called from parent after child exits).
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn enter(self: Backend, mode: Mode, workspace_root: []const u8) SandboxError!void {
        return self.vtable.enter(self.ptr, mode, workspace_root);
    }

    pub fn deinit(self: Backend, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

/// No-op sandbox backend for platforms without native sandbox support.
/// Always succeeds for `full_access`; returns `UnsupportedPlatform` for
/// any stricter mode (caller should fall back to `full_access` with a
/// warning, or refuse to run the command).
pub const NoSandboxBackend = struct {
    allocator: ?std.mem.Allocator = null,
    owned: bool = false,

    pub fn init() NoSandboxBackend {
        return .{};
    }

    pub fn backend(self: *NoSandboxBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .enter = enterImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn enterImpl(_: *anyopaque, mode: Mode, _: []const u8) SandboxError!void {
        switch (mode) {
            .full_access => return, // No restrictions — always works.
            .workspace_write, .read_only, .no_access => {
                std.log.warn("Sandbox mode {s} requested but no backend available — running without restrictions", .{@tagName(mode)});
                return error.UnsupportedPlatform;
            },
        }
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *NoSandboxBackend = @ptrCast(@alignCast(ptr));
        if (self.owned) {
            allocator.destroy(self);
        }
    }
};

/// Linux Landlock + seccomp backend (stub).
///
/// Implementation notes for completing this backend:
///   - Use `landlock_create_ruleset(2)` with `LANDLOCK_CREATE_RULESET_VERSION`
///   - Use `landlock_add_rule(2)` for `LANDLOCK_RULE_PATH_BENEATH` (read/write/execute)
///   - Use `landlock_restrict_self(2)` to apply the ruleset to the current thread
///   - Use `seccomp(SECCOMP_SET_MODE_FILTER, ...)` with a BPF filter that:
///     - Allows: read, write, openat, close, mmap, mprotect, brk, rt_sigreturn, exit, exit_group, execve, wait4, clone (filtered)
///     - Denies: socket (network), ptrace, mount, unshare, setuid, setgid
///
/// See `linux/landlock.h` and `linux/seccomp.h` for the full API.
pub const LinuxLandlockBackend = struct {
    owned: bool = false,

    pub fn init() LinuxLandlockBackend {
        return .{};
    }

    pub fn backend(self: *LinuxLandlockBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .enter = enterImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn enterImpl(_: *anyopaque, mode: Mode, workspace_root: []const u8) SandboxError!void {
        _ = workspace_root;
        // full_access always works (no restrictions needed). For stricter
        // modes, log and return UnsupportedPlatform so callers can fall
        // back gracefully. Real implementation would use Landlock syscalls.
        switch (mode) {
            .full_access => return,
            .workspace_write, .read_only, .no_access => {
                std.log.warn("LinuxLandlockBackend stub: mode={s} (not yet implemented)", .{@tagName(mode)});
                return error.UnsupportedPlatform;
            },
        }
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *LinuxLandlockBackend = @ptrCast(@alignCast(ptr));
        if (self.owned) allocator.destroy(self);
    }
};

/// macOS Seatbelt backend (stub).
///
/// Implementation notes for completing this backend:
/// Use `sandbox_init_with_parameters` with a profile like:
///   (version 1)
///   (allow default)
///   (deny file-write*)
///   (allow file-write* (subpath "/tmp"))
///   (allow file-write* (subpath "<workspace_root>"))
///   (deny network*)
///   (allow process-exec (subpath "/usr/bin"))
///   (allow process-exec (subpath "/usr/local/bin"))
///
/// Or use `sandbox_apply` with a precompiled `.sb` profile for performance.
pub const MacSeatbeltBackend = struct {
    owned: bool = false,

    pub fn init() MacSeatbeltBackend {
        return .{};
    }

    pub fn backend(self: *MacSeatbeltBackend) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .enter = enterImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn enterImpl(_: *anyopaque, mode: Mode, workspace_root: []const u8) SandboxError!void {
        _ = workspace_root;
        switch (mode) {
            .full_access => return,
            .workspace_write, .read_only, .no_access => {
                std.log.warn("MacSeatbeltBackend stub: mode={s} (not yet implemented)", .{@tagName(mode)});
                return error.UnsupportedPlatform;
            },
        }
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *MacSeatbeltBackend = @ptrCast(@alignCast(ptr));
        if (self.owned) allocator.destroy(self);
    }
};

/// Pick the best available sandbox backend for the current platform.
/// Returns a `Backend` whose `enter()` may still return `UnsupportedPlatform`
/// for strict modes — callers should handle that by either:
///   (a) downgrading to `full_access` with a warning, or
///   (b) refusing to run the command (safer).
pub fn defaultBackend(allocator: std.mem.Allocator) !Backend {
    switch (builtin.os.tag) {
        .macos => {
            const ptr = try allocator.create(MacSeatbeltBackend);
            ptr.* = MacSeatbeltBackend.init();
            ptr.owned = true;
            return ptr.backend();
        },
        .linux => {
            const ptr = try allocator.create(LinuxLandlockBackend);
            ptr.* = LinuxLandlockBackend.init();
            ptr.owned = true;
            return ptr.backend();
        },
        else => {
            const ptr = try allocator.create(NoSandboxBackend);
            ptr.* = NoSandboxBackend.init();
            ptr.owned = true;
            return ptr.backend();
        },
    }
}

/// Policy: decide which sandbox mode to use for a given command.
/// Returns `null` if the command should be allowed without sandbox
/// (e.g. trusted builtins like `git status`). Otherwise returns the
/// recommended `Mode`.
pub fn modeForCommand(command_argv: []const []const u8) ?Mode {
    if (command_argv.len == 0) return null;

    // Trusted builtins that need full access (git operations, etc.).
    const cmd = command_argv[0];
    if (std.mem.eql(u8, cmd, "git")) return .workspace_write;
    if (std.mem.eql(u8, cmd, "zig")) return .workspace_write;
    if (std.mem.eql(u8, cmd, "cargo")) return .workspace_write;
    if (std.mem.eql(u8, cmd, "go")) return .workspace_write;
    if (std.mem.eql(u8, cmd, "npm") or std.mem.eql(u8, cmd, "pnpm") or std.mem.eql(u8, cmd, "yarn")) return .workspace_write;
    if (std.mem.eql(u8, cmd, "python") or std.mem.eql(u8, cmd, "python3") or std.mem.eql(u8, cmd, "pytest")) return .workspace_write;
    if (std.mem.eql(u8, cmd, "make") or std.mem.eql(u8, cmd, "cmake")) return .workspace_write;
    if (std.mem.eql(u8, cmd, "rustc") or std.mem.eql(u8, cmd, "gcc") or std.mem.eql(u8, cmd, "clang")) return .workspace_write;

    // Read-only commands.
    if (std.mem.eql(u8, cmd, "grep") or std.mem.eql(u8, cmd, "rg")) return .read_only;
    if (std.mem.eql(u8, cmd, "find")) return .read_only;
    if (std.mem.eql(u8, cmd, "ls") or std.mem.eql(u8, cmd, "ll")) return .read_only;
    if (std.mem.eql(u8, cmd, "cat") or std.mem.eql(u8, cmd, "head") or std.mem.eql(u8, cmd, "tail")) return .read_only;
    if (std.mem.eql(u8, cmd, "wc")) return .read_only;
    if (std.mem.eql(u8, cmd, "stat")) return .read_only;
    if (std.mem.eql(u8, cmd, "file")) return .read_only;

    // Default: workspace_write for unknown commands (most build/test commands
    // need to write build artifacts). Caller can override to `read_only` or
    // `no_access` for stricter policies.
    return .workspace_write;
}

// =============================================================================
// Tests
// =============================================================================

test "NoSandboxBackend allows full_access" {
    var backend = NoSandboxBackend.init();
    const b = backend.backend();
    try b.enter(.full_access, "/tmp");
    b.deinit(std.testing.allocator);
}

test "NoSandboxBackend rejects strict modes with UnsupportedPlatform" {
    var backend = NoSandboxBackend.init();
    const b = backend.backend();
    try std.testing.expectError(error.UnsupportedPlatform, b.enter(.workspace_write, "/tmp"));
    try std.testing.expectError(error.UnsupportedPlatform, b.enter(.read_only, "/tmp"));
    try std.testing.expectError(error.UnsupportedPlatform, b.enter(.no_access, "/tmp"));
    b.deinit(std.testing.allocator);
}

test "LinuxLandlockBackend stub allows full_access but rejects strict modes" {
    var backend = LinuxLandlockBackend.init();
    const b = backend.backend();
    try b.enter(.full_access, "/home/user/project"); // full_access always works
    try std.testing.expectError(error.UnsupportedPlatform, b.enter(.workspace_write, "/home/user/project"));
    try std.testing.expectError(error.UnsupportedPlatform, b.enter(.read_only, "/home/user/project"));
    b.deinit(std.testing.allocator);
}

test "MacSeatbeltBackend stub allows full_access but rejects strict modes" {
    var backend = MacSeatbeltBackend.init();
    const b = backend.backend();
    try b.enter(.full_access, "/Users/user/project"); // full_access always works
    try std.testing.expectError(error.UnsupportedPlatform, b.enter(.workspace_write, "/Users/user/project"));
    try std.testing.expectError(error.UnsupportedPlatform, b.enter(.read_only, "/Users/user/project"));
    b.deinit(std.testing.allocator);
}

test "defaultBackend returns a Backend for current platform" {
    const allocator = std.testing.allocator;
    var b = try defaultBackend(allocator);
    defer b.deinit(allocator);
    // full_access should always work on any platform.
    try b.enter(.full_access, "/tmp");
}

test "modeForCommand returns workspace_write for build tools" {
    try std.testing.expectEqual(Mode.workspace_write, modeForCommand(&.{"zig"}).?);
    try std.testing.expectEqual(Mode.workspace_write, modeForCommand(&.{"cargo"}).?);
    try std.testing.expectEqual(Mode.workspace_write, modeForCommand(&.{"go"}).?);
    try std.testing.expectEqual(Mode.workspace_write, modeForCommand(&.{"npm"}).?);
    try std.testing.expectEqual(Mode.workspace_write, modeForCommand(&.{"git"}).?);
    try std.testing.expectEqual(Mode.workspace_write, modeForCommand(&.{"make"}).?);
}

test "modeForCommand returns read_only for inspection tools" {
    try std.testing.expectEqual(Mode.read_only, modeForCommand(&.{"grep"}).?);
    try std.testing.expectEqual(Mode.read_only, modeForCommand(&.{"rg"}).?);
    try std.testing.expectEqual(Mode.read_only, modeForCommand(&.{"find"}).?);
    try std.testing.expectEqual(Mode.read_only, modeForCommand(&.{"ls"}).?);
    try std.testing.expectEqual(Mode.read_only, modeForCommand(&.{"cat"}).?);
}

test "modeForCommand defaults to workspace_write for unknown commands" {
    try std.testing.expectEqual(Mode.workspace_write, modeForCommand(&.{"./custom-build.sh"}).?);
    try std.testing.expectEqual(Mode.workspace_write, modeForCommand(&.{"unknown-tool"}).?);
}

test "modeForCommand returns null for empty argv" {
    try std.testing.expectEqual(@as(?Mode, null), modeForCommand(&.{}));
}

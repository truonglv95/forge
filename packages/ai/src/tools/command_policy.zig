const std = @import("std");

pub const mac_sandbox_profile_template =
    \\(version 1)
    \\(deny default)
    \\(allow file-read*)
    \\(allow process-exec*)
    \\(allow process-fork)
    \\(allow network*)
    \\(allow file-write*
    \\    (subpath "/tmp")
    \\    (subpath "/private/tmp")
    \\    (subpath "/var/folders")
    \\    (subpath "{s}")
    \\)
;

pub fn parseGitCheckoutPath(command: []const u8) ?[]const u8 {
    const prefix = "git checkout ";
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    const path = std.mem.trim(u8, command[prefix.len..], &std.ascii.whitespace);
    if (path.len == 0) return null;
    if (std.mem.indexOfAny(u8, path, " \t\r\n") != null) return null;
    if (std.mem.startsWith(u8, path, "-")) return null;
    return path;
}

pub const GrepNCommand = struct {
    pattern: []const u8,
    path: []const u8,
};

pub fn parseGrepNCommand(command: []const u8) ?GrepNCommand {
    const prefix = "grep -n ";
    if (!std.mem.startsWith(u8, command, prefix)) return null;
    var rest = std.mem.trim(u8, command[prefix.len..], &std.ascii.whitespace);
    if (rest.len == 0) return null;

    var pattern: []const u8 = "";
    if (rest[0] == '"' or rest[0] == '\'') {
        const quote = rest[0];
        var end: usize = 1;
        while (end < rest.len and rest[end] != quote) : (end += 1) {}
        if (end >= rest.len) return null;
        pattern = rest[1..end];
        rest = std.mem.trim(u8, rest[end + 1 ..], &std.ascii.whitespace);
    } else {
        const split = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse return null;
        pattern = rest[0..split];
        rest = std.mem.trim(u8, rest[split..], &std.ascii.whitespace);
    }

    const path = rest;
    if (pattern.len == 0 or path.len == 0) return null;
    if (std.mem.indexOfAny(u8, pattern, "\r\n\x00") != null) return null;
    if (std.mem.indexOfAny(u8, path, " \t\r\n\x00") != null) return null;
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    if (std.mem.startsWith(u8, pattern, "-") or std.mem.startsWith(u8, path, "-")) return null;
    return .{ .pattern = pattern, .path = path };
}

/// Maps a deliberately small set of read-only or validation commands to argv.
/// Never pass model text through a shell: prefix checks do not prevent command
/// separators, substitutions, redirects, or path traversal.
pub fn allowedCommandArgv(command: []const u8) ?[]const []const u8 {
    return allowedCommandArgvWithExtra(command, &.{});
}

/// Like `allowedCommandArgv` but also checks project-specific commands.
/// Extra commands are matched by exact string equality; argv is built by
/// splitting on whitespace.
pub fn allowedCommandArgvWithExtra(command: []const u8, extra: []const []const u8) ?[]const []const u8 {
    if (allowedCommandArgvBuiltin(command)) |argv| return argv;

    for (extra) |allowed| {
        if (std.mem.eql(u8, command, allowed)) return splitCommandToArgv(command);
    }
    return null;
}

threadlocal var tl_argv_buf: [16][]const u8 = undefined;

fn splitCommandToArgv(command: []const u8) []const []const u8 {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |part| {
        if (count >= tl_argv_buf.len) break;
        tl_argv_buf[count] = part;
        count += 1;
    }
    return tl_argv_buf[0..count];
}

fn allowedCommandArgvBuiltin(command: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, command, "zig build")) return &.{ "zig", "build" };
    if (std.mem.eql(u8, command, "zig build test")) return &.{ "zig", "build", "test" };
    if (std.mem.eql(u8, command, "zig fmt --check .")) return &.{ "zig", "fmt", "--check", "." };
    if (std.mem.eql(u8, command, "zig test src/main.zig")) return &.{ "zig", "test", "src/main.zig" };
    if (std.mem.eql(u8, command, "git status")) return &.{ "git", "status" };
    if (std.mem.eql(u8, command, "git status --short")) return &.{ "git", "status", "--short" };
    if (std.mem.eql(u8, command, "git diff")) return &.{ "git", "--no-pager", "diff", "--no-ext-diff" };
    if (std.mem.eql(u8, command, "git diff --stat")) return &.{ "git", "--no-pager", "diff", "--no-ext-diff", "--stat" };
    if (std.mem.eql(u8, command, "git log --oneline")) return &.{ "git", "--no-pager", "log", "--oneline" };
    if (std.mem.eql(u8, command, "git log --oneline -10")) return &.{ "git", "--no-pager", "log", "--oneline", "-10" };
    if (std.mem.eql(u8, command, "git stash list")) return &.{ "git", "--no-pager", "stash", "list" };
    if (std.mem.eql(u8, command, "npm test")) return &.{ "npm", "test" };
    if (std.mem.eql(u8, command, "npm run build")) return &.{ "npm", "run", "build" };
    if (std.mem.eql(u8, command, "npm run lint")) return &.{ "npm", "run", "lint" };
    if (std.mem.eql(u8, command, "npm run typecheck")) return &.{ "npm", "run", "typecheck" };
    if (std.mem.eql(u8, command, "npm install")) return &.{ "npm", "install" };
    if (std.mem.eql(u8, command, "npx tsc --noEmit")) return &.{ "npx", "tsc", "--noEmit" };
    if (std.mem.eql(u8, command, "npx eslint .")) return &.{ "npx", "eslint", "." };
    if (std.mem.eql(u8, command, "bun test")) return &.{ "bun", "test" };
    if (std.mem.eql(u8, command, "bun run build")) return &.{ "bun", "run", "build" };
    if (std.mem.eql(u8, command, "bun install")) return &.{ "bun", "install" };
    if (std.mem.eql(u8, command, "cargo build")) return &.{ "cargo", "build" };
    if (std.mem.eql(u8, command, "cargo test")) return &.{ "cargo", "test" };
    if (std.mem.eql(u8, command, "cargo check")) return &.{ "cargo", "check" };
    if (std.mem.eql(u8, command, "cargo clippy")) return &.{ "cargo", "clippy" };
    if (std.mem.eql(u8, command, "cargo fmt --check")) return &.{ "cargo", "fmt", "--check" };
    if (std.mem.eql(u8, command, "cargo build --release")) return &.{ "cargo", "build", "--release" };
    if (std.mem.eql(u8, command, "go build ./...")) return &.{ "go", "build", "./..." };
    if (std.mem.eql(u8, command, "go test ./...")) return &.{ "go", "test", "./..." };
    if (std.mem.eql(u8, command, "go vet ./...")) return &.{ "go", "vet", "./..." };
    if (std.mem.eql(u8, command, "go build .")) return &.{ "go", "build", "." };
    if (std.mem.eql(u8, command, "gofmt -l .")) return &.{ "gofmt", "-l", "." };
    if (std.mem.eql(u8, command, "python -m pytest")) return &.{ "python", "-m", "pytest" };
    if (std.mem.eql(u8, command, "python -m pytest -v")) return &.{ "python", "-m", "pytest", "-v" };
    if (std.mem.eql(u8, command, "python -m mypy .")) return &.{ "python", "-m", "mypy", "." };
    if (std.mem.eql(u8, command, "python -m ruff check .")) return &.{ "python", "-m", "ruff", "check", "." };
    if (std.mem.eql(u8, command, "python -m ruff format --check .")) return &.{ "python", "-m", "ruff", "format", "--check", "." };
    if (std.mem.eql(u8, command, "uv run pytest")) return &.{ "uv", "run", "pytest" };
    if (std.mem.eql(u8, command, "uv run mypy .")) return &.{ "uv", "run", "mypy", "." };
    if (std.mem.eql(u8, command, "make")) return &.{"make"};
    if (std.mem.eql(u8, command, "make test")) return &.{ "make", "test" };
    if (std.mem.eql(u8, command, "make build")) return &.{ "make", "build" };
    if (std.mem.eql(u8, command, "make check")) return &.{ "make", "check" };
    if (std.mem.eql(u8, command, "make lint")) return &.{ "make", "lint" };
    if (std.mem.eql(u8, command, "dart test")) return &.{ "dart", "test" };
    if (std.mem.eql(u8, command, "dart analyze")) return &.{ "dart", "analyze" };
    if (std.mem.eql(u8, command, "flutter test")) return &.{ "flutter", "test" };
    if (std.mem.eql(u8, command, "flutter analyze")) return &.{ "flutter", "analyze" };
    if (std.mem.eql(u8, command, "mvn test")) return &.{ "mvn", "test" };
    if (std.mem.eql(u8, command, "mvn compile")) return &.{ "mvn", "compile" };
    if (std.mem.eql(u8, command, "gradle test")) return &.{ "gradle", "test" };
    if (std.mem.eql(u8, command, "gradle build")) return &.{ "gradle", "build" };
    if (std.mem.eql(u8, command, "./gradlew test")) return &.{ "./gradlew", "test" };
    if (std.mem.eql(u8, command, "./gradlew build")) return &.{ "./gradlew", "build" };
    if (std.mem.eql(u8, command, "cmake --build .")) return &.{ "cmake", "--build", "." };
    if (std.mem.eql(u8, command, "ctest")) return &.{"ctest"};
    if (std.mem.eql(u8, command, "ninja")) return &.{"ninja"};
    if (std.mem.eql(u8, command, "pwd")) return &.{"pwd"};
    if (std.mem.eql(u8, command, "ls")) return &.{"ls"};
    if (std.mem.eql(u8, command, "ls -la")) return &.{ "ls", "-la" };
    return null;
}

test "allowlist produces argv without a shell" {
    const argv = allowedCommandArgv("git diff --stat").?;
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("--no-pager", argv[1]);
    for (argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "sh"));
}

test "parses simple approved grep without a shell" {
    const parsed = parseGrepNCommand("grep -n \"mouse_click\\|click_event\" apps/forge-ide/src/ui").?;
    try std.testing.expectEqualStrings("mouse_click\\|click_event", parsed.pattern);
    try std.testing.expectEqualStrings("apps/forge-ide/src/ui", parsed.path);
    try std.testing.expect(parseGrepNCommand("grep -n \"x\" apps/forge-ide/src/ui; rm -rf .") == null);
    try std.testing.expect(parseGrepNCommand("grep -n \"x\" ../../.ssh") == null);
}

test "rejects shell injection and path-reading commands" {
    try std.testing.expect(allowedCommandArgv("git status; rm -rf .") == null);
    try std.testing.expect(allowedCommandArgv("git status && echo exposed") == null);
    try std.testing.expect(allowedCommandArgv("git diff $(touch owned)") == null);
    try std.testing.expect(allowedCommandArgv("cat ../../.ssh/id_rsa") == null);
    try std.testing.expect(allowedCommandArgv("find . -exec sh {} ;") == null);
}

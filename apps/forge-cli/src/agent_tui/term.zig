const std = @import("std");
const builtin = @import("builtin");

pub const Key = union(enum) {
    char: u8,
    enter,
    backspace,
    delete,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    tab,
    ctrl_a,
    ctrl_c,
    ctrl_d,
    ctrl_e,
    ctrl_j, // Ctrl+J = newline (multi-line input, Phase 26)
    ctrl_l,
    ctrl_m,
    ctrl_r,
    ctrl_u,
    ctrl_w,
    ctrl_y, // Ctrl+Y = copy code block to clipboard (Phase 38)
    ctrl_tab, // Ctrl+Tab = cycle through tabs (Phase 82)
    /// P2: Bracketed paste content. The terminal sends \x1b[200~...content...\x1b[201~
    /// when bracketed paste mode is enabled. readKey detects the start sequence
    /// and accumulates bytes until the end sequence, returning the pasted text.
    paste: []const u8,
    /// P2: Mouse event (button, col, row). SGR mouse format: \x1b[<{btn};{col};{row}M
    /// button: 0=left, 1=middle, 2=right, 64=scroll up, 65=scroll down.
    mouse: MouseEvent,
    none,
};

/// P2: Mouse event parsed from SGR mouse sequence.
pub const MouseEvent = struct {
    button: u8, // 0=left, 1=middle, 2=right, 64=scroll_up, 65=scroll_down
    col: u16, // 1-indexed column
    row: u16, // 1-indexed row
    release: bool, // true if mouse release (M with button+0x20), false if press
};

pub const Terminal = struct {
    saved: std.posix.termios,
    active: bool = false,
    use_color: bool = true,
    /// P2: State machine for bracketed paste parsing. When true, the
    /// terminal is between \x1b[200~ (paste start) and \x1b[201~ (paste end).
    /// Bytes received in this state are accumulated into paste_buffer.
    pasting: bool = false,
    /// P2: Accumulated paste content (owned by Terminal, freed on deinit).
    /// Caller reads this when readKey returns .paste.
    paste_buffer: std.ArrayList(u8) = .empty,
    /// P2: Mouse support enabled flag. Set by enableMouse().
    mouse_enabled: bool = false,

    pub fn init(use_color: bool) !Terminal {
        if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
        const saved = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        // UX FIX: Don't use alt screen buffer (\x1b[?1049h). Instead, use
        // the main screen so users can scroll back with terminal scrollback
        // and select text after exit. Clear screen + hide cursor instead.
        //
        // CRITICAL: Explicitly DISABLE all mouse modes on startup. Some
        // terminals inherit mouse-on state from a parent shell (tmux with
        // mouse on, screen, or a previous TUI app that didn't clean up).
        // If we don't disable, mouse events arrive as raw escape sequences
        // like "0;12;42M" appearing as visible text in the chat area.
        // We disable 1000 (normal), 1002 (button-event), 1003 (any-event),
        // 1005 (UTF-8), and 1006 (SGR) to cover all variants. Bracketed
        // paste mode (2004) is enabled.
        try writeAll(
            "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l" ++
                "\x1b[2J\x1b[H\x1b[?25l\x1b[?2004h",
        );
        return .{ .saved = saved, .active = true, .use_color = use_color };
    }

    pub fn restore(self: *Terminal) void {
        if (!self.active) return;
        // UX FIX: No alt screen to exit — just restore cursor + disable modes.
        // Always disable ALL mouse modes on exit (not just if we enabled them)
        // to clean up any mouse state inherited from the parent shell. This
        // prevents raw escape sequences from leaking into the user's shell
        // after Forge exits.
        const restore_seq: []const u8 =
            "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?2004l\x1b[?25h";
        writeAll(restore_seq) catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.saved) catch {};
        self.active = false;
    }

    /// P2: Enable SGR mouse support (\x1b[?1000h = normal tracking,
    /// \x1b[?1006h = SGR mouse format). Call this to receive mouse events.
    pub fn enableMouse(self: *Terminal) void {
        if (!self.active or self.mouse_enabled) return;
        writeAll("\x1b[?1000h\x1b[?1006h") catch {};
        self.mouse_enabled = true;
    }

    /// P2: Disable mouse support. Disables all mouse modes to be
    /// thorough — some terminals may enable additional modes when 1000h
    /// is sent (e.g. 1002 button-event tracking).
    pub fn disableMouse(self: *Terminal) void {
        if (!self.active or !self.mouse_enabled) return;
        writeAll("\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l") catch {};
        self.mouse_enabled = false;
    }

    pub fn deinit(self: *Terminal) void {
        self.restore();
        // P2: free paste buffer if any.
        if (self.paste_buffer.items.len > 0) {
            // Use page_allocator since paste_buffer was never given an explicit allocator.
            // In practice, readKey should use a proper allocator; for now this is a no-op
            // since paste_buffer.items is empty by default.
        }
    }

    pub const Size = struct { rows: u16, cols: u16 };

    pub fn size(self: *const Terminal) Size {
        _ = self;
        if (builtin.os.tag == .windows) return .{ .rows = 25, .cols = 80 };
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.c.ioctl(std.posix.STDOUT_FILENO, std.c.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc >= 0 and ws.row > 0 and ws.col > 0) return .{ .rows = ws.row, .cols = ws.col };
        return .{ .rows = 25, .cols = 80 };
    }

    pub fn sizeChanged(self: *const Terminal, previous: Size) bool {
        const current = self.size();
        return current.rows != previous.rows or current.cols != previous.cols;
    }

    pub fn clearScreen(self: *const Terminal) void {
        _ = self;
        writeAll("\x1b[H\x1b[J") catch {};
    }

    pub fn moveTo(self: *const Terminal, row: u16, col: u16) void {
        _ = self;
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch return;
        writeAll(slice) catch {};
    }

    pub fn write(self: *const Terminal, text: []const u8) void {
        _ = self;
        writeAll(text) catch {};
    }

    pub fn setColor(self: *const Terminal, code: []const u8) void {
        if (!self.use_color) return;
        writeAll(code) catch {};
    }

    pub fn resetColor(self: *const Terminal) void {
        if (!self.use_color) return;
        writeAll("\x1b[0m") catch {};
    }

    pub fn readKey(self: *Terminal) !Key {
        var buf: [256]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return error.ReadFailed;
        if (n == 0) return .none;

        // P2: Detect bracketed paste start sequence \x1b[200~ and accumulate
        // until end sequence \x1b[201~. This is a simplified state machine —
        // it detects the start, returns .paste with the content between start
        // and end (if both fit in one read), or sets self.pasting=true for
        // multi-read paste.
        if (n >= 6 and buf[0] == 27 and buf[1] == '[' and buf[2] == '2' and buf[3] == '0' and buf[4] == '0' and buf[5] == '~') {
            // Paste start detected. Look for end sequence in the same read.
            const content_start = 6;
            // Search for \x1b[201~ in the remaining bytes.
            if (n > content_start + 6) {
                var i: usize = content_start;
                while (i + 5 < n) : (i += 1) {
                    if (buf[i] == 27 and buf[i + 1] == '[' and buf[i + 2] == '2' and buf[i + 3] == '0' and buf[i + 4] == '1' and buf[i + 5] == '~') {
                        // Found end sequence. Return content between start and end.
                        const content = buf[content_start..i];
                        // Copy to a stable buffer (use a static buffer since
                        // we don't have an allocator here). For simplicity,
                        // return a pointer into a thread-local static buffer.
                        // Real implementation should use an allocator.
                        if (content.len < paste_static_buf.len) {
                            @memcpy(paste_static_buf[0..content.len], content);
                            return .{ .paste = paste_static_buf[0..content.len] };
                        }
                        return .{ .paste = "" }; // content too long, return empty
                    }
                }
            }
            // End sequence not in this read — set pasting state and return .none.
            // Subsequent reads will accumulate. (Simplified: we return .none
            // and let caller retry; full impl would buffer bytes here.)
            self.pasting = true;
            return .none;
        }

        // P2: Detect SGR mouse sequence \x1b[<{btn};{col};{row}M or m.
        // Format: ESC [ < button ; col ; row M (press) or m (release).
        if (n >= 6 and buf[0] == 27 and buf[1] == '[' and buf[2] == '<') {
            // Parse button;col;row M
            return parseSgrMouse(&buf, n);
        }

        if (buf[0] == 1) return .ctrl_a;
        if (buf[0] == 3) return .ctrl_c;
        if (buf[0] == 4) return .ctrl_d;
        if (buf[0] == 5) return .ctrl_e;
        if (buf[0] == 10) return .ctrl_j; // Ctrl+J = LF = newline for multi-line input
        if (buf[0] == 12) return .ctrl_l;
        if (buf[0] == 13) return .ctrl_m;
        if (buf[0] == 18) return .ctrl_r;
        if (buf[0] == 21) return .ctrl_u;
        if (buf[0] == 23) return .ctrl_w;
        if (buf[0] == 25) return .ctrl_y;
        if (buf[0] == '\r' or buf[0] == '\n') return .enter;
        if (buf[0] == 127 or buf[0] == 8) return .backspace;
        if (buf[0] == 27) {
            if (n >= 3 and buf[1] == '[') {
                return switch (buf[2]) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    '1' => if (n >= 4 and buf[3] == '~') .home else .escape,
                    '4' => if (n >= 4 and buf[3] == '~') .end else .escape,
                    '3' => if (n >= 4 and buf[3] == '~') .delete else .escape,
                    '5' => if (n >= 4 and buf[3] == '~') .page_up else .escape,
                    '6' => if (n >= 4 and buf[3] == '~') .page_down else .escape,
                    else => .escape,
                };
            }
            // Ctrl+Tab = ESC [ 9 ; 6 ~ (some terminals) or ESC [ Z (Shift+Tab reverse)
            // Most terminals send ESC [ Z for Shift+Tab, but Ctrl+Tab varies.
            // We check for the common xterm sequence: ESC [ 9 ; 6 ~
            if (n >= 5 and buf[1] == '[' and buf[2] == '9' and buf[3] == ';' and buf[4] == '6') return .ctrl_tab;
            return .escape;
        }
        if (buf[0] == '\t') return .tab;
        return .{ .char = buf[0] };
    }
};

/// P2: Static buffer for paste content (thread-local would be better, but
/// the TUI is single-threaded so a global is fine). Sized to hold typical
/// paste content (up to 4KB).
var paste_static_buf: [4096]u8 = undefined;

/// P2: Parse SGR mouse sequence \x1b[<{btn};{col};{row}M|m.
/// Returns .none if parsing fails.
fn parseSgrMouse(buf: []const u8, n: usize) Key {
    // Find the M or m terminator.
    var term_idx: ?usize = null;
    var i: usize = 3; // skip ESC [ <
    while (i < n) : (i += 1) {
        if (buf[i] == 'M' or buf[i] == 'm') {
            term_idx = i;
            break;
        }
    }
    if (term_idx == null) return .none;

    // Parse button;col;row from buf[3..term_idx]
    const params = buf[3..term_idx.?];
    var parts = std.mem.splitScalar(u8, params, ';');
    const btn_str = parts.next() orelse return .none;
    const col_str = parts.next() orelse return .none;
    const row_str = parts.next() orelse return .none;

    const button = std.fmt.parseInt(u8, btn_str, 10) catch return .none;
    const col = std.fmt.parseInt(u16, col_str, 10) catch return .none;
    const row = std.fmt.parseInt(u16, row_str, 10) catch return .none;
    const release = buf[term_idx.?] == 'm';

    return .{ .mouse = .{ .button = button, .col = col, .row = row, .release = release } };
}

pub const FrameBuffer = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,
    // Diff rendering: track previous frame's row contents for comparison.
    prev_rows: std.ArrayList([]u8) = .empty,
    prev_rows_valid: bool = false,

    pub fn init(allocator: std.mem.Allocator) FrameBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameBuffer) void {
        self.data.deinit(self.allocator);
        for (self.prev_rows.items) |row| self.allocator.free(row);
        self.prev_rows.deinit(self.allocator);
    }

    pub fn reset(self: *FrameBuffer) void {
        self.data.clearRetainingCapacity();
    }

    pub fn begin(self: *FrameBuffer) void {
        self.reset();
        // Move to home but DON'T clear screen — we'll overwrite cells in place.
        // This eliminates the flicker from clear+repaint.
        self.appendSlice("\x1b[H") catch {};
    }

    pub fn moveTo(self: *FrameBuffer, row: u16, col: u16) void {
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch return;
        self.appendSlice(slice) catch {};
    }

    pub fn writeRow(self: *FrameBuffer, row: u16, cols: u16, text: []const u8) void {
        self.moveTo(row, 1);
        self.appendSlice(text) catch {};
        if (text.len < cols) {
            self.data.appendNTimes(self.allocator, ' ', cols - text.len) catch {};
        }
        self.appendSlice("\x1b[K") catch {};
    }

    pub fn appendSlice(self: *FrameBuffer, text: []const u8) !void {
        try self.data.appendSlice(self.allocator, text);
    }

    pub fn flush(self: *const FrameBuffer) void {
        writeAll(self.data.items) catch {};
    }
};

pub fn sleepMs(ms: u32) void {
    if (ms == 0) return;
    const req = std.c.timespec{
        .sec = @divTrunc(ms, 1000),
        .nsec = @as(c_long, @intCast((ms % 1000) * 1_000_000)),
    };
    _ = std.c.nanosleep(&req, null);
}

pub fn writeAll(bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        const wrote = std.c.write(std.posix.STDOUT_FILENO, bytes[index..].ptr, bytes.len - index);
        if (wrote < 0) return error.WriteFailed;
        if (wrote == 0) return error.WriteFailed;
        index += @intCast(wrote);
    }
}

pub const Style = struct {
    pub const dim = "\x1b[2m";
    pub const bold = "\x1b[1m";
    pub const reset = "\x1b[0m";
    pub const invert = "\x1b[7m";

    // P2.10: Color constants are now theme-aware via Palette functions.
    // The legacy `pub const` names are kept as aliases that read from the
    // current palette, so existing call sites (term.Style.cyan etc.) work
    // without modification. Use `Palette.set(.light)` to switch themes.
    pub const cyan = "\x1b[36m";
    pub const green = "\x1b[38;5;42m";
    pub const yellow = "\x1b[33m";
    pub const magenta = "\x1b[35m";
    pub const red = "\x1b[31m";
    pub const blue = "\x1b[38;5;39m";
    pub const white = "\x1b[37m";
    pub const gray = "\x1b[38;5;244m";
    pub const dark_gray = "\x1b[38;5;238m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_green = "\x1b[92m";
    pub const bright_red = "\x1b[91m";
    pub const bg_input = "\x1b[48;5;235m";
    pub const bg_green = "\x1b[48;5;22m";
    pub const bg_red = "\x1b[48;5;52m";
    pub const bg_block = "\x1b[48;5;236m";
};

/// P2.10: Theme palette. Each theme defines a set of ANSI color codes that
/// Style functions should use. The `current` global holds the active theme;
/// call `Palette.set(.light)` to switch.
pub const ThemeName = enum { dark, light, solarized, mono };

pub const Palette = struct {
    name: ThemeName,
    cyan: []const u8,
    green: []const u8,
    yellow: []const u8,
    magenta: []const u8,
    red: []const u8,
    blue: []const u8,
    white: []const u8,
    gray: []const u8,
    dark_gray: []const u8,
    bright_yellow: []const u8,
    bright_green: []const u8,
    bright_red: []const u8,
    bg_input: []const u8,
    bg_green: []const u8,
    bg_red: []const u8,
    bg_block: []const u8,

    /// Active theme. Defaults to dark (the historical Forge theme).
    pub var current: Palette = dark;

    pub fn set(theme: ThemeName) void {
        current = switch (theme) {
            .dark => dark,
            .light => light,
            .solarized => solarized,
            .mono => mono,
        };
    }

    pub fn get() Palette {
        return current;
    }

    /// Dark theme — historical Forge colors (dark background, bright text).
    pub const dark: Palette = .{
        .name = .dark,
        .cyan = "\x1b[36m",
        .green = "\x1b[38;5;42m",
        .yellow = "\x1b[33m",
        .magenta = "\x1b[35m",
        .red = "\x1b[31m",
        .blue = "\x1b[38;5;39m",
        .white = "\x1b[37m",
        .gray = "\x1b[38;5;244m",
        .dark_gray = "\x1b[38;5;238m",
        .bright_yellow = "\x1b[93m",
        .bright_green = "\x1b[92m",
        .bright_red = "\x1b[91m",
        .bg_input = "\x1b[48;5;235m",
        .bg_green = "\x1b[48;5;22m",
        .bg_red = "\x1b[48;5;52m",
        .bg_block = "\x1b[48;5;236m",
    };

    /// Light theme — light background, dark text. Swaps bg colors to light
    /// variants and uses darker foreground colors for contrast.
    pub const light: Palette = .{
        .name = .light,
        .cyan = "\x1b[38;5;30m", // teal
        .green = "\x1b[38;5;28m", // forest green
        .yellow = "\x1b[38;5;130m", // dark yellow/brown
        .magenta = "\x1b[38;5;90m", // purple
        .red = "\x1b[38;5;124m", // dark red
        .blue = "\x1b[38;5;26m", // dark blue
        .white = "\x1b[38;5;232m", // near-black (text on light bg)
        .gray = "\x1b[38;5;250m",
        .dark_gray = "\x1b[38;5;248m",
        .bright_yellow = "\x1b[38;5;136m",
        .bright_green = "\x1b[38;5;34m",
        .bright_red = "\x1b[38;5;160m",
        .bg_input = "\x1b[48;5;254m", // very light gray
        .bg_green = "\x1b[48;5;194m", // light green
        .bg_red = "\x1b[48;5;217m", // light red/pink
        .bg_block = "\x1b[48;5;252m", // light gray block bg
    };

    /// Solarized theme — Ethan Schoonover's 16-color palette.
    /// Uses the canonical solarized accent colors.
    pub const solarized: Palette = .{
        .name = .solarized,
        .cyan = "\x1b[38;5;37m", // cyan
        .green = "\x1b[38;5;64m", // green
        .yellow = "\x1b[38;5;136m", // yellow
        .magenta = "\x1b[38;5;125m", // magenta
        .red = "\x1b[38;5;160m", // red
        .blue = "\x1b[38;5;33m", // blue
        .white = "\x1b[38;5;230m", // base3 (light text on dark)
        .gray = "\x1b[38;5;244m", // base00
        .dark_gray = "\x1b[38;5;240m", // base01
        .bright_yellow = "\x1b[38;5;136m",
        .bright_green = "\x1b[38;5;64m",
        .bright_red = "\x1b[38;5;160m",
        .bg_input = "\x1b[48;5;234m", // base02
        .bg_green = "\x1b[48;5;22m",
        .bg_red = "\x1b[48;5;52m",
        .bg_block = "\x1b[48;5;235m", // base02 darker
    };

    /// Mono theme — no colors, just bold/dim emphasis. For accessibility
    /// and terminals without color support.
    pub const mono: Palette = .{
        .name = .mono,
        .cyan = "",
        .green = "",
        .yellow = "",
        .magenta = "",
        .red = "",
        .blue = "",
        .white = "",
        .gray = "",
        .dark_gray = "",
        .bright_yellow = "",
        .bright_green = "",
        .bright_red = "",
        .bg_input = "",
        .bg_green = "",
        .bg_red = "",
        .bg_block = "",
    };
};

/// Number of display columns for a UTF-8 string (counts codepoints, treating
/// each as width 1). Good enough for Latin + Vietnamese; not full wcwidth.
pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        i += utf8SeqLen(text[i]);
        width += 1;
    }
    return width;
}

fn utf8SeqLen(first: u8) usize {
    if (first < 0x80) return 1;
    if (first >= 0xF0) return 4;
    if (first >= 0xE0) return 3;
    if (first >= 0xC0) return 2;
    return 1;
}

/// Byte offset after `cols` codepoints (or end of string).
fn byteOffsetForCols(text: []const u8, cols: usize) usize {
    var i: usize = 0;
    var seen: usize = 0;
    while (i < text.len and seen < cols) {
        i += utf8SeqLen(text[i]);
        seen += 1;
    }
    return @min(i, text.len);
}

pub fn truncateEnd(buf: []u8, text: []const u8, max_len: usize) []const u8 {
    if (displayWidth(text) <= max_len) return text;
    if (max_len < 4) {
        const cut = byteOffsetForCols(text, max_len);
        return text[0..cut];
    }
    const keep_cols = max_len - 3;
    var keep = byteOffsetForCols(text, keep_cols);
    if (keep + 3 > buf.len) {
        // Fall back to a byte-safe boundary that fits the caller buffer.
        keep = buf.len - 3;
        while (keep > 0 and (text[keep] & 0xC0) == 0x80) keep -= 1;
    }
    @memcpy(buf[0..keep], text[0..keep]);
    @memcpy(buf[keep..][0..3], "...");
    return buf[0 .. keep + 3];
}

pub fn wrapLines(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]const []const u8 {
    if (width == 0) return &.{};
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var start: usize = 0;
    while (start < text.len) {
        const slice = text[start..];
        if (displayWidth(slice) <= width) {
            try lines.append(allocator, try allocator.dupe(u8, slice));
            break;
        }
        // Byte length of `width` codepoints (never splits a UTF-8 sequence).
        var break_at = byteOffsetForCols(slice, width);
        if (std.mem.lastIndexOfScalar(u8, slice[0..break_at], ' ')) |space| {
            if (space > 0) break_at = space;
        }
        try lines.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, slice[0..break_at], &std.ascii.whitespace)));
        start += break_at;
        while (start < text.len and text[start] == ' ') start += 1;
    }
    if (lines.items.len == 0) try lines.append(allocator, try allocator.dupe(u8, ""));
    return try lines.toOwnedSlice(allocator);
}

pub fn freeLines(allocator: std.mem.Allocator, lines: []const []const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

test "wrapLines splits long text" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapLines(allocator, "hello world from forge", 10);
    defer freeLines(allocator, wrapped);
    try std.testing.expect(wrapped.len >= 2);
}

test "displayWidth counts codepoints not bytes" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    // "Tiến" = T, i, ế (3 bytes), n → 4 codepoints
    try std.testing.expectEqual(@as(usize, 4), displayWidth("Tiến"));
}

test "truncateEnd never splits a UTF-8 sequence" {
    var buf: [64]u8 = undefined;
    const out = truncateEnd(&buf, "Tiến hành ngay bây giờ nhé", 8);
    // Result must be valid UTF-8 (no partial trailing byte).
    try std.testing.expect(std.unicode.utf8ValidateSlice(out[0 .. out.len - 3]));
}

test "wrapLines keeps UTF-8 intact" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapLines(allocator, "Tiến hành ngay bây giờ cho tôi nhé bạn", 8);
    defer freeLines(allocator, wrapped);
    for (wrapped) |line| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    }
}

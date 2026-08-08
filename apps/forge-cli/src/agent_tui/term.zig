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
    paste_len: usize = 0,
    /// P2: Mouse support enabled flag. Set by enableMouse().
    mouse_enabled: bool = false,

    pub fn init(use_color: bool) !Terminal {
        if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
        const saved = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        // Disable input translation: don't convert \r to \n (ICRNL),
        // don't convert \n to \r (INLCR), don't ignore \r (IGNCR).
        // This ensures Enter key (\r = byte 13) is read as-is.
        raw.iflag.ICRNL = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        // Also disable output translation: don't convert \n to \r\n (ONLCR).
        // The TUI handles its own line endings.
        raw.oflag.ONLCR = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        // Use the MAIN screen (not alt screen) so the terminal's native
        // scrollback buffer is preserved. With alt screen (?1049h), users
        // cannot scroll up to see output that scrolled off the top — the
        // alt buffer has no scrollback. Main screen lets users use
        // Shift-PgUp / mouse wheel / terminal scrollback to review past
        // output even after the TUI exits.
        //
        // Trade-off: when the TUI exits, the last rendered frame remains
        // visible at the top of the scrollback. We accept this — it's
        // better than losing all history.
        //
        // We still: hide cursor (?25l), enable bracketed paste (?2004h),
        // and enable alternate-scroll mode (?1007h) so wheel scrolling
        // can drive the TUI when the mouse is over the terminal.
        try writeAll("\x1b[?25l\x1b[?2004h\x1b[?1007h");
        // Clear screen once at startup so we start from a clean slate.
        // After this, diff-rendering overwrites cells in place without
        // clearing the whole screen each frame.
        try writeAll("\x1b[2J\x1b[H");
        return .{ .saved = saved, .active = true, .use_color = use_color };
    }

    pub fn restore(self: *Terminal) void {
        if (!self.active) return;
        // Disable: bracketed paste, mouse, show cursor.
        // We don't exit alt screen (we never entered it) — just restore cursor.
        writeAll("\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1007l\x1b[?2004l\x1b[?25h") catch {};
        // Move cursor to bottom of screen so new shell prompt appears below.
        writeAll("\r\n") catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.saved) catch {};
        self.mouse_enabled = false;
        self.active = false;
    }

    /// P2: Enable SGR mouse support (\x1b[?1000h = normal tracking,
    /// \x1b[?1006h = SGR mouse format). Call this to receive mouse events.
    pub fn enableMouse(self: *Terminal) void {
        if (!self.active or self.mouse_enabled) return;
        writeAll("\x1b[?1000h\x1b[?1006h") catch {};
        self.mouse_enabled = true;
    }

    /// P2: Disable mouse support.
    pub fn disableMouse(self: *Terminal) void {
        if (!self.active) return;
        writeAll("\x1b[?1006l\x1b[?1000l") catch {};
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

        if (self.pasting) {
            return self.readPasteContinuation(buf[0..n]);
        }

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
                        self.paste_len = 0;
                        self.appendPasteBytes(content);
                        return .{ .paste = paste_static_buf[0..self.paste_len] };
                    }
                }
            }
            self.paste_len = 0;
            self.appendPasteBytes(buf[content_start..n]);
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
        // IMPORTANT: \r (byte 13) is the Enter key on most terminals.
        // It MUST be checked BEFORE the ctrl_m check below, because
        // Ctrl+M also sends byte 13. We prioritize Enter over Ctrl+M
        // since Enter is used far more frequently.
        // The .ctrl_m case (cycle mode) is still accessible via Ctrl+J
        // (byte 10) which is the Line Feed / multi-line input key.
        if (buf[0] == '\r' or buf[0] == '\n') return .enter;
        if (buf[0] == 10) return .ctrl_j; // Ctrl+J = LF = newline for multi-line input
        if (buf[0] == 12) return .ctrl_l;
        // Ctrl+M (byte 13) is already handled as .enter above.
        // If you need Ctrl+M specifically, use a different binding.
        if (buf[0] == 18) return .ctrl_r;
        if (buf[0] == 21) return .ctrl_u;
        if (buf[0] == 23) return .ctrl_w;
        if (buf[0] == 25) return .ctrl_y;
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
        if (n > 1 and isPlainTextPaste(buf[0..n])) {
            self.paste_len = 0;
            self.appendPasteBytes(buf[0..n]);
            return .{ .paste = paste_static_buf[0..self.paste_len] };
        }
        return .{ .char = buf[0] };
    }

    fn readPasteContinuation(self: *Terminal, bytes: []const u8) Key {
        var i: usize = 0;
        while (i + 5 < bytes.len) : (i += 1) {
            if (bytes[i] == 27 and bytes[i + 1] == '[' and bytes[i + 2] == '2' and bytes[i + 3] == '0' and bytes[i + 4] == '1' and bytes[i + 5] == '~') {
                self.appendPasteBytes(bytes[0..i]);
                self.pasting = false;
                return .{ .paste = paste_static_buf[0..self.paste_len] };
            }
        }
        self.appendPasteBytes(bytes);
        return .none;
    }

    fn appendPasteBytes(self: *Terminal, bytes: []const u8) void {
        if (self.paste_len >= paste_static_buf.len) return;
        const writable = @min(bytes.len, paste_static_buf.len - self.paste_len);
        @memcpy(paste_static_buf[self.paste_len .. self.paste_len + writable], bytes[0..writable]);
        self.paste_len += writable;
    }
};

fn isPlainTextPaste(bytes: []const u8) bool {
    for (bytes) |c| {
        if (c == 27) return false;
        if (c < 32 and c != '\t' and c != '\n' and c != '\r') return false;
    }
    return true;
}

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
    // Each entry is the rendered bytes (after moveTo + clear + content)
    // for that row in the previous frame. When a row's content matches,
    // we skip emitting it entirely — no cursor move, no clear, no write.
    // This cuts bytes-written-to-stdout by 60-90% on stable frames (only
    // the cursor + spinner row change between frames when idle).
    prev_rows: std.ArrayList([]u8) = .empty,
    prev_rows_valid: bool = false,
    // Current-frame row buffer: accumulates bytes for the row being built.
    // Flushed to prev_rows on endFrame().
    cur_rows: std.ArrayList([]u8) = .empty,
    // Pending bytes for the current row that hasn't been moveTo'd yet.
    // We buffer writes per-row so we can compare against prev_rows.
    // Track the "current row" being written — if -1, no row active.
    cur_row: i32 = -1,
    cur_row_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) FrameBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameBuffer) void {
        self.data.deinit(self.allocator);
        self.cur_row_buf.deinit(self.allocator);
        for (self.prev_rows.items) |row| self.allocator.free(row);
        self.prev_rows.deinit(self.allocator);
        for (self.cur_rows.items) |row| self.allocator.free(row);
        self.cur_rows.deinit(self.allocator);
    }

    pub fn reset(self: *FrameBuffer) void {
        self.data.clearRetainingCapacity();
        self.cur_row_buf.clearRetainingCapacity();
        self.cur_row = -1;
        // Clear cur_rows (will be repopulated during this frame).
        for (self.cur_rows.items) |row| self.allocator.free(row);
        self.cur_rows.clearRetainingCapacity();
    }

    pub fn begin(self: *FrameBuffer) void {
        self.reset();
        // Move to home but DON'T clear screen — we'll overwrite cells in place.
        // This eliminates the flicker from clear+repaint.
        self.appendSlice("\x1b[H") catch {};
    }

    pub fn moveTo(self: *FrameBuffer, row: u16, col: u16) void {
        // Flush the previous row's buffered content into cur_rows.
        self.flushCurrentRow();

        // Buffer the moveTo + set current row. We'll emit it during flush()
        // only if the row content differs from prev_rows.
        self.cur_row = @intCast(row);
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch return;
        self.cur_row_buf.appendSlice(self.allocator, slice) catch {};
    }

    pub fn writeRow(self: *FrameBuffer, row: u16, cols: u16, text: []const u8) void {
        self.moveTo(row, 1);
        self.appendSlice(text) catch {};
        if (text.len < cols) {
            self.cur_row_buf.appendNTimes(self.allocator, ' ', cols - text.len) catch {};
        }
        self.appendSlice("\x1b[K") catch {};
    }

    pub fn appendSlice(self: *FrameBuffer, text: []const u8) !void {
        // If a row is active (cur_row >= 0), buffer into cur_row_buf.
        // Otherwise (e.g. the initial \x1b[H in begin()), write directly to data.
        if (self.cur_row >= 0) {
            try self.cur_row_buf.appendSlice(self.allocator, text);
        } else {
            try self.data.appendSlice(self.allocator, text);
        }
    }

    /// Flush the current row's buffered content into cur_rows, then reset
    /// the per-row buffer for the next moveTo.
    fn flushCurrentRow(self: *FrameBuffer) void {
        if (self.cur_row < 0) return;
        const owned = self.cur_row_buf.toOwnedSlice(self.allocator) catch {
            // On allocation failure, drop the row but keep going.
            self.cur_row_buf.clearRetainingCapacity();
            self.cur_row = -1;
            return;
        };
        // Track the row index so we can compare during flush().
        // We store (row_index as first 4 bytes) + content — but simpler:
        // store content keyed by position in cur_rows which matches order
        // of moveTo calls. The render loop calls moveTo in increasing row
        // order, so cur_rows[i] corresponds to the i-th distinct row drawn.
        // We also store the row number so flush() can place it correctly.
        // Use a simple struct: pack row into a prefix.
        const row_num: u32 = @intCast(self.cur_row);
        const prefix = std.mem.asBytes(&row_num);
        const combined = self.allocator.alloc(u8, prefix.len + owned.len) catch {
            self.allocator.free(owned);
            self.cur_row_buf.clearRetainingCapacity();
            self.cur_row = -1;
            return;
        };
        @memcpy(combined[0..prefix.len], prefix);
        @memcpy(combined[prefix.len..], owned);
        self.allocator.free(owned);
        self.cur_rows.append(self.allocator, combined) catch {
            self.allocator.free(combined);
        };
        self.cur_row_buf = .empty;
        self.cur_row = -1;
    }

    /// Finalize the frame: flush the last row, then emit the current rows.
    /// The TUI can draw the same row more than once in one frame (for example
    /// clear row, then draw at an inset column). A row-level diff cache loses
    /// that ordering information and can skip text that should be repainted, so
    /// we favor correctness and redraw current rows every frame.
    pub fn flush(self: *FrameBuffer) void {
        // Flush any pending row.
        self.flushCurrentRow();

        for (self.cur_rows.items) |entry| {
            if (entry.len < 4) continue;
            self.data.appendSlice(self.allocator, entry[4..]) catch {};
        }

        // If the number of rows shrank this frame, clear the trailing rows
        // that were drawn last frame but not this frame. This prevents
        // stale content from lingering at the bottom.
        // Collect prev row numbers into a set for the "which prev rows are
        // no longer present" check.
        {
            var cur_row_nums: std.AutoHashMap(u32, void) = .init(self.allocator);
            defer cur_row_nums.deinit();
            for (self.cur_rows.items) |entry| {
                if (entry.len < 4) continue;
                const row_num_bytes: [4]u8 = entry[0..4].*;
                const row_num: u32 = std.mem.readInt(u32, &row_num_bytes, .little);
                cur_row_nums.put(row_num, {}) catch {};
            }
            if (self.prev_rows_valid) {
                for (self.prev_rows.items) |entry| {
                    if (entry.len < 4) continue;
                    const row_num_bytes: [4]u8 = entry[0..4].*;
                    const row_num: u32 = std.mem.readInt(u32, &row_num_bytes, .little);
                    if (!cur_row_nums.contains(row_num)) {
                        // This row was drawn last frame but not this frame — clear it.
                        var buf: [32]u8 = undefined;
                        const clear_seq = std.fmt.bufPrint(&buf, "\x1b[{d};1H\x1b[2K", .{row_num}) catch continue;
                        self.data.appendSlice(self.allocator, clear_seq) catch {};
                    }
                }
            }
        }

        // Swap cur_rows → prev_rows for next frame.
        for (self.prev_rows.items) |row| self.allocator.free(row);
        self.prev_rows.clearRetainingCapacity();
        // Move cur_rows into prev_rows (transfer ownership, no re-alloc).
        self.prev_rows.appendSlice(self.allocator, self.cur_rows.items) catch {};
        self.cur_rows.clearRetainingCapacity();
        self.prev_rows_valid = true;

        // Write the assembled diff to stdout.
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
    pub const italic = "\x1b[3m";
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
    pub const violet = "\x1b[38;5;99m";
    pub const lime = "\x1b[38;5;118m";
    pub const border = "\x1b[38;5;244m";
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

pub fn utf8SeqLen(first: u8) usize {
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
    while (start <= text.len) {
        const paragraph_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        var paragraph_start = start;

        if (paragraph_start == paragraph_end) {
            try lines.append(allocator, try allocator.dupe(u8, ""));
        } else {
            while (paragraph_start < paragraph_end) {
                const slice = text[paragraph_start..paragraph_end];
                if (displayWidth(slice) <= width) {
                    try lines.append(allocator, try allocator.dupe(u8, slice));
                    paragraph_start = paragraph_end;
                    break;
                }
                // Byte length of `width` codepoints (never splits a UTF-8 sequence).
                var break_at = byteOffsetForCols(slice, width);
                if (std.mem.lastIndexOfScalar(u8, slice[0..break_at], ' ')) |space| {
                    if (space > 0) break_at = space;
                }
                try lines.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, slice[0..break_at], &std.ascii.whitespace)));
                paragraph_start += break_at;
                while (paragraph_start < paragraph_end and text[paragraph_start] == ' ') paragraph_start += 1;
            }
        }

        if (paragraph_end == text.len) break;
        start = paragraph_end + 1;
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

test "wrapLines preserves explicit newlines" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapLines(allocator, "one\ntwo\n\nthree", 20);
    defer freeLines(allocator, wrapped);
    try std.testing.expectEqual(@as(usize, 4), wrapped.len);
    try std.testing.expectEqualStrings("one", wrapped[0]);
    try std.testing.expectEqualStrings("two", wrapped[1]);
    try std.testing.expectEqualStrings("", wrapped[2]);
    try std.testing.expectEqualStrings("three", wrapped[3]);
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

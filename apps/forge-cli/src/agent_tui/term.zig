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
    ctrl_l,
    ctrl_m,
    ctrl_r,
    ctrl_u,
    ctrl_w,
    none,
};

pub const Terminal = struct {
    saved: std.posix.termios,
    active: bool = false,
    use_color: bool = true,

    pub fn init(use_color: bool) !Terminal {
        if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
        const saved = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        try writeAll("\x1b[?1049h\x1b[?25l");
        return .{ .saved = saved, .active = true, .use_color = use_color };
    }

    pub fn restore(self: *Terminal) void {
        if (!self.active) return;
        writeAll("\x1b[?1049l\x1b[?25h") catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.saved) catch {};
        self.active = false;
    }

    pub fn deinit(self: *Terminal) void {
        self.restore();
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

    pub fn readKey(self: *const Terminal) !Key {
        _ = self;
        var buf: [8]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return error.ReadFailed;
        if (n == 0) return .none;
        if (buf[0] == 1) return .ctrl_a;
        if (buf[0] == 3) return .ctrl_c;
        if (buf[0] == 4) return .ctrl_d;
        if (buf[0] == 5) return .ctrl_e;
        if (buf[0] == 12) return .ctrl_l;
        if (buf[0] == 13) return .ctrl_m;
        if (buf[0] == 18) return .ctrl_r;
        if (buf[0] == 21) return .ctrl_u;
        if (buf[0] == 23) return .ctrl_w;
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
            return .escape;
        }
        if (buf[0] == '\t') return .tab;
        return .{ .char = buf[0] };
    }
};

pub const FrameBuffer = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) FrameBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FrameBuffer) void {
        self.data.deinit(self.allocator);
    }

    pub fn reset(self: *FrameBuffer) void {
        self.data.clearRetainingCapacity();
    }

    pub fn begin(self: *FrameBuffer) void {
        self.reset();
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

fn writeAll(bytes: []const u8) !void {
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
    pub const cyan = "\x1b[36m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const magenta = "\x1b[35m";
    pub const red = "\x1b[31m";
    pub const blue = "\x1b[34m";
    pub const white = "\x1b[37m";
    pub const gray = "\x1b[90m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_green = "\x1b[92m";
    pub const bright_red = "\x1b[91m";
    pub const bg_input = "\x1b[48;5;235m";
    pub const bg_green = "\x1b[48;5;22m";
    pub const bg_red = "\x1b[48;5;52m";
    pub const reset = "\x1b[0m";
    pub const invert = "\x1b[7m";
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

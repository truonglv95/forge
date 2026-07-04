const std = @import("std");

const State = enum {
    normal,
    escape,
    csi,
    osc,
    osc_escape,
    charset,
};

/// Strips ANSI/OSC escape sequences and assembles PTY output into display lines.
pub const LineAssembler = struct {
    state: State = .normal,
    line: std.ArrayList(u8),
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator) LineAssembler {
        _ = allocator;
        return .{ .line = .empty };
    }

    pub fn deinit(self: *LineAssembler, allocator: std.mem.Allocator) void {
        self.line.deinit(allocator);
    }

    pub fn feed(
        self: *LineAssembler,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        ctx: *anyopaque,
        appendLine: *const fn (ctx: *anyopaque, line: []const u8) anyerror!void,
    ) !void {
        var index: usize = 0;
        while (index < chunk.len) {
            switch (self.state) {
                .normal => {
                    const byte = chunk[index];
                    index += 1;
                    switch (byte) {
                        '\x1b' => self.state = .escape,
                        '\r' => self.cursor = 0,
                        '\n' => try self.flushLine(ctx, appendLine),
                        '\t' => try self.writeAtCursor(allocator, '\t'),
                        '\x08', '\x7f' => try self.deleteBeforeCursor(allocator),
                        else => {
                            if (byte < 32) continue;
                            try self.writeAtCursor(allocator, byte);
                        },
                    }
                },
                .escape => {
                    const byte = chunk[index];
                    index += 1;
                    self.state = switch (byte) {
                        '[' => .csi,
                        ']' => .osc,
                        '(', ')', '*', '+' => .charset,
                        else => .normal,
                    };
                },
                .charset => {
                    _ = chunk[index];
                    index += 1;
                    self.state = .normal;
                },
                .csi => {
                    const byte = chunk[index];
                    index += 1;
                    if (byte >= 0x40 and byte <= 0x7E) {
                        if (byte == 'K') try self.eraseToEndOfLine(allocator);
                        self.state = .normal;
                    }
                },
                .osc => {
                    const byte = chunk[index];
                    index += 1;
                    switch (byte) {
                        '\x07' => self.state = .normal,
                        '\x1b' => self.state = .osc_escape,
                        else => {},
                    }
                },
                .osc_escape => {
                    const byte = chunk[index];
                    index += 1;
                    self.state = if (byte == '\\') .normal else .osc;
                },
            }
        }
    }

    fn deleteBeforeCursor(self: *LineAssembler, allocator: std.mem.Allocator) !void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        if (self.cursor < self.line.items.len) {
            _ = self.line.orderedRemove(self.cursor);
        }
        _ = allocator;
    }

    fn writeAtCursor(self: *LineAssembler, allocator: std.mem.Allocator, byte: u8) !void {
        if (self.cursor < self.line.items.len) {
            self.line.items[self.cursor] = byte;
        } else {
            try self.line.append(allocator, byte);
        }
        self.cursor += 1;
    }

    fn eraseToEndOfLine(self: *LineAssembler, allocator: std.mem.Allocator) !void {
        if (self.cursor >= self.line.items.len) return;
        self.line.shrinkRetainingCapacity(self.cursor);
        _ = allocator;
    }

    fn flushLine(
        self: *LineAssembler,
        ctx: *anyopaque,
        appendLine: *const fn (ctx: *anyopaque, line: []const u8) anyerror!void,
    ) !void {
        try appendLine(ctx, self.line.items);
        self.line.clearRetainingCapacity();
        self.cursor = 0;
    }
};

test "strips fish shell integration sequences" {
    const sample =
        "\x1b]1337;RemoteHost=user@host\x07" ++
        "\x1b]1337;CurrentDir=/tmp\x07" ++
        "\x1b[38;2;85;85;85mDarwin host 25.5.0 arm64\x1b(B\x1b[m\n" ++
        "\x1b]0;~/proj\x07" ++
        "forge> ";

    var filter = LineAssembler.init(std.testing.allocator);
    defer filter.deinit(std.testing.allocator);

    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(std.testing.allocator);

    const Ctx = struct {
        out: *std.ArrayList(u8),
        fn append(ctx: *anyopaque, line: []const u8) !void {
            const list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
            if (line.len > 0) try list.appendSlice(std.testing.allocator, line);
            try list.append(std.testing.allocator, '\n');
        }
    };
    var ctx = Ctx{ .out = &collected };
    try filter.feed(std.testing.allocator, sample, &ctx, Ctx.append);

    try std.testing.expect(std.mem.indexOf(u8, collected.items, "1337") == null);
    try std.testing.expect(std.mem.indexOf(u8, collected.items, "Darwin host") != null);
    try std.testing.expect(std.mem.indexOf(u8, collected.items, "forge>") != null);
}

test "carriage return overwrites current line" {
    var filter = LineAssembler.init(std.testing.allocator);
    defer filter.deinit(std.testing.allocator);

    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(std.testing.allocator);

    const Ctx = struct {
        out: *std.ArrayList(u8),
        fn append(ctx: *anyopaque, line: []const u8) !void {
            const list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
            try list.appendSlice(std.testing.allocator, line);
            try list.append(std.testing.allocator, '|');
        }
    };
    var ctx = Ctx{ .out = &collected };

    try filter.feed(std.testing.allocator, "old\rnew\n", &ctx, Ctx.append);
    try std.testing.expectEqualStrings("new|", collected.items);
}

test "carriage return alone keeps prompt visible" {
    var filter = LineAssembler.init(std.testing.allocator);
    defer filter.deinit(std.testing.allocator);

    var ctx: u8 = 0;
    try filter.feed(std.testing.allocator, "truong@host % ", &ctx, noopAppend);
    try filter.feed(std.testing.allocator, "\r", &ctx, noopAppend);
    try std.testing.expectEqualStrings("truong@host % ", filter.line.items);
}

fn noopAppend(ctx: *anyopaque, line: []const u8) !void {
    _ = ctx;
    _ = line;
}

//! Component system for Forge TUI
//! Base component interface and event handling

const std = @import("std");
const Allocator = std.mem.Allocator;
const layouts = @import("../layouts/layouts.zig");
const state = @import("../state/state.zig");
const theme = @import("../theme/theme.zig");

/// Input events
pub const InputEvent = union(enum) {
    key: Key,
    mouse: MouseEvent,
    paste: []const u8,
    resize: struct { width: u16, height: u16 },
    focus: bool,
};

/// Key events
pub const Key = union(enum) {
    char: u8,
    ctrl: u8,
    alt: u8,
    shift_char: u8,
    special: SpecialKey,
});

/// Special keys
pub const SpecialKey = enum {
    enter,
    tab,
    backspace,
    escape,
    space,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    insert,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// Mouse events
pub const MouseEvent = struct {
    x: i32,
    y: i32,
    button: MouseButton,
    action: MouseAction,
    modifiers: Modifiers,
};

pub const MouseButton = enum { left, right, middle, scroll_up, scroll_down };
pub const MouseAction = enum { press, release, move, double_click };
pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
};

/// Component result
pub const ComponentResult = enum {
    consumed,
    ignored,
    propagate,
    quit,
};

/// Base component interface
pub const Component = @Type(.{
    .Struct = .{
        .layout = .auto,
        .fields = &.{},
        .decls = &.{},
        .is_tuple = false,
    },
});

/// Component vtable
pub const ComponentVTable = struct {
    render: *const fn (*anyopaque, layouts.Rect, anytype) !void,
    handleEvent: *const fn (*anyopaque, InputEvent) ComponentResult,
    update: *const fn (*anyopaque) void,
    getRect: *const fn (*anyopaque) layouts.Rect,
    setRect: *const fn (*anyopaque, layouts.Rect) void,
    focus: *const fn (*anyopaque) bool,
    setFocus: *const fn (*anyopaque, bool) void,
};

/// Component container
pub const ComponentContainer = struct {
    ptr: *anyopaque,
    vtable: *const ComponentVTable,

    pub fn render(self: ComponentContainer, rect: layouts.Rect, writer: anytype) !void {
        return self.vtable.render(self.ptr, rect, writer);
    }

    pub fn handleEvent(self: ComponentContainer, event: InputEvent) ComponentResult {
        return self.vtable.handleEvent(self.ptr, event);
    }

    pub fn update(self: ComponentContainer) void {
        self.vtable.update(self.ptr);
    }

    pub fn getRect(self: ComponentContainer) layouts.Rect {
        return self.vtable.getRect(self.ptr);
    }

    pub fn setRect(self: ComponentContainer, rect: layouts.Rect) void {
        self.vtable.setRect(self.ptr, rect);
    }

    pub fn isFocused(self: ComponentContainer) bool {
        return self.vtable.focus(self.ptr);
    }

    pub fn setFocus(self: ComponentContainer, focused: bool) void {
        self.vtable.setFocus(self.ptr, focused);
    }
};

/// Event loop configuration
pub const EventLoopConfig = struct {
    tick_rate_ms: u64 = 16, // ~60 FPS
    enable_mouse: bool = true,
    enable_paste: bool = true,
    enable_bracketed_paste: bool = true,
};

/// Event loop
pub const EventLoop = struct {
    config: EventLoopConfig,
    stdin: std.fs.File.Reader,
    stdout: std.fs.File.Writer,
    running: bool = false,
    raw_mode: bool = false,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, config: EventLoopConfig) !Self {
        return .{
            .config = config,
            .stdin = std.io.getStdIn().reader(),
            .stdout = std.io.getStdOut().writer(),
            .running = false,
            .raw_mode = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.raw_mode) {
            self.disableRawMode() catch {};
        }
    }

    pub fn enableRawMode(self: *Self) !void {
        if (self.raw_mode) return;
        
        // Enable raw mode using termios
        const termios_h = @cImport({
            @cInclude("termios.h");
            @cInclude("unistd.h");
        });
        
        var tty_attr: termios_h.termios = undefined;
        if (termios_h.tcgetattr(0, &tty_attr) < 0) {
            return error.TerminalError;
        }
        
        const original = tty_attr;
        tty_attr.c_lflag &= ~(@as(c_uint, termios_h.ICANON) | termios_h.ECHO);
        tty_attr.c_lflag |= termios_h.ISIG;
        tty_attr.c_iflag &= ~(@as(c_uint, termios_h.ISTRIP) | termios_h.INLCR | termios_h.IGNCR | termios_h.ICRNL | termios_h.IXON);
        tty_attr.c_oflag &= ~@as(c_uint, termios_h.OPOST);
        tty_attr.c_cc[termios_h.VMIN] = 0;
        tty_attr.c_cc[termios_h.VTIME] = 0;
        
        if (termios_h.tcsetattr(0, termios_h.TCSANOW, &tty_attr) < 0) {
            return error.TerminalError;
        }
        
        self.raw_mode = true;
        
        // Enable mouse
        if (self.config.enable_mouse) {
            try self.stdout.writeAll("\x1b[?1003h\x1b[?1006h");
        }
        
        // Enable bracketed paste
        if (self.config.enable_bracketed_paste) {
            try self.stdout.writeAll("\x1b[?2004h");
        }
    }

    pub fn disableRawMode(self: *Self) !void {
        if (!self.raw_mode) return;
        
        const termios_h = @cImport({
            @cInclude("termios.h");
            @cInclude("unistd.h");
        });
        
        var tty_attr: termios_h.termios = undefined;
        if (termios_h.tcgetattr(0, &tty_attr) == 0) {
            tty_attr.c_lflag |= @as(c_uint, termios_h.ICANON) | termios_h.ECHO;
            _ = termios_h.tcsetattr(0, termios_h.TCSANOW, &tty_attr);
        }
        
        // Disable mouse
        try self.stdout.writeAll("\x1b[?1003l\x1b[?1006l");
        
        // Disable bracketed paste
        try self.stdout.writeAll("\x1b[?2004l");
        
        // Reset all styles
        try self.stdout.writeAll("\x1b[0m\x1b[2J\x1b[H");
        
        self.raw_mode = false;
    }

    pub fn nextEvent(self: *Self) !?InputEvent {
        var buf: [32]u8 = undefined;
        const n = try self.stdin.read(&buf);
        
        if (n == 0) return null;
        
        return self.parseEvent(buf[0..n]);
    }

    fn parseEvent(self: *Self, buf: []const u8) ?InputEvent {
        if (buf.len == 0) return null;
        
        // ESC sequence
        if (buf[0] == 27) {
            if (buf.len == 1) {
                return .{ .key = .{ .special = .escape } };
            }
            
            if (buf.len >= 2 and buf[1] == 91) {
                // CSI sequence
                if (buf.len >= 3) {
                    switch (buf[2]) {
                        65 => return .{ .key = .{ .special = .up } },
                        66 => return .{ .key = .{ .special = .down } },
                        67 => return .{ .key = .{ .special = .right } },
                        68 => return .{ .key = .{ .special = .left } },
                        72 => return .{ .key = .{ .special = .home } },
                        70 => return .{ .key = .{ .special = .end } },
                        51 => return .{ .key = .{ .special = .delete } },
                        50 => return .{ .key = .{ .special = .insert } },
                        53 => return .{ .key = .{ .special = .page_up } },
                        54 => return .{ .key = .{ .special = .page_down } },
                        else => {},
                    }
                    
                    // F1-F4
                    if (buf.len >= 4 and buf[3] == 126) {
                        switch (buf[2]) {
                            49 => return .{ .key = .{ .special = .f1 } },
                            50 => return .{ .key = .{ .special = .f2 } },
                            51 => return .{ .key = .{ .special = .f3 } },
                            52 => return .{ .key = .{ .special = .f4 } },
                            else => {},
                        }
                    }
                }
                
                // Mouse event
                if (buf.len >= 6 and buf[1] == 91 and buf[2] == 60) {
                    const btn = buf[3] - 32;
                    const x = @as(i32, buf[4] - 33);
                    const y = @as(i32, buf[5] - 33);
                    
                    return .{
                        .mouse = .{
                            .x = x,
                            .y = y,
                            .button = switch (btn & 0x3) {
                                0 => .left,
                                1 => .middle,
                                2 => .right,
                                else => .scroll_up,
                            },
                            .action = if ((btn & 0x40) != 0) .release else .press,
                            .modifiers = .{},
                        },
                    };
                }
                
                return .{ .key = .{ .special = .escape } };
            }
            
            // Alt key
            if (buf.len >= 2) {
                return .{ .key = .{ .alt = buf[1] } };
            }
        }
        
        // Ctrl key
        if (buf[0] < 27) {
            return .{ .key = .{ .ctrl = buf[0] + 64 } };
        }
        
        // Regular character
        return .{ .key = .{ .char = buf[0] } };
    }

    pub fn run(self: *Self, comptime Handler: type, handler: *Handler) !void {
        try self.enableRawMode();
        self.running = true;
        
        while (self.running) {
            if (try self.nextEvent()) |event| {
                const result = handler.handleEvent(event);
                if (result == .quit) {
                    self.running = false;
                }
            }
            
            handler.update();
            
            // Small delay to prevent busy loop
            std.time.sleep(std.time.ns_per_ms * self.config.tick_rate_ms);
        }
        
        try self.disableRawMode();
    }
};

test "event parsing" {
    var loop = try EventLoop.init(std.testing.allocator, .{});
    defer loop.deinit();
    
    // Test escape
    const esc = loop.parseEvent(&.{27}).?;
    try std.testing.expect(esc == .key);
    try std.testing.expect(esc.key == .special);
    try std.testing.expect(esc.key.special == .escape);
}

//! Core Components for Forge TUI
//! 
//! Base component interface and essential components.

const std = @import("std");
const theme = @import("../theme/theme.zig");
const layouts = @import("../layouts/layouts.zig");
const state = @import("../state/state.zig");

/// Component lifecycle and interface
pub const Component = struct {
    id: []const u8,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    visible: bool = true,
    focused: bool = false,
    parent: ?*Component = null,
    children: std.ArrayList(*Component),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, rect: layouts.Rect) Component {
        return .{
            .id = id,
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
            .children = std.ArrayList(*Component).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Component) void {
        self.children.deinit();
    }

    pub fn render(self: *Component, renderer: anytype) !void {
        if (!self.visible) return;
        // Default render does nothing - override in subclasses
        _ = renderer;
    }

    pub fn handleEvent(self: *Component, event: anytype) !bool {
        // Default event handler - override in subclasses
        _ = event;
        return false; // Event not handled
    }

    pub fn addChild(self: *Component, child: *Component) !void {
        child.parent = self;
        try self.children.append(child);
    }

    pub fn removeChild(self: *Component, child: *Component) void {
        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.orderedRemove(i);
                break;
            }
        }
    }

    pub fn setBounds(self: *Component, rect: layouts.Rect) void {
        self.x = rect.x;
        self.y = rect.y;
        self.width = rect.width;
        self.height = rect.height;
    }

    pub fn getBounds(self: Component) layouts.Rect {
        return .{
            .x = self.x,
            .y = self.y,
            .width = self.width,
            .height = self.height,
        };
    }
};

/// Input event types
pub const InputEvent = union(enum) {
    key: Key,
    mouse: MouseEvent,
    paste: []const u8,
    resize: struct { width: u16, height: u16 },
};

pub const Key = union(enum) {
    char: u8,
    ctrl_char: u8,
    enter,
    backspace,
    tab,
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
    f: u8, // F1-F12
    
    pub fn isCtrl(self: Key) bool {
        return self == .ctrl_char;
    }
};

pub const MouseEvent = union(enum) {
    press: struct { x: u16, y: u16, button: MouseButton },
    release: struct { x: u16, y: u16, button: MouseButton },
    move: struct { x: u16, y: u16 },
    scroll: struct { x: u16, y: u16, delta: i8 },
};

pub const MouseButton = enum {
    left,
    right,
    middle,
};

/// Event loop for processing input
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    mouse_enabled: bool,
    raw_mode: bool = false,
    input_buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, mouse_enabled: bool) EventLoop {
        return .{
            .allocator = allocator,
            .mouse_enabled = mouse_enabled,
            .input_buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.input_buffer.deinit();
        self.disableRawMode() catch {};
    }

    pub fn enableRawMode(self: *EventLoop) !void {
        if (self.raw_mode) return;
        
        // Enable raw mode using termios
        const stdin_fd = std.io.getStdIn().handle;
        var termios = try std.posix.tcgetattr(stdin_fd);
        
        // Save original settings
        self.original_termios = termios;
        
        // Set raw mode
        termios.input_flags.brkint = false;
        termios.input_flags.icrnl = false;
        termios.input_flags.inpck = false;
        termios.input_flags.istrip = false;
        termios.input_flags.ixon = false;
        termios.control_flags.csize = 8;
        termios.local_flags.icanon = false;
        termios.local_flags.echo = false;
        termios.local_flags.isig = false;
        termios.control_flags.cmin = 1;
        termios.control_flags.ctime = 0;
        
        try std.posix.tcsetattr(stdin_fd, .FLUSH, termios);
        self.raw_mode = true;
        
        // Enable mouse if requested
        if (self.mouse_enabled) {
            _ = std.io.getStdOut().write("\x1b[?1003h") catch {}; // Enable mouse tracking
        }
    }

    pub fn disableRawMode(self: *EventLoop) !void {
        if (!self.raw_mode) return;
        
        const stdin_fd = std.io.getStdIn().handle;
        try std.posix.tcsetattr(stdin_fd, .FLUSH, self.original_termios);
        self.raw_mode = false;
        
        // Disable mouse
        if (self.mouse_enabled) {
            _ = std.io.getStdOut().write("\x1b[?1003l") catch {};
        }
    }

    original_termios: std.posix.termios = undefined,

    pub fn poll(self: *EventLoop) ?InputEvent {
        var buf: [32]u8 = undefined;
        
        // Non-blocking read
        const n = std.posix.read(std.io.getStdIn().handle, &buf) catch return null;
        if (n == 0) return null;
        
        self.input_buffer.appendSlice(buf[0..n]) catch return null;
        
        // Parse escape sequences
        return self.parseInput();
    }

    fn parseInput(self: *EventLoop) ?InputEvent {
        if (self.input_buffer.items.len == 0) return null;
        
        const first = self.input_buffer.items[0];
        
        // Escape sequence
        if (first == 27) { // ESC
            if (self.input_buffer.items.len < 2) return null;
            
            if (self.input_buffer.items[1] == '[') {
                if (self.input_buffer.items.len < 3) return null;
                
                const third = self.input_buffer.items[2];
                
                // Arrow keys and function keys
                switch (third) {
                    'A' => {
                        self.input_buffer.clearRetainingCapacity();
                        return .{ .key = .up };
                    },
                    'B' => {
                        self.input_buffer.clearRetainingCapacity();
                        return .{ .key = .down };
                    },
                    'C' => {
                        self.input_buffer.clearRetainingCapacity();
                        return .{ .key = .right };
                    },
                    'D' => {
                        self.input_buffer.clearRetainingCapacity();
                        return .{ .key = .left };
                    },
                    'H' => {
                        self.input_buffer.clearRetainingCapacity();
                        return .{ .key = .home };
                    },
                    'F' => {
                        self.input_buffer.clearRetainingCapacity();
                        return .{ .key = .end };
                    },
                    '3' => {
                        self.input_buffer.clearRetainingCapacity();
                        return .{ .key = .delete };
                    },
                    else => {},
                }
            }
        }
        
        // Regular character
        if (first >= 32 and first < 127) {
            const char = self.input_buffer.orderedRemove(0);
            return .{ .key = .{ .char = char } };
        }
        
        // Backspace
        if (first == 127 or first == 8) {
            _ = self.input_buffer.orderedRemove(0);
            return .{ .key = .backspace };
        }
        
        // Enter
        if (first == 10 or first == 13) {
            _ = self.input_buffer.orderedRemove(0);
            return .{ .key = .enter };
        }
        
        // Tab
        if (first == 9) {
            _ = self.input_buffer.orderedRemove(0);
            return .{ .key = .tab };
        }
        
        // Ctrl+C
        if (first == 3) {
            _ = self.input_buffer.orderedRemove(0);
            return .{ .key = .{ .ctrl_char = 'c' } };
        }
        
        return null;
    }
};

test "Component creation" {
    const allocator = std.testing.allocator;
    var comp = Component.init(allocator, "test", .{ .x = 0, .y = 0, .width = 10, .height = 5 });
    defer comp.deinit();
    
    try std.testing.expectEqualStrings("test", comp.id);
    try std.testing.expectEqual(@as(u16, 10), comp.width);
}

test "Component bounds" {
    const allocator = std.testing.allocator;
    var comp = Component.init(allocator, "test", .{ .x = 5, .y = 10, .width = 20, .height = 15 });
    defer comp.deinit();
    
    const bounds = comp.getBounds();
    try std.testing.expectEqual(@as(u16, 5), bounds.x);
    try std.testing.expectEqual(@as(u16, 10), bounds.y);
}

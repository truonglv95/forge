//! Performance Optimizer - Dirty Rect Tracking, Frame Limiter, Input Debouncing
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FrameLimiter = struct {
    target_fps: u32,
    frame_duration_ns: u64,
    last_frame_time: u64,

    pub fn init(fps: u32) FrameLimiter {
        return .{
            .target_fps = fps,
            .frame_duration_ns = std.time.ns_per_s / fps,
            .last_frame_time = 0,
        };
    }

    pub fn shouldRender(self: *FrameLimiter) bool {
        const now = std.time.nanoTimestamp();
        if (now - self.last_frame_time >= self.frame_duration_ns) {
            self.last_frame_time = now;
            return true;
        }
        return false;
    }

    pub fn waitIfNeeded(self: *FrameLimiter) void {
        while (!self.shouldRender()) {
            std.time.sleep(1_000_000); // 1ms
        }
    }
};

pub const DirtyRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    dirty: bool,

    pub fn markDirty(self: *DirtyRect) void {
        self.dirty = true;
    }

    pub fn isDirty(self: *DirtyRect) bool {
        return self.dirty;
    }

    pub fn clear(self: *DirtyRect) void {
        self.dirty = false;
    }

    pub fn intersects(self: *DirtyRect, other: *DirtyRect) bool {
        return !(self.x + self.width <= other.x or
                 other.x + other.width <= self.x or
                 self.y + self.height <= other.y or
                 other.y + other.height <= self.y);
    }
};

pub const InputDebounce = struct {
    last_event_time: u64,
    debounce_ms: u64,

    pub fn init(debounce_ms: u64) InputDebounce {
        return .{
            .last_event_time = 0,
            .debounce_ms = debounce_ms,
        };
    }

    pub fn shouldProcess(self: *InputDebounce) bool {
        const now = std.time.milliTimestamp();
        if (now - self.last_event_time >= self.debounce_ms) {
            self.last_event_time = now;
            return true;
        }
        return false;
    }
};

pub const RenderBatch = struct {
    allocator: Allocator,
    commands: std.ArrayList(Command),

    pub const Command = union(enum) {
        draw_char: struct { x: usize, y: usize, char: u8, style: u16 },
        clear_rect: struct { x: usize, y: usize, w: usize, h: usize },
        set_cursor: struct { x: usize, y: usize },
    };

    pub fn init(allocator: Allocator) RenderBatch {
        return .{
            .allocator = allocator,
            .commands = std.ArrayList(Command).init(allocator),
        };
    }

    pub fn deinit(self: *RenderBatch) void {
        self.commands.deinit();
    }

    pub fn addDrawChar(self: *RenderBatch, x: usize, y: usize, char: u8, style: u16) !void {
        try self.commands.append(.{ .draw_char = .{ .x = x, .y = y, .char = char, .style = style } });
    }

    pub fn addClearRect(self: *RenderBatch, x: usize, y: usize, w: usize, h: usize) !void {
        try self.commands.append(.{ .clear_rect = .{ .x = x, .y = y, .w = w, .h = h } });
    }

    pub fn addSetCursor(self: *RenderBatch, x: usize, y: usize) !void {
        try self.commands.append(.{ .set_cursor = .{ .x = x, .y = y } });
    }

    pub fn flush(self: *RenderBatch, writer: anytype) !void {
        for (self.commands.items) |cmd| {
            switch (cmd) {
                .draw_char => |dc| {
                    try writer.print("\x1b[{d};{d}H\x1b[38;5;{d}m{c}", .{ dc.y + 1, dc.x + 1, dc.style, dc.char });
                },
                .clear_rect => |cr| {
                    try writer.print("\x1b[{d};{d}H\x1b[J", .{ cr.y + 1, cr.x + 1 });
                },
                .set_cursor => |sc| {
                    try writer.print("\x1b[{d};{d}H", .{ sc.y + 1, sc.x + 1 });
                },
            }
        }
        self.commands.clearRetainingCapacity();
    }
};

test "FrameLimiter limits FPS" {
    var limiter = FrameLimiter.init(60);
    _ = limiter.shouldRender();
    try std.testing.expectEqual(false, limiter.shouldRender());
}

test "DirtyRect intersection" {
    var rect1 = DirtyRect{ .x = 0, .y = 0, .width = 10, .height = 10, .dirty = true };
    var rect2 = DirtyRect{ .x = 5, .y = 5, .width = 10, .height = 10, .dirty = true };
    try std.testing.expectEqual(true, rect1.intersects(&rect2));
}

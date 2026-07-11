const std = @import("std");

pub const mac = @cImport({
    @cInclude("mac_window.h");
});

pub const view = @import("view.zig");
pub const View = view.View;
pub const Rect = view.Rect;
pub const Color = view.Color;
pub const icons = @import("octicons.zig");
pub const file_icons = @import("file_icons.zig").icons;

pub const TextSpan = extern struct {
    offset: usize,
    length: usize,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const KeyEvent = struct {
    keycode: i32,
    chars: []const u8,
    is_down: bool,
    modifiers: i32,
};

pub const MouseAction = enum(c_int) {
    down = 0,
    up = 1,
    move = 2,
    drag = 3,
    scroll = 4,
};

pub const MouseEvent = struct {
    x: f32,
    y: f32,
    button: i32,
    action: MouseAction,
    modifiers: i32 = 0,
};

var app_render_callback: ?*const fn () void = null;
var app_key_callback: ?*const fn (event: KeyEvent) void = null;
var app_mouse_callback: ?*const fn (event: MouseEvent) void = null;

const ClipRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

var clip_stack: [12]ClipRect = undefined;
var clip_stack_len: usize = 0;
var active_clip: ?ClipRect = null;
var text_style_generation: u32 = 0;

const MeasureCacheSlot = struct {
    key: u64 = 0,
    width: f32 = 0,
};

var measure_cache: [1024]MeasureCacheSlot = [_]MeasureCacheSlot{.{}} ** 1024;
var measure_cache_hits: u64 = 0;
var measure_cache_misses: u64 = 0;

fn measureCacheKey(text: []const u8, font_size: f32) u64 {
    var hasher = std.hash.Wyhash.init(0x4652475f54455854);
    hasher.update(std.mem.asBytes(&text_style_generation));
    const font_bits: u32 = @bitCast(font_size);
    hasher.update(std.mem.asBytes(&font_bits));
    hasher.update(text);
    return hasher.final();
}

fn clearMeasureCache() void {
    measure_cache = [_]MeasureCacheSlot{.{}} ** 1024;
}

fn applyClipRect(rect: ClipRect) void {
    mac.forge_mac_set_clip_rect(rect.x, rect.y, rect.w, rect.h);
    active_clip = rect;
}

fn intersectClip(outer: ClipRect, inner: ClipRect) ClipRect {
    const x = @max(outer.x, inner.x);
    const y = @max(outer.y, inner.y);
    const right = @min(outer.x + outer.w, inner.x + inner.w);
    const bottom = @min(outer.y + outer.h, inner.y + inner.h);
    return .{
        .x = x,
        .y = y,
        .w = @max(0, right - x),
        .h = @max(0, bottom - y),
    };
}

export fn internal_render_callback() void {
    if (app_render_callback) |cb| {
        cb();
    }
}

export fn internal_key_callback(keycode: c_int, chars: [*c]const u8, is_down: bool, modifiers: c_int) void {
    if (app_key_callback) |cb| {
        const chars_slice = std.mem.span(chars);
        cb(.{
            .keycode = @as(i32, @intCast(keycode)),
            .chars = chars_slice,
            .is_down = is_down,
            .modifiers = @as(i32, @intCast(modifiers)),
        });
    }
}

export fn internal_mouse_callback(x: f32, y: f32, button: c_int, action: c_int, modifiers: c_int) void {
    if (app_mouse_callback) |cb| {
        cb(.{
            .x = x,
            .y = y,
            .button = @as(i32, @intCast(button)),
            .action = @as(MouseAction, @enumFromInt(action)),
            .modifiers = @as(i32, @intCast(modifiers)),
        });
    }
}

pub const Renderer = struct {
    pub fn init() void {
        mac.forge_mac_init();
        mac.forge_mac_set_render_callback(internal_render_callback);
        mac.forge_mac_set_key_callback(internal_key_callback);
        mac.forge_mac_set_mouse_callback(internal_mouse_callback);
    }

    pub fn createWindow(title: []const u8, width: i32, height: i32) void {
        mac.forge_mac_create_window(@ptrCast(title), width, height);
    }

    pub fn run() void {
        mac.forge_mac_run();
    }

    pub fn requestRedraw() void {
        mac.forge_mac_request_redraw();
    }

    pub fn setContinuousRendering(enabled: bool) void {
        mac.forge_mac_set_continuous_rendering(enabled);
    }

    pub fn setRenderCallback(callback: *const fn () void) void {
        app_render_callback = callback;
    }

    pub fn setKeyCallback(callback: *const fn (event: KeyEvent) void) void {
        app_key_callback = callback;
    }

    pub fn setMouseCallback(callback: *const fn (event: MouseEvent) void) void {
        app_mouse_callback = callback;
    }

    pub fn getWindowSize(width: *f32, height: *f32) void {
        mac.forge_mac_get_window_size(width, height);
    }

    pub fn setCursor(cursor_type: i32) void {
        mac.forge_mac_set_cursor(@as(c_int, @intCast(cursor_type)));
    }

    pub fn setClipRect(x: f32, y: f32, w: f32, h: f32) void {
        applyClipRect(.{ .x = x, .y = y, .w = w, .h = h });
    }

    pub fn pushClipRect(x: f32, y: f32, w: f32, h: f32) void {
        const next = ClipRect{ .x = x, .y = y, .w = w, .h = h };
        const clipped = if (active_clip) |current| intersectClip(current, next) else next;
        if (clip_stack_len < clip_stack.len) {
            if (active_clip) |current| {
                clip_stack[clip_stack_len] = current;
                clip_stack_len += 1;
            }
        }
        applyClipRect(clipped);
    }

    pub fn popClipRect() void {
        if (clip_stack_len == 0) {
            clearClipRect();
            return;
        }
        clip_stack_len -= 1;
        applyClipRect(clip_stack[clip_stack_len]);
    }

    pub fn clearClipRect() void {
        mac.forge_mac_clear_clip_rect();
        active_clip = null;
        clip_stack_len = 0;
    }

    pub fn flushBatch() void {
        mac.forge_mac_flush_batch();
    }

    pub fn drawRect(x: f32, y: f32, w: f32, h: f32, color: Color) void {
        mac.forge_mac_draw_rect(x, y, w, h, color.r, color.g, color.b, color.a);
    }

    pub fn drawRoundedRect(x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
        mac.forge_mac_draw_rounded_rect(x, y, w, h, color.r, color.g, color.b, color.a, radius);
    }

    pub fn drawText(text: []const u8, x: f32, y: f32, font_size: f32, color: Color) void {
        if (text.len == 0) return;
        // Many UI call sites pass stack [:0] buffers via @ptrCast; truncate at first NUL.
        const len = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
        if (len == 0) return;
        mac.forge_mac_draw_text_len(@ptrCast(text.ptr), len, x, y, font_size, color.r, color.g, color.b, color.a);
    }

    pub fn drawStyledText(text: []const u8, x: f32, y: f32, font_size: f32, spans: []const TextSpan) void {
        if (text.len == 0) return;
        if (spans.len == 0) {
            drawText(text, x, y, font_size, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
            return;
        }
        mac.forge_mac_draw_styled_text(@ptrCast(text.ptr), text.len, x, y, font_size, @ptrCast(spans.ptr), spans.len);
    }

    pub fn drawSvg(svg_string: [:0]const u8, x: f32, y: f32, w: f32, h: f32, color: Color) void {
        mac.forge_mac_draw_svg(svg_string.ptr, x, y, w, h, color.r, color.g, color.b, color.a);
    }

    pub fn getResolvedFontName(buf: []u8) void {
        if (buf.len == 0) return;
        mac.forge_mac_get_resolved_font_name(@ptrCast(buf.ptr), buf.len);
    }

    pub const FontWeight = enum(c_int) {
        regular = 0,
        medium = 1,
        semibold = 2,
        bold = 3,
    };

    pub fn setTextStyle(font_family: []const u8, font_weight: FontWeight) void {
        mac.forge_mac_set_text_style(@ptrCast(font_family.ptr), @intFromEnum(font_weight));
        text_style_generation +%= 1;
        clearMeasureCache();
    }

    pub fn applyThemeFont(theme: anytype) void {
        const weight: FontWeight = switch (theme.font_weight) {
            .regular => .regular,
            .medium => .medium,
            .semibold => .semibold,
            .bold => .bold,
        };
        setTextStyle(theme.font_family, weight);
    }

    pub fn setEditorTextMetrics(font_size: f32, line_height: f32, baseline: f32) void {
        mac.forge_mac_set_editor_text_metrics(font_size, line_height, baseline);
    }

    pub fn getFontMetrics(font_size: f32, char_width: *f32, line_height: *f32, baseline: *f32) void {
        mac.forge_mac_get_font_metrics(font_size, char_width, line_height, baseline);
    }

    pub fn measureText(text: []const u8, font_size: f32) f32 {
        if (text.len == 0) return 0;
        const raw_key = measureCacheKey(text, font_size);
        const key = if (raw_key == 0) @as(u64, 1) else raw_key;
        const start = @as(usize, @intCast(key % measure_cache.len));
        var insert_idx = start;
        var probe: usize = 0;
        while (probe < 4) : (probe += 1) {
            const idx = (start + probe) % measure_cache.len;
            const slot = measure_cache[idx];
            if (slot.key == key) {
                measure_cache_hits += 1;
                return slot.width;
            }
            if (slot.key == 0) {
                insert_idx = idx;
                break;
            }
        }

        const width = mac.forge_mac_measure_text_width(@ptrCast(text.ptr), text.len, font_size);
        measure_cache_misses += 1;
        measure_cache[insert_idx] = .{ .key = key, .width = width };
        return width;
    }

    pub fn measureTextCacheStats(hits: *u64, misses: *u64) void {
        hits.* = measure_cache_hits;
        misses.* = measure_cache_misses;
    }

    pub fn setClipboardText(text: []const u8) void {
        if (text.len == 0) return;
        mac.forge_mac_set_clipboard_text(@ptrCast(text.ptr), text.len);
    }

    pub fn clipboardText(allocator: std.mem.Allocator) ![]u8 {
        var buf: [16384]u8 = undefined;
        const len = mac.forge_mac_get_clipboard_text(&buf, buf.len);
        if (len == 0) return try allocator.dupe(u8, "");
        return try allocator.dupe(u8, buf[0..len]);
    }

    pub fn saveClipboardPng(path: []const u8) bool {
        if (path.len == 0) return false;
        return mac.forge_mac_save_clipboard_png(@ptrCast(path.ptr)) == 1;
    }
};

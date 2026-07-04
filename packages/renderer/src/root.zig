const std = @import("std");

pub const mac = @cImport({
    @cInclude("mac_window.h");
});

pub const view = @import("view.zig");
pub const View = view.View;
pub const Rect = view.Rect;
pub const Color = view.Color;

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
        mac.forge_mac_set_clip_rect(x, y, w, h);
    }

    pub fn clearClipRect() void {
        mac.forge_mac_clear_clip_rect();
    }

    pub fn drawRect(x: f32, y: f32, w: f32, h: f32, color: Color) void {
        mac.forge_mac_draw_rect(x, y, w, h, color.r, color.g, color.b, color.a);
    }

    pub fn drawRoundedRect(x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
        mac.forge_mac_draw_rounded_rect(x, y, w, h, color.r, color.g, color.b, color.a, radius);
    }

    pub fn drawText(text: []const u8, x: f32, y: f32, font_size: f32, color: Color) void {
        mac.forge_mac_draw_text(@ptrCast(text.ptr), x, y, font_size, color.r, color.g, color.b, color.a);
    }

    pub fn drawStyledText(text: []const u8, x: f32, y: f32, font_size: f32, spans: []const TextSpan) void {
        if (text.len == 0) return;
        if (spans.len == 0) {
            drawText(text, x, y, font_size, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
            return;
        }
        mac.forge_mac_draw_styled_text(@ptrCast(text.ptr), text.len, x, y, font_size, @ptrCast(spans.ptr), spans.len);
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
        return mac.forge_mac_measure_text_width(@ptrCast(text.ptr), text.len, font_size);
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
};

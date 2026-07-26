//! Login modal — shown when the user is not authenticated. Provides
//! email/password sign-in via Supabase Auth. On success, the session
//! is stored and the IDE switches to the forge_cloud provider.
//!
//! The modal is drawn as a centered dialog on top of a dimmed overlay.
//! It uses two text input buffers (email + password) that the user
//! can type into. Pressing Enter submits the login form.

const std = @import("std");
const renderer = @import("forge-renderer");
const state = @import("../core/state.zig");
const Workbench = @import("../../workbench.zig").Workbench;

/// Draw the login modal overlay.
pub fn drawLoginModal(wb: *Workbench, w: f32, h: f32) void {
    // Dim the background.
    renderer.Renderer.drawRect(0, 0, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 0.7 });

    const box_w: f32 = 420;
    const box_h: f32 = 380;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 2;

    // Drop shadow.
    renderer.Renderer.drawRoundedRect(box_x + 4, box_y + 6, box_w, box_h, 12, .{ .r = 0, .g = 0, .b = 0, .a = 0.4 });
    // Panel background.
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, box_h, 12, .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1.0 });
    // Accent border top.
    renderer.Renderer.drawRoundedRect(box_x, box_y, box_w, 3, 1.5, .{ .r = 0.27, .g = 0.53, .b = 1.0, .a = 1.0 });

    // Title.
    renderer.Renderer.drawText("Forge IDE", box_x + 24, box_y + 24, 20.0, .{ .r = 0.95, .g = 0.96, .b = 1.0, .a = 1.0 });
    renderer.Renderer.drawText("Sign in to your account", box_x + 24, box_y + 52, 13.0, .{ .r = 0.6, .g = 0.65, .b = 0.72, .a = 1.0 });

    // Email label + input.
    renderer.Renderer.drawText("Email", box_x + 24, box_y + 90, 11.0, .{ .r = 0.7, .g = 0.74, .b = 0.8, .a = 1.0 });
    renderer.Renderer.drawRoundedRect(box_x + 24, box_y + 108, box_w - 48, 34, 6, .{ .r = 0.08, .g = 0.09, .b = 0.12, .a = 1.0 });
    // Email input text.
    const email_text = wb.login_email_buffer.content() catch "";
    if (email_text.len > 0) {
        var email_buf: [256:0]u8 = undefined;
        const n = @min(email_text.len, 255);
        @memcpy(email_buf[0..n], email_text[0..n]);
        email_buf[n] = 0;
        renderer.Renderer.drawText(@ptrCast(&email_buf), box_x + 34, box_y + 116, 14.0, .{ .r = 0.9, .g = 0.9, .b = 0.95, .a = 1.0 });
    } else {
        renderer.Renderer.drawText("you@example.com", box_x + 34, box_y + 116, 14.0, .{ .r = 0.4, .g = 0.42, .b = 0.48, .a = 1.0 });
    }
    // Cursor on email field if focused.
    if (wb.login_focused_field == 0) {
        const cursor_x = box_x + 34 + @as(f32, @floatFromInt(email_text.len)) * 8.0;
        const blink = @mod(state.time, 1.0) < 0.5;
        if (blink) {
            renderer.Renderer.drawRect(cursor_x, box_y + 114, 2, 20, .{ .r = 0.4, .g = 0.7, .b = 1.0, .a = 0.8 });
        }
    }

    // Password label + input.
    renderer.Renderer.drawText("Password", box_x + 24, box_y + 158, 11.0, .{ .r = 0.7, .g = 0.74, .b = 0.8, .a = 1.0 });
    renderer.Renderer.drawRoundedRect(box_x + 24, box_y + 176, box_w - 48, 34, 6, .{ .r = 0.08, .g = 0.09, .b = 0.12, .a = 1.0 });
    // Password input (show dots).
    const pass_text = wb.login_password_buffer.content() catch "";
    if (pass_text.len > 0) {
        var dots_buf: [128:0]u8 = undefined;
        const n = @min(pass_text.len, 127);
        @memset(dots_buf[0..n], '*');
        dots_buf[n] = 0;
        renderer.Renderer.drawText(@ptrCast(&dots_buf), box_x + 34, box_y + 184, 14.0, .{ .r = 0.9, .g = 0.9, .b = 0.95, .a = 1.0 });
    } else {
        renderer.Renderer.drawText("••••••••", box_x + 34, box_y + 184, 14.0, .{ .r = 0.4, .g = 0.42, .b = 0.48, .a = 1.0 });
    }
    if (wb.login_focused_field == 1) {
        const cursor_x = box_x + 34 + @as(f32, @floatFromInt(pass_text.len)) * 8.0;
        const blink = @mod(state.time, 1.0) < 0.5;
        if (blink) {
            renderer.Renderer.drawRect(cursor_x, box_y + 182, 2, 20, .{ .r = 0.4, .g = 0.7, .b = 1.0, .a = 0.8 });
        }
    }

    // Error message (if any) — shown inline between password and button.
    if (wb.login_error) |err| {
        var err_buf: [256:0]u8 = undefined;
        const n = @min(err.len, 255);
        @memcpy(err_buf[0..n], err[0..n]);
        err_buf[n] = 0;
        // Red background pill for the error.
        const err_w = @as(f32, @floatFromInt(n)) * 7.0 + 16;
        renderer.Renderer.drawRoundedRect(box_x + 24, box_y + 218, @min(err_w, box_w - 48), 22, 4, .{ .r = 0.3, .g = 0.1, .b = 0.1, .a = 1.0 });
        renderer.Renderer.drawText(@ptrCast(&err_buf), box_x + 32, box_y + 223, 12.0, .{ .r = 1.0, .g = 0.5, .b = 0.5, .a = 1.0 });
    }

    // Sign in button.
    const btn_w: f32 = box_w - 48;
    const btn_h: f32 = 38;
    const btn_x = box_x + 24;
    const btn_y = box_y + 260;
    const btn_hover = !wb.login_in_progress and state.last_mouse_x >= btn_x and state.last_mouse_x < btn_x + btn_w and
        state.last_mouse_y >= btn_y and state.last_mouse_y < btn_y + btn_h;
    const btn_color: renderer.Color = if (wb.login_in_progress)
        .{ .r = 0.12, .g = 0.2, .b = 0.35, .a = 1.0 }
    else if (btn_hover)
        .{ .r = 0.2, .g = 0.4, .b = 0.85, .a = 1.0 }
    else
        .{ .r = 0.15, .g = 0.35, .b = 0.8, .a = 1.0 };
    renderer.Renderer.drawRoundedRect(btn_x, btn_y, btn_w, btn_h, 6, btn_color);
    const btn_text = if (wb.login_in_progress) "Signing in..." else "Sign in";
    const btn_text_color = if (wb.login_in_progress)
        renderer.Color{ .r = 0.6, .g = 0.65, .b = 0.75, .a = 1.0 }
    else
        renderer.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    renderer.Renderer.drawText(btn_text, btn_x + (btn_w - @as(f32, @floatFromInt(btn_text.len)) * 7.0) / 2, btn_y + 11, 14.0, btn_text_color);

    // Hint text.
    renderer.Renderer.drawText("Tab: switch field    Enter: sign in    Esc: skip", box_x + 24, box_y + 320, 11.0, .{ .r = 0.5, .g = 0.55, .b = 0.6, .a = 1.0 });

    // Divider line.
    renderer.Renderer.drawRect(box_x + 24, box_y + 340, box_w - 48, 1, .{ .r = 0.2, .g = 0.22, .b = 0.28, .a = 1.0 });
    renderer.Renderer.drawText("Don't have an account? Sign up at forge.dev", box_x + 24, box_y + 352, 11.0, .{ .r = 0.5, .g = 0.55, .b = 0.65, .a = 1.0 });
}

/// Hit test the login modal. Returns the action to dispatch on click.
pub const LoginAction = enum {
    none,
    email_field,
    password_field,
    sign_in_button,
    skip,
};

pub fn hitTest(w: f32, h: f32, click_x: f32, click_y: f32) LoginAction {
    const box_w: f32 = 420;
    const box_h: f32 = 380;
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 2;

    // Email field.
    if (click_x >= box_x + 24 and click_x < box_x + box_w - 24 and
        click_y >= box_y + 108 and click_y < box_y + 142) return .email_field;

    // Password field.
    if (click_x >= box_x + 24 and click_x < box_x + box_w - 24 and
        click_y >= box_y + 176 and click_y < box_y + 210) return .password_field;

    // Sign in button.
    if (click_x >= box_x + 24 and click_x < box_x + box_w - 24 and
        click_y >= box_y + 260 and click_y < box_y + 298) return .sign_in_button;

    return .none;
}

//! Animation System - Easing Functions, Fade Effects, Smooth Transitions
const std = @import("std");

pub const EasingType = enum {
    linear,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
    ease_in_out_sine,
    bounce,
};

pub const Easing = struct {
    pub fn interpolate(t: f32, easing_type: EasingType) f32 {
        return switch (easing_type) {
            .linear => t,
            .ease_in_quad => t * t,
            .ease_out_quad => t * (2.0 - t),
            .ease_in_out_quad => if (t < 0.5) 2 * t * t else -1 + (4 - 2 * t) * t,
            .ease_in_cubic => t * t * t,
            .ease_out_cubic => 1 - std.math.pow(f32, 1 - t, 3),
            .ease_in_out_cubic => if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 3) / 2,
            .ease_in_out_sine => -(std.math.cos(std.math.pi * t) - 1) / 2,
            .bounce => bounceEase(t),
        };
    }

    fn bounceEase(t: f32) f32 {
        const n1 = 7.5625;
        const d1 = 2.75;
        var x = t;
        
        if (x < 1 / d1) {
            return n1 * x * x;
        } else if (x < 2 / d1) {
            x -= 1.5 / d1;
            return n1 * x * x + 0.75;
        } else if (x < 2.5 / d1) {
            x -= 2.25 / d1;
            return n1 * x * x + 0.9375;
        } else {
            x -= 2.625 / d1;
            return n1 * x * x + 0.984375;
        }
    }
};

pub const Animation = struct {
    start_value: f32,
    end_value: f32,
    current_value: f32,
    duration_ms: u32,
    elapsed_ms: u32,
    easing_type: EasingType,
    running: bool,
    reversed: bool,

    pub fn init(start: f32, end: f32, duration_ms: u32, easing: EasingType) Animation {
        return .{
            .start_value = start,
            .end_value = end,
            .current_value = start,
            .duration_ms = duration_ms,
            .elapsed_ms = 0,
            .easing_type = easing,
            .running = true,
            .reversed = false,
        };
    }

    pub fn update(self: *Animation, delta_ms: u32) bool {
        if (!self.running) return false;
        
        self.elapsed_ms += delta_ms;
        if (self.elapsed_ms >= self.duration_ms) {
            self.elapsed_ms = self.duration_ms;
            self.running = false;
        }
        
        const t = @as(f32, @floatFromInt(self.elapsed_ms)) / @as(f32, @floatFromInt(self.duration_ms));
        const eased_t = Easing.interpolate(t, self.easing_type);
        
        if (self.reversed) {
            self.current_value = self.end_value + (self.start_value - self.end_value) * eased_t;
        } else {
            self.current_value = self.start_value + (self.end_value - self.start_value) * eased_t;
        }
        
        return self.running;
    }

    pub fn getValue(self: *Animation) f32 {
        return self.current_value;
    }

    pub fn start(self: *Animation) void {
        self.running = true;
        self.elapsed_ms = 0;
    }

    pub fn stop(self: *Animation) void {
        self.running = false;
    }

    pub fn reverse(self: *Animation) void {
        self.reversed = !self.reversed;
        self.start();
    }
};

pub const FadeEffect = struct {
    animation: Animation,
    visible: bool,

    pub fn init(duration_ms: u32) FadeEffect {
        return .{
            .animation = Animation.init(0.0, 1.0, duration_ms, .ease_in_out_sine),
            .visible = false,
        };
    }

    pub fn fadeIn(self: *FadeEffect) void {
        self.visible = true;
        self.animation.reversed = false;
        self.animation.start();
    }

    pub fn fadeOut(self: *FadeEffect) void {
        self.animation.reversed = true;
        self.animation.start();
    }

    pub fn update(self: *FadeEffect, delta_ms: u32) f32 {
        _ = self.animation.update(delta_ms);
        if (!self.animation.running and self.animation.reversed) {
            self.visible = false;
        }
        return self.animation.getValue();
    }

    pub fn getAlpha(self: *FadeEffect) f32 {
        return if (self.visible) self.animation.getValue() else 0.0;
    }
};

pub const SmoothScroll = struct {
    current_position: f32,
    target_position: f32,
    velocity: f32,
    friction: f32,

    pub fn init() SmoothScroll {
        return .{
            .current_position = 0.0,
            .target_position = 0.0,
            .velocity = 0.0,
            .friction = 0.85,
        };
    }

    pub fn scrollTo(self: *SmoothScroll, target: f32) void {
        self.target_position = target;
        self.velocity += (target - self.current_position) * 0.1;
    }

    pub fn update(self: *SmoothScroll) f32 {
        self.velocity *= self.friction;
        self.current_position += self.velocity;
        
        if (std.math.absFloat(self.velocity) < 0.01) {
            self.current_position = self.target_position;
            self.velocity = 0.0;
        }
        
        return self.current_position;
    }
};

test "Easing functions" {
    try std.testing.expectEqual(@as(f32, 0.0), Easing.interpolate(0.0, .linear));
    try std.testing.expectEqual(@as(f32, 1.0), Easing.interpolate(1.0, .linear));
    try std.testing.expectEqual(@as(f32, 0.25), Easing.interpolate(0.5, .ease_in_quad));
}

test "Animation completes" {
    var anim = Animation.init(0.0, 100.0, 1000, .linear);
    _ = anim.update(500);
    try std.testing.expectEqual(@as(f32, 50.0), anim.getValue());
    _ = anim.update(500);
    try std.testing.expectEqual(false, anim.running);
}

test "FadeEffect visibility" {
    var fade = FadeEffect.init(300);
    fade.fadeIn();
    try std.testing.expectEqual(true, fade.visible);
    _ = fade.update(300);
    try std.testing.expectEqual(true, fade.visible);
}

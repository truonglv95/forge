//! UI animations — subtle transitions for panel collapse, tab switch,
//! and other interactive elements.
//!
//! Design principles:
//! - Subtle: 150-250ms duration, ease-out curves
//! - Non-blocking: animations update visual state only, never block input
//! - Cancellable: new animation replaces in-progress one
//! - Frame-rate independent: uses delta time

const std = @import("std");

/// Animation duration constants (milliseconds).
pub const Duration = struct {
    pub const fast: f32 = 120; // hover, small state changes
    pub const normal: f32 = 200; // panel collapse, tab switch
    pub const slow: f32 = 300; // modal open, large transitions
};

/// Easing functions — all take t in [0, 1] and return eased value.
pub const Ease = struct {
    pub fn linear(t: f32) f32 {
        return t;
    }

    pub fn easeOut(t: f32) f32 {
        return 1 - (1 - t) * (1 - t);
    }

    pub fn easeInOut(t: f32) f32 {
        return if (t < 0.5)
            2 * t * t
        else
            1 - std.math.pow(f32, -2 * t + 2, 2) / 2;
    }

    pub fn easeOutCubic(t: f32) f32 {
        return 1 - std.math.pow(f32, 1 - t, 3);
    }
};

/// A single animated value. Tracks current state and target.
/// Call `update(delta_ms)` each frame; `value()` returns interpolated.
pub const AnimatedValue = struct {
    current: f32,
    target: f32,
    start: f32,
    elapsed_ms: f32 = 0,
    duration_ms: f32 = Duration.normal,
    easing: *const fn (f32) f32 = Ease.easeOut,
    active: bool = false,

    pub fn init(initial: f32) AnimatedValue {
        return .{
            .current = initial,
            .target = initial,
            .start = initial,
        };
    }

    /// Set a new target. The animation will transition from current value.
    pub fn animateTo(self: *AnimatedValue, target: f32, duration_ms: f32, easing: *const fn (f32) f32) void {
        if (std.math.approxEqAbs(f32, target, self.current, 0.001)) {
            self.active = false;
            return;
        }
        self.start = self.current;
        self.target = target;
        self.elapsed_ms = 0;
        self.duration_ms = duration_ms;
        self.easing = easing;
        self.active = true;
    }

    /// Advance the animation by delta_ms milliseconds.
    pub fn update(self: *AnimatedValue, delta_ms: f32) void {
        if (!self.active) return;
        self.elapsed_ms += delta_ms;
        const t = std.math.clamp(self.elapsed_ms / self.duration_ms, 0, 1);
        const eased = self.easing(t);
        self.current = self.start + (self.target - self.start) * eased;
        if (t >= 1.0) {
            self.current = self.target;
            self.active = false;
        }
    }

    /// Skip to final state instantly.
    pub fn complete(self: *AnimatedValue) void {
        self.current = self.target;
        self.active = false;
    }

    /// Whether animation is currently running.
    pub fn isAnimating(self: *const AnimatedValue) bool {
        return self.active;
    }
};

/// Panel collapse animation — animates width/height between expanded and collapsed.
pub const PanelAnimation = struct {
    width: AnimatedValue,
    opacity: AnimatedValue,

    pub fn init(initial_width: f32) PanelAnimation {
        return .{
            .width = AnimatedValue.init(initial_width),
            .opacity = AnimatedValue.init(1.0),
        };
    }

    pub fn collapse(self: *PanelAnimation, target_width: f32) void {
        self.width.animateTo(target_width, Duration.normal, Ease.easeOutCubic);
        self.opacity.animateTo(0.0, Duration.fast, Ease.easeOut);
    }

    pub fn expand(self: *PanelAnimation, target_width: f32) void {
        self.width.animateTo(target_width, Duration.normal, Ease.easeOutCubic);
        self.opacity.animateTo(1.0, Duration.fast, Ease.easeOut);
    }

    pub fn update(self: *PanelAnimation, delta_ms: f32) void {
        self.width.update(delta_ms);
        self.opacity.update(delta_ms);
    }
};

/// Tab switch animation — fades between tabs.
pub const TabSwitchAnimation = struct {
    fade: AnimatedValue,
    slide_offset: AnimatedValue,

    pub fn init() TabSwitchAnimation {
        return .{
            .fade = AnimatedValue.init(1.0),
            .slide_offset = AnimatedValue.init(0.0),
        };
    }

    pub fn trigger(self: *TabSwitchAnimation) void {
        // Fade out then in: set to 0 then back to 1.
        self.fade.animateTo(0.0, Duration.fast, Ease.easeOut);
        self.slide_offset.animateTo(8.0, Duration.fast, Ease.easeOut);
        // Note: caller should trigger expand back to 1.0 after fade out.
    }

    pub fn triggerIn(self: *TabSwitchAnimation) void {
        self.fade.animateTo(1.0, Duration.normal, Ease.easeOutCubic);
        self.slide_offset.animateTo(0.0, Duration.normal, Ease.easeOutCubic);
    }

    pub fn update(self: *TabSwitchAnimation, delta_ms: f32) void {
        self.fade.update(delta_ms);
        self.slide_offset.update(delta_ms);
    }
};

test "AnimatedValue transitions to target" {
    var av = AnimatedValue.init(0.0);
    av.animateTo(100.0, 100.0, Ease.linear);
    try std.testing.expect(av.isAnimating());

    av.update(50.0); // half way
    try std.testing.expect(std.math.approxEqAbs(f32, av.current, 50.0, 0.01));
    try std.testing.expect(av.isAnimating());

    av.update(50.0); // complete
    try std.testing.expect(std.math.approxEqAbs(f32, av.current, 100.0, 0.01));
    try std.testing.expect(!av.isAnimating());
}

test "AnimatedValue complete skips to end" {
    var av = AnimatedValue.init(0.0);
    av.animateTo(100.0, 1000.0, Ease.easeOut);
    av.complete();
    try std.testing.expectEqual(@as(f32, 100.0), av.current);
    try std.testing.expect(!av.isAnimating());
}

test "Ease.easeOut at boundaries" {
    try std.testing.expect(std.math.approxEqAbs(f32, Ease.easeOut(0.0), 0.0, 0.001));
    try std.testing.expect(std.math.approxEqAbs(f32, Ease.easeOut(1.0), 1.0, 0.001));
}

test "Ease.easeInOut midpoint" {
    try std.testing.expect(std.math.approxEqAbs(f32, Ease.easeInOut(0.5), 0.5, 0.01));
}

test "PanelAnimation collapse sets opacity to 0" {
    var panel = PanelAnimation.init(300.0);
    panel.collapse(0.0);
    panel.update(200.0);
    try std.testing.expect(panel.opacity.current < 0.5);
}

test "TabSwitchAnimation trigger starts fade out" {
    var tab = TabSwitchAnimation.init();
    tab.trigger();
    try std.testing.expect(tab.fade.isAnimating());
    tab.update(60.0);
    try std.testing.expect(tab.fade.current < 1.0);
}

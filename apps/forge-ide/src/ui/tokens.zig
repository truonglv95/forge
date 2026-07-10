const renderer = @import("forge-renderer");

pub const space = struct {
    pub const xs: f32 = 4;
    pub const sm: f32 = 6;
    pub const md: f32 = 8;
    pub const lg: f32 = 12;
    pub const xl: f32 = 16;
    pub const xxl: f32 = 20;
};

pub const radius = struct {
    pub const sm: f32 = 4;
    pub const md: f32 = 6;
    pub const lg: f32 = 10;
};

pub const font = struct {
    pub const caption: f32 = 11.0;
    pub const body: f32 = 14.0;
    pub const body_line: f32 = 18.0;
    pub const code: f32 = 12.0;
    pub const code_line: f32 = 21.0;
    pub const heading: f32 = 15.0;
    pub const heading_line: f32 = 20.0;
};

pub const color = struct {
    pub const surface: renderer.Color = .{ .r = 0.055, .g = 0.055, .b = 0.06, .a = 1.0 };
    pub const surface_raised: renderer.Color = .{ .r = 0.14, .g = 0.14, .b = 0.15, .a = 1.0 };
    pub const surface_recessed: renderer.Color = .{ .r = 0.1, .g = 0.11, .b = 0.14, .a = 1.0 };
    pub const border: renderer.Color = .{ .r = 0.22, .g = 0.22, .b = 0.24, .a = 1.0 };
    pub const text_primary: renderer.Color = .{ .r = 0.88, .g = 0.9, .b = 0.94, .a = 1.0 };
    pub const text_secondary: renderer.Color = .{ .r = 0.72, .g = 0.76, .b = 0.82, .a = 1.0 };
    pub const text_muted: renderer.Color = .{ .r = 0.6, .g = 0.6, .b = 0.65, .a = 1.0 };
    pub const accent: renderer.Color = .{ .r = 0.4, .g = 0.7, .b = 1.0, .a = 1.0 };
    pub const success: renderer.Color = .{ .r = 0.2, .g = 0.8, .b = 0.4, .a = 1.0 };
    pub const warning: renderer.Color = .{ .r = 0.95, .g = 0.72, .b = 0.4, .a = 1.0 };
    pub const danger: renderer.Color = .{ .r = 0.95, .g = 0.45, .b = 0.45, .a = 1.0 };
    pub const code_fg: renderer.Color = .{ .r = 0.88, .g = 0.9, .b = 0.94, .a = 1.0 };
    pub const inline_code_fg: renderer.Color = .{ .r = 0.85, .g = 0.92, .b = 1.0, .a = 1.0 };
    pub const inline_code_bg: renderer.Color = .{ .r = 0.22, .g = 0.24, .b = 0.3, .a = 1.0 };
};

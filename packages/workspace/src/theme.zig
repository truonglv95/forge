const std = @import("std");

pub const FontWeight = enum {
    regular,
    medium,
    semibold,
    bold,

    pub fn parse(value: []const u8) ?FontWeight {
        return std.meta.stringToEnum(FontWeight, value);
    }
};

pub const ThemePreset = enum {
    dark,
    light,

    pub fn parse(value: []const u8) ?ThemePreset {
        return std.meta.stringToEnum(ThemePreset, value);
    }
};

pub const Rgba = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub fn hex(value: []const u8) error{InvalidHex}!Rgba {
        if (value.len != 7 or value[0] != '#') return error.InvalidHex;
        return .{
            .r = @as(f32, @floatFromInt(try parseHexByte(value[1..3]))) / 255.0,
            .g = @as(f32, @floatFromInt(try parseHexByte(value[3..5]))) / 255.0,
            .b = @as(f32, @floatFromInt(try parseHexByte(value[5..7]))) / 255.0,
        };
    }
};

fn parseHexByte(digits: []const u8) error{InvalidHex}!u8 {
    var value: u8 = 0;
    for (digits) |digit| {
        value *%= 16;
        value += switch (digit) {
            '0'...'9' => digit - '0',
            'a'...'f' => digit - 'a' + 10,
            'A'...'F' => digit - 'A' + 10,
            else => return error.InvalidHex,
        };
    }
    return value;
}

pub const Palette = struct {
    workbench_bg: Rgba,
    header_bg: Rgba,
    activity_bg: Rgba,
    sidebar_bg: Rgba,
    agent_bg: Rgba,
    editor_bg: Rgba,
    tab_bar_bg: Rgba,
    tab_active_bg: Rgba,
    panel_bg: Rgba,
    status_bg: Rgba,
    border: Rgba,
    text_primary: Rgba,
    text_secondary: Rgba,
    text_muted: Rgba,
    editor_fg: Rgba,
    line_number: Rgba,
    cursor: Rgba,
    keyword: Rgba,
    number: Rgba,
    punctuation: Rgba,
    string_color: Rgba,
    type: Rgba,
    parameter: Rgba,
    variable: Rgba,
    property: Rgba,
    function: Rgba,
    comment: Rgba,
    diff_add: Rgba,
    diff_remove: Rgba,
    accent: Rgba,
    accent_soft: Rgba,
    selection: Rgba,
    warning: Rgba,
};

pub const ThemeSettings = struct {
    preset: ThemePreset = .dark,
    font_family: []const u8 = "Menlo",
    ui_font_family: []const u8 = "Inter",
    font_size: f32 = 14,
    font_weight: FontWeight = .regular,
    line_height: f32 = 1.5,
    ui_font_size: f32 = 13,
    background: ?Rgba = null,
    foreground: ?Rgba = null,
    keyword: ?Rgba = null,
    string_color: ?Rgba = null,
    number: ?Rgba = null,
    accent: ?Rgba = null,

    pub fn mergeFrom(self: *ThemeSettings, override: ThemeOverrides) void {
        if (override.preset) |v| self.preset = v;
        if (override.font_family) |v| self.font_family = v;
        if (override.ui_font_family) |v| self.ui_font_family = v;
        if (override.font_size) |v| self.font_size = v;
        if (override.font_weight) |v| self.font_weight = v;
        if (override.line_height) |v| self.line_height = v;
        if (override.ui_font_size) |v| self.ui_font_size = v;
        if (override.background) |c| self.background = c;
        if (override.foreground) |c| self.foreground = c;
        if (override.keyword) |c| self.keyword = c;
        if (override.string_color) |c| self.string_color = c;
        if (override.number) |c| self.number = c;
        if (override.accent) |c| self.accent = c;
    }

    pub fn parseSection(source: []const u8) error{ InvalidSyntax, InvalidValue }!ThemeOverrides {
        var overrides = ThemeOverrides{};
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index|
                raw_line[0..index]
            else
                raw_line;
            const line = std.mem.trim(u8, &std.ascii.whitespace, without_comment);
            if (line.len == 0) continue;
            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidSyntax;
                section = std.mem.trim(u8, &std.ascii.whitespace, line[1 .. line.len - 1]);
                continue;
            }
            if (!std.mem.eql(u8, section, "theme")) continue;
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSyntax;
            const key = std.mem.trim(u8, &std.ascii.whitespace, line[0..equals]);
            const value = std.mem.trim(u8, &std.ascii.whitespace, line[equals + 1 ..]);
            try overrides.applyKey(key, value);
        }
        return overrides;
    }

    pub fn applyKey(self: *ThemeSettings, key: []const u8, value: []const u8) error{InvalidValue}!void {
        if (std.mem.eql(u8, key, "preset")) {
            self.preset = ThemePreset.parse(try parseStringValue(value)) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "font_family")) {
            self.font_family = try parseStringValue(value);
        } else if (std.mem.eql(u8, key, "ui_font_family")) {
            self.ui_font_family = try parseStringValue(value);
        } else if (std.mem.eql(u8, key, "font_size")) {
            self.font_size = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            if (self.font_size < 8 or self.font_size > 32) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "font_weight")) {
            self.font_weight = FontWeight.parse(try parseStringValue(value)) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "line_height")) {
            self.line_height = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            if (self.line_height < 1.0 or self.line_height > 2.5) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "ui_font_size")) {
            self.ui_font_size = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            if (self.ui_font_size < 8 or self.ui_font_size > 24) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "background")) {
            self.background = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "foreground")) {
            self.foreground = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "keyword")) {
            self.keyword = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "string")) {
            self.string_color = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "number")) {
            self.number = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "accent")) {
            self.accent = try parseColorValue(value);
        } else {
            return error.InvalidValue;
        }
    }
};

fn parseStringValue(value: []const u8) error{InvalidValue}![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidValue;
    return value[1 .. value.len - 1];
}

fn parseColorValue(value: []const u8) error{InvalidValue}!Rgba {
    const raw = try parseStringValue(value);
    return Rgba.hex(raw) catch error.InvalidValue;
}

pub const ThemeOverrides = struct {
    preset: ?ThemePreset = null,
    font_family: ?[]const u8 = null,
    ui_font_family: ?[]const u8 = null,
    font_size: ?f32 = null,
    font_weight: ?FontWeight = null,
    line_height: ?f32 = null,
    ui_font_size: ?f32 = null,
    background: ?Rgba = null,
    foreground: ?Rgba = null,
    keyword: ?Rgba = null,
    string_color: ?Rgba = null,
    number: ?Rgba = null,
    accent: ?Rgba = null,

    pub fn applyKey(self: *ThemeOverrides, key: []const u8, value: []const u8) error{InvalidValue}!void {
        if (std.mem.eql(u8, key, "preset")) {
            self.preset = ThemePreset.parse(try parseStringValue(value)) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "font_family")) {
            self.font_family = try parseStringValue(value);
        } else if (std.mem.eql(u8, key, "ui_font_family")) {
            self.ui_font_family = try parseStringValue(value);
        } else if (std.mem.eql(u8, key, "font_size")) {
            const size = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            if (size < 8 or size > 32) return error.InvalidValue;
            self.font_size = size;
        } else if (std.mem.eql(u8, key, "font_weight")) {
            self.font_weight = FontWeight.parse(try parseStringValue(value)) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "line_height")) {
            const lh = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            if (lh < 1.0 or lh > 2.5) return error.InvalidValue;
            self.line_height = lh;
        } else if (std.mem.eql(u8, key, "ui_font_size")) {
            const size = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
            if (size < 8 or size > 24) return error.InvalidValue;
            self.ui_font_size = size;
        } else if (std.mem.eql(u8, key, "background")) {
            self.background = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "foreground")) {
            self.foreground = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "keyword")) {
            self.keyword = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "string")) {
            self.string_color = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "number")) {
            self.number = try parseColorValue(value);
        } else if (std.mem.eql(u8, key, "accent")) {
            self.accent = try parseColorValue(value);
        } else {
            return error.InvalidValue;
        }
    }
};

pub const Theme = struct {
    preset: ThemePreset,
    font_family: []const u8,
    ui_font_family: []const u8,
    editor_font_size: f32,
    ui_font_size: f32,
    font_weight: FontWeight,
    line_height_scale: f32,
    tab_width: u8,
    colors: Palette,
    measured_char_width: f32 = 0,
    measured_line_height: f32 = 0,
    measured_baseline: f32 = 0,
    owned_family: ?[]const u8 = null,
    owned_ui_family: ?[]const u8 = null,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Theme) void {
        if (self.owned_family) |family| {
            if (self.allocator) |allocator| allocator.free(family);
        }
        if (self.owned_ui_family) |family| {
            if (self.allocator) |allocator| allocator.free(family);
        }
        self.* = undefined;
    }

    pub fn lineHeight(self: Theme) f32 {
        if (self.measured_line_height > 0) {
            return self.measured_line_height * self.line_height_scale;
        }
        return self.editor_font_size * self.line_height_scale;
    }

    pub fn charWidth(self: Theme) f32 {
        if (self.measured_char_width > 0) return self.measured_char_width;
        return self.editor_font_size * 0.686;
    }

    pub fn baseline(self: Theme) f32 {
        if (self.measured_baseline > 0) return self.measured_baseline;
        return self.editor_font_size;
    }

    pub fn gutterWidth(self: Theme) f32 {
        _ = self;
        return 50;
    }

    pub fn fromSettings(allocator: std.mem.Allocator, tab_width: u8, settings: ThemeSettings) !Theme {
        var theme = presetPalette(settings.preset);
        theme.preset = settings.preset;
        theme.tab_width = tab_width;
        theme.editor_font_size = settings.font_size;
        theme.ui_font_size = settings.ui_font_size;
        theme.font_weight = settings.font_weight;
        theme.line_height_scale = settings.line_height;
        theme.font_family = try allocator.dupe(u8, settings.font_family);
        theme.owned_family = theme.font_family;
        theme.ui_font_family = try allocator.dupe(u8, settings.ui_font_family);
        theme.owned_ui_family = theme.ui_font_family;
        theme.allocator = allocator;

        if (settings.background) |color| theme.colors.editor_bg = color;
        if (settings.foreground) |color| theme.colors.editor_fg = color;
        if (settings.keyword) |color| theme.colors.keyword = color;
        if (settings.string_color) |color| theme.colors.string_color = color;
        if (settings.number) |color| theme.colors.number = color;
        if (settings.accent) |color| {
            theme.colors.accent = color;
            theme.colors.accent_soft = color;
        }

        return theme;
    }

    pub fn darkDefault() Theme {
        var theme = presetPalette(.dark);
        theme.font_family = "Menlo";
        theme.ui_font_family = "Inter";
        return theme;
    }

    pub fn lightDefault() Theme {
        var theme = presetPalette(.light);
        theme.font_family = "Menlo";
        theme.ui_font_family = "Inter";
        return theme;
    }
};

fn presetPalette(preset: ThemePreset) Theme {
    return switch (preset) {
        .dark => .{
            .preset = .dark,
            .font_family = "Menlo",
            .ui_font_family = "Inter",
            .editor_font_size = 14,
            .ui_font_size = 13,
            .font_weight = .regular,
            .line_height_scale = 1.5,
            .tab_width = 4,
            .colors = .{
                // Modern dark palette — inspired by VSCode Modern Dark / Cursor
                // Deeper backgrounds with subtle blue tint for depth
                .workbench_bg = .{ .r = 0.094, .g = 0.094, .b = 0.110 }, // #181820
                .header_bg = .{ .r = 0.094, .g = 0.094, .b = 0.110 },
                .activity_bg = .{ .r = 0.078, .g = 0.078, .b = 0.094 }, // #141418
                .sidebar_bg = .{ .r = 0.086, .g = 0.086, .b = 0.102 }, // #16161a
                .agent_bg = .{ .r = 0.102, .g = 0.102, .b = 0.118 }, // #1a1a1e
                .editor_bg = .{ .r = 0.094, .g = 0.094, .b = 0.110 }, // #181820
                .tab_bar_bg = .{ .r = 0.078, .g = 0.078, .b = 0.094 },
                .tab_active_bg = .{ .r = 0.094, .g = 0.094, .b = 0.110 },
                .panel_bg = .{ .r = 0.086, .g = 0.086, .b = 0.102 },
                .status_bg = .{ .r = 0.063, .g = 0.063, .b = 0.078 }, // #101014
                .border = .{ .r = 0.165, .g = 0.165, .b = 0.196 }, // #2a2a32
                .text_primary = .{ .r = 0.933, .g = 0.933, .b = 0.953 }, // #eeeef3
                .text_secondary = .{ .r = 0.733, .g = 0.733, .b = 0.773 }, // #bbbbcc
                .text_muted = .{ .r = 0.533, .g = 0.533, .b = 0.573 }, // #888899
                .editor_fg = .{ .r = 0.882, .g = 0.882, .b = 0.922 }, // #e1e1eb
                .line_number = .{ .r = 0.373, .g = 0.373, .b = 0.412 }, // #5f5f6a
                .cursor = .{ .r = 0.533, .g = 0.733, .b = 1.0 }, // #88bbff
                // Syntax — modern vibrant but not harsh
                .keyword = .{ .r = 0.533, .g = 0.6, .b = 1.0 }, // #8899ff purple-blue
                .number = .{ .r = 0.933, .g = 0.667, .b = 0.467 }, // #eeaa77 orange
                .punctuation = .{ .r = 0.6, .g = 0.6, .b = 0.667 }, // #9999aa
                .string_color = .{ .r = 0.733, .g = 0.867, .b = 0.533 }, // #bbdd88 green
                .type = .{ .r = 0.467, .g = 0.867, .b = 0.867 }, // #77dddd teal
                .parameter = .{ .r = 0.933, .g = 0.733, .b = 0.533 }, // #eebb88
                .variable = .{ .r = 0.733, .g = 0.8, .b = 0.933 }, // #bbccdd
                .property = .{ .r = 0.6, .g = 0.733, .b = 0.933 }, // #99bbee
                .function = .{ .r = 0.933, .g = 0.8, .b = 0.467 }, // #eecc77 yellow
                .comment = .{ .r = 0.4, .g = 0.467, .b = 0.533 }, // #667788 muted
                .diff_add = .{ .r = 0.2, .g = 0.533, .b = 0.267 }, // #338844
                .diff_remove = .{ .r = 0.733, .g = 0.267, .b = 0.267 }, // #bb4444
                .accent = .{ .r = 0.267, .g = 0.533, .b = 1.0 }, // #4488ff blue
                .accent_soft = .{ .r = 0.2, .g = 0.333, .b = 0.533 }, // #335588
                .selection = .{ .r = 0.2, .g = 0.333, .b = 0.533 },
                .warning = .{ .r = 0.933, .g = 0.733, .b = 0.2 }, // #eebb33
            },
        },
        .light => .{
            .preset = .light,
            .font_family = "Menlo",
            .ui_font_family = "Inter",
            .editor_font_size = 14,
            .ui_font_size = 13,
            .font_weight = .regular,
            .line_height_scale = 1.5,
            .tab_width = 4,
            .colors = .{
                // Modern light palette — clean, high-contrast, warm whites
                .workbench_bg = .{ .r = 0.984, .g = 0.984, .b = 0.988 }, // #fbfbfc
                .header_bg = .{ .r = 0.972, .g = 0.972, .b = 0.976 }, // #f8f8fa
                .activity_bg = .{ .r = 0.965, .g = 0.965, .b = 0.972 }, // #f6f6f8
                .sidebar_bg = .{ .r = 0.976, .g = 0.976, .b = 0.980 }, // #f9f9fa
                .agent_bg = .{ .r = 0.992, .g = 0.992, .b = 0.996 }, // #fdfdfe
                .editor_bg = .{ .r = 1.0, .g = 1.0, .b = 1.0 }, // #ffffff
                .tab_bar_bg = .{ .r = 0.965, .g = 0.965, .b = 0.972 },
                .tab_active_bg = .{ .r = 1.0, .g = 1.0, .b = 1.0 },
                .panel_bg = .{ .r = 0.980, .g = 0.980, .b = 0.984 },
                .status_bg = .{ .r = 0.0, .g = 0.42, .b = 0.72 },
                .border = .{ .r = 0.890, .g = 0.890, .b = 0.902 }, // #e3e3e6
                .text_primary = .{ .r = 0.094, .g = 0.094, .b = 0.110 }, // #181820
                .text_secondary = .{ .r = 0.290, .g = 0.290, .b = 0.322 }, // #4a4a52
                .text_muted = .{ .r = 0.490, .g = 0.490, .b = 0.522 }, // #7d7d85
                .editor_fg = .{ .r = 0.133, .g = 0.133, .b = 0.157 }, // #222228
                .line_number = .{ .r = 0.620, .g = 0.620, .b = 0.651 }, // #9e9ea6
                .cursor = .{ .r = 0.10, .g = 0.34, .b = 0.94 }, // #1a57f0
                // Syntax — clean, readable, distinct
                .keyword = .{ .r = 0.50, .g = 0.20, .b = 0.78 }, // #8033c7 purple
                .number = .{ .r = 0.80, .g = 0.40, .b = 0.10 }, // #cc6619 orange
                .punctuation = .{ .r = 0.40, .g = 0.40, .b = 0.45 }, // #666673
                .string_color = .{ .r = 0.20, .g = 0.55, .b = 0.25 }, // #338c40 green
                .type = .{ .r = 0.05, .g = 0.45, .b = 0.55 }, // #0d738c teal
                .parameter = .{ .r = 0.75, .g = 0.40, .b = 0.10 }, // #bf6619
                .variable = .{ .r = 0.20, .g = 0.30, .b = 0.55 }, // #334d8c
                .property = .{ .r = 0.50, .g = 0.20, .b = 0.55 }, // #80338c
                .function = .{ .r = 0.65, .g = 0.40, .b = 0.05 }, // #a6660d amber
                .comment = .{ .r = 0.45, .g = 0.50, .b = 0.55 }, // #737f88 muted
                .diff_add = .{ .r = 0.20, .g = 0.55, .b = 0.25 }, // #338c40
                .diff_remove = .{ .r = 0.80, .g = 0.20, .b = 0.20 }, // #cc3333
                .accent = .{ .r = 0.10, .g = 0.34, .b = 0.94 }, // #1a57f0 blue
                .accent_soft = .{ .r = 0.86, .g = 0.91, .b = 0.98 }, // #dbe8fa
                .selection = .{ .r = 0.78, .g = 0.85, .b = 0.96 },
                .warning = .{ .r = 0.80, .g = 0.50, .b = 0.0 }, // #cc8000
            },
        },
    };
}

test "theme derives editor metrics from font size" {
    const theme = Theme.darkDefault();
    try std.testing.expect(theme.lineHeight() > theme.editor_font_size);
    try std.testing.expect(theme.charWidth() > 0);
}

test "hex color parsing" {
    const color = try Rgba.hex("#1e1e1e");
    try std.testing.expect(color.r < 0.2);
}

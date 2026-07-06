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
    font_size: f32 = 14,
    font_weight: FontWeight = .regular,
    line_height: f32 = 1.5,
    ui_font_size: f32 = 12,
    background: ?Rgba = null,
    foreground: ?Rgba = null,
    keyword: ?Rgba = null,
    string_color: ?Rgba = null,
    number: ?Rgba = null,
    accent: ?Rgba = null,

    pub fn mergeFrom(self: *ThemeSettings, override: ThemeOverrides) void {
        if (override.preset) |v| self.preset = v;
        if (override.font_family) |v| self.font_family = v;
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
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Theme) void {
        if (self.owned_family) |family| {
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
        return theme;
    }
};

fn presetPalette(preset: ThemePreset) Theme {
    return switch (preset) {
        .dark => .{
            .preset = .dark,
            .font_family = "Menlo",
            .editor_font_size = 14,
            .ui_font_size = 12,
            .font_weight = .regular,
            .line_height_scale = 1.5,
            .tab_width = 4,
            .colors = .{
                .workbench_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .header_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .activity_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .sidebar_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .agent_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .editor_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .tab_bar_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .tab_active_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .panel_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .status_bg = .{ .r = 0.05, .g = 0.05, .b = 0.05 },
                .border = .{ .r = 0.12, .g = 0.12, .b = 0.12 },
                .text_primary = .{ .r = 0.92, .g = 0.92, .b = 0.92 },
                .text_secondary = .{ .r = 0.8, .g = 0.8, .b = 0.8 },
                .text_muted = .{ .r = 0.55, .g = 0.55, .b = 0.55 },
                .editor_fg = .{ .r = 0.9, .g = 0.9, .b = 0.9 },
                .line_number = .{ .r = 0.5, .g = 0.5, .b = 0.5 },
                .cursor = .{ .r = 1.0, .g = 1.0, .b = 1.0 },
                .keyword = .{ .r = 0.9, .g = 0.4, .b = 0.7 },
                .number = .{ .r = 0.5, .g = 0.8, .b = 0.5 },
                .punctuation = .{ .r = 0.6, .g = 0.6, .b = 0.6 },
                .string_color = .{ .r = 0.85, .g = 0.75, .b = 0.55 },
                .diff_add = .{ .r = 0.5, .g = 0.9, .b = 0.5 },
                .diff_remove = .{ .r = 0.95, .g = 0.45, .b = 0.45 },
                .accent = .{ .r = 0.15, .g = 0.35, .b = 0.55 },
                .accent_soft = .{ .r = 0.22, .g = 0.35, .b = 0.55 },
                .selection = .{ .r = 0.22, .g = 0.22, .b = 0.26 },
                .warning = .{ .r = 1.0, .g = 0.6, .b = 0.2 },
            },
        },
        .light => .{
            .preset = .light,
            .font_family = "Menlo",
            .editor_font_size = 14,
            .ui_font_size = 12,
            .font_weight = .regular,
            .line_height_scale = 1.5,
            .tab_width = 4,
            .colors = .{
                .workbench_bg = .{ .r = 0.96, .g = 0.96, .b = 0.96 },
                .header_bg = .{ .r = 0.88, .g = 0.88, .b = 0.88 },
                .activity_bg = .{ .r = 0.9, .g = 0.9, .b = 0.9 },
                .sidebar_bg = .{ .r = 0.93, .g = 0.93, .b = 0.94 },
                .agent_bg = .{ .r = 0.95, .g = 0.95, .b = 0.96 },
                .editor_bg = .{ .r = 1.0, .g = 1.0, .b = 1.0 },
                .tab_bar_bg = .{ .r = 0.9, .g = 0.9, .b = 0.9 },
                .tab_active_bg = .{ .r = 1.0, .g = 1.0, .b = 1.0 },
                .panel_bg = .{ .r = 0.98, .g = 0.98, .b = 0.98 },
                .status_bg = .{ .r = 0.0, .g = 0.42, .b = 0.72 },
                .border = .{ .r = 0.78, .g = 0.78, .b = 0.78 },
                .text_primary = .{ .r = 0.12, .g = 0.12, .b = 0.12 },
                .text_secondary = .{ .r = 0.25, .g = 0.25, .b = 0.25 },
                .text_muted = .{ .r = 0.45, .g = 0.45, .b = 0.45 },
                .editor_fg = .{ .r = 0.12, .g = 0.12, .b = 0.12 },
                .line_number = .{ .r = 0.55, .g = 0.55, .b = 0.55 },
                .cursor = .{ .r = 0.0, .g = 0.0, .b = 0.0 },
                .keyword = .{ .r = 0.0, .g = 0.0, .b = 0.8 },
                .number = .{ .r = 0.08, .g = 0.55, .b = 0.08 },
                .punctuation = .{ .r = 0.35, .g = 0.35, .b = 0.35 },
                .string_color = .{ .r = 0.65, .g = 0.2, .b = 0.2 },
                .diff_add = .{ .r = 0.1, .g = 0.55, .b = 0.1 },
                .diff_remove = .{ .r = 0.75, .g = 0.15, .b = 0.15 },
                .accent = .{ .r = 0.0, .g = 0.45, .b = 0.85 },
                .accent_soft = .{ .r = 0.82, .g = 0.9, .b = 0.98 },
                .selection = .{ .r = 0.85, .g = 0.9, .b = 0.98 },
                .warning = .{ .r = 0.85, .g = 0.45, .b = 0.0 },
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

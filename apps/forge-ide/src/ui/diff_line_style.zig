const std = @import("std");
const renderer = @import("forge-renderer");

pub const Kind = enum {
    neutral,
    addition,
    deletion,
    file_header,
};

pub fn classify(line: []const u8) Kind {
    if (line.len >= 3 and std.mem.startsWith(u8, line, "---")) return .file_header;
    if (line.len >= 3 and std.mem.startsWith(u8, line, "+++")) return .file_header;
    if (line.len >= 2 and std.mem.startsWith(u8, line, "++")) return .addition;
    if (line.len >= 2 and std.mem.startsWith(u8, line, "--")) return .deletion;
    if (line.len > 0 and line[0] == '+') return .addition;
    if (line.len > 0 and line[0] == '-') return .deletion;
    return .neutral;
}

pub fn background(kind: Kind, accepted: bool) ?renderer.Color {
    const dim: f32 = if (accepted) 1.0 else 0.5;
    return switch (kind) {
        .addition => .{ .r = 0.14, .g = 0.42, .b = 0.22, .a = 0.72 * dim },
        .deletion => .{ .r = 0.48, .g = 0.14, .b = 0.14, .a = 0.72 * dim },
        else => null,
    };
}

pub fn foreground(kind: Kind, line: []const u8, accepted: bool, default: renderer.Color) renderer.Color {
    const dim: f32 = if (accepted) 1.0 else 0.55;
    return switch (kind) {
        .addition => .{ .r = 0.62, .g = 0.95, .b = 0.68, .a = dim },
        .deletion => .{ .r = 0.98, .g = 0.55, .b = 0.55, .a = dim },
        .file_header => if (std.mem.startsWith(u8, line, "---"))
            .{ .r = 0.95, .g = 0.82, .b = 0.45, .a = dim }
        else
            .{ .r = 0.55, .g = 0.85, .b = 0.95, .a = dim },
        .neutral => .{ .r = default.r, .g = default.g, .b = default.b, .a = default.a * dim },
    };
}

pub fn drawLine(
    line: []const u8,
    x: f32,
    y: f32,
    w: f32,
    line_h: f32,
    font_size: f32,
    accepted: bool,
    default_fg: renderer.Color,
) void {
    const kind = classify(line);
    if (background(kind, accepted)) |bg| {
        renderer.Renderer.drawRect(x, y - 1, w, line_h, bg);
    }
    const clipped = if (line.len > 511) line[0..511] else line;
    const fg = foreground(kind, clipped, accepted, default_fg);
    renderer.Renderer.drawText(clipped, x + 4, y, font_size, fg);
}

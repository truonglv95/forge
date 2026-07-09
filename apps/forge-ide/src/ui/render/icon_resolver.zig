const std = @import("std");
const renderer = @import("forge-renderer");

pub const IconResult = struct {
    svg: [:0]const u8,
    color: renderer.Color,
};

pub fn resolveIcon(name: []const u8) IconResult {
    const n = name;
    if (std.ascii.eqlIgnoreCase(n, "readme.md")) {
        return .{ .svg = renderer.icons.info, .color = .{ .r = 0.4, .g = 0.7, .b = 0.9, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".zig") or std.mem.endsWith(u8, n, ".zon")) {
        return .{ .svg = renderer.file_icons.zig, .color = .{ .r = 0.96, .g = 0.64, .b = 0.15, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".js") or std.mem.endsWith(u8, n, ".mjs") or std.mem.endsWith(u8, n, ".cjs")) {
        return .{ .svg = renderer.file_icons.js, .color = .{ .r = 0.94, .g = 0.84, .b = 0.32, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".ts") or std.mem.endsWith(u8, n, ".jsx") or std.mem.endsWith(u8, n, ".tsx")) {
        return .{ .svg = renderer.file_icons.ts, .color = .{ .r = 0.18, .g = 0.49, .b = 0.86, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".json")) {
        return .{ .svg = renderer.file_icons.json, .color = .{ .r = 0.55, .g = 0.76, .b = 0.29, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".md")) {
        return .{ .svg = renderer.file_icons.markdown, .color = .{ .r = 0.4, .g = 0.7, .b = 0.9, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".html")) {
        return .{ .svg = renderer.file_icons.html, .color = .{ .r = 0.89, .g = 0.3, .b = 0.2, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".css") or std.mem.endsWith(u8, n, ".scss")) {
        return .{ .svg = renderer.file_icons.css, .color = .{ .r = 0.2, .g = 0.5, .b = 0.8, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".py") or std.mem.endsWith(u8, n, ".pyw")) {
        return .{ .svg = renderer.file_icons.py, .color = .{ .r = 0.22, .g = 0.46, .b = 0.68, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".c")) {
        return .{ .svg = renderer.file_icons.c, .color = .{ .r = 0.4, .g = 0.6, .b = 0.9, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".h")) {
        return .{ .svg = renderer.file_icons.h, .color = .{ .r = 0.6, .g = 0.4, .b = 0.8, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".m")) {
        return .{ .svg = renderer.file_icons.m, .color = .{ .r = 0.9, .g = 0.8, .b = 0.2, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".cpp") or std.mem.endsWith(u8, n, ".hpp") or std.mem.endsWith(u8, n, ".cc")) {
        return .{ .svg = renderer.file_icons.cpp, .color = .{ .r = 0.4, .g = 0.6, .b = 0.9, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".go")) {
        return .{ .svg = renderer.file_icons.go, .color = .{ .r = 0.3, .g = 0.7, .b = 0.9, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".rs")) {
        return .{ .svg = renderer.file_icons.rust, .color = .{ .r = 0.8, .g = 0.4, .b = 0.3, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".java") or std.mem.endsWith(u8, n, ".jar") or std.mem.endsWith(u8, n, ".class")) {
        return .{ .svg = renderer.file_icons.java, .color = .{ .r = 0.8, .g = 0.3, .b = 0.3, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".php")) {
        return .{ .svg = renderer.file_icons.php, .color = .{ .r = 0.4, .g = 0.5, .b = 0.8, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".rb")) {
        return .{ .svg = renderer.file_icons.ruby, .color = .{ .r = 0.8, .g = 0.2, .b = 0.2, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".swift")) {
        return .{ .svg = renderer.file_icons.swift, .color = .{ .r = 0.9, .g = 0.4, .b = 0.2, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".kt") or std.mem.endsWith(u8, n, ".kts")) {
        return .{ .svg = renderer.file_icons.kotlin, .color = .{ .r = 0.6, .g = 0.3, .b = 0.9, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".dart")) {
        return .{ .svg = renderer.file_icons.dart, .color = .{ .r = 0.2, .g = 0.7, .b = 0.9, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".lua")) {
        return .{ .svg = renderer.file_icons.lua, .color = .{ .r = 0.2, .g = 0.3, .b = 0.7, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".yaml") or std.mem.endsWith(u8, n, ".yml")) {
        return .{ .svg = renderer.file_icons.yaml, .color = .{ .r = 0.9, .g = 0.3, .b = 0.3, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".xml")) {
        return .{ .svg = renderer.file_icons.xml, .color = .{ .r = 0.5, .g = 0.8, .b = 0.3, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".txt") or std.mem.endsWith(u8, n, ".example") or std.mem.endsWith(u8, n, ".o") or std.mem.endsWith(u8, n, "test_map")) {
        return .{ .svg = renderer.icons.file, .color = .{ .r = 0.6, .g = 0.65, .b = 0.7, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".png") or std.mem.endsWith(u8, n, ".jpg") or std.mem.endsWith(u8, n, ".jpeg") or std.mem.endsWith(u8, n, ".gif") or std.mem.endsWith(u8, n, ".svg")) {
        return .{ .svg = renderer.file_icons.image, .color = .{ .r = 0.2, .g = 0.8, .b = 0.6, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".wasm")) {
        return .{ .svg = renderer.file_icons.wasm, .color = .{ .r = 0.5, .g = 0.3, .b = 1.0, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".env") or std.mem.endsWith(u8, n, ".toml") or std.mem.endsWith(u8, n, ".ini")) {
        return .{ .svg = renderer.icons.gear, .color = .{ .r = 0.5, .g = 0.6, .b = 0.6, .a = 1.0 } };
    } else if (std.mem.endsWith(u8, n, ".gitignore")) {
        return .{ .svg = renderer.icons.git_branch, .color = .{ .r = 0.9, .g = 0.3, .b = 0.2, .a = 1.0 } };
    }

    return .{ .svg = renderer.icons.file, .color = .{ .r = 0.62, .g = 0.64, .b = 0.68, .a = 1.0 } };
}

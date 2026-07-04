const std = @import("std");
const workspace = @import("forge-workspace");
const commands_mod = @import("commands.zig");
const sidebar_view_mod = @import("../ui/sidebar_view.zig");
const breakpoints_mod = @import("breakpoints.zig");

const state_path = ".forge/last_session.toml";

pub const Layout = struct {
    active: usize = 0,
    editor_split: bool = false,
    split_tab_index: usize = 0,
    editor_pane_secondary: bool = false,
    editor_scroll_y: f32 = 0,
    editor_scroll_x: f32 = 0,
    split_scroll_y: f32 = 0,
    split_scroll_x: f32 = 0,
    bottom_panel_mode: commands_mod.BottomPanelMode = .output,
    sidebar_view: sidebar_view_mod.SidebarView = .explorer,
    bottom_panel_height: f32 = @import("../ui/layout.zig").task_panel_height,
};

pub const BreakpointEntry = breakpoints_mod.Entry;

pub const LoadResult = struct {
    paths: []const []const u8,
    layout: Layout,
    breakpoint_lines: []const BreakpointEntry,
};

pub fn saveSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    paths: []const []const u8,
    layout: Layout,
    breakpoints: *const breakpoints_mod.Store,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "[session]\n");
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "active = {d}\n", .{layout.active}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "editor_split = {s}\n", .{if (layout.editor_split) "true" else "false"}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "split_tab_index = {d}\n", .{layout.split_tab_index}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "editor_pane = \"{s}\"\n", .{if (layout.editor_pane_secondary) "secondary" else "primary"}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "editor_scroll_y = {d:.1}\n", .{layout.editor_scroll_y}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "editor_scroll_x = {d:.1}\n", .{layout.editor_scroll_x}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "split_scroll_y = {d:.1}\n", .{layout.split_scroll_y}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "split_scroll_x = {d:.1}\n", .{layout.split_scroll_x}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "bottom_panel = \"{s}\"\n", .{bottomPanelName(layout.bottom_panel_mode)}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "sidebar_view = \"{s}\"\n", .{sidebarName(layout.sidebar_view)}));
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "bottom_panel_height = {d:.1}\n", .{layout.bottom_panel_height}));

    try out.appendSlice(allocator, "\n[tabs]\n");
    for (paths) |path| {
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "path = \"{s}\"\n", .{path}));
    }

    if (breakpoints.items.items.len > 0) {
        try out.appendSlice(allocator, "\n[breakpoints]\n");
        for (breakpoints.items.items) |bp| {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "path = \"{s}\"\n", .{bp.path}));
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "line = {d}\n", .{bp.line + 1}));
        }
    }

    const wp = try workspace.WorkspacePath.parse(state_path);
    try workspace.atomic.replaceFile(io, root, wp, out.items);
}

pub fn loadSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
) !LoadResult {
    const wp = workspace.WorkspacePath.parse(state_path) catch return emptyResult();
    var snap = workspace.FileSnapshot.read(allocator, io, root, wp) catch return emptyResult();
    defer snap.deinit();

    var tabs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tabs.items) |path| allocator.free(path);
        tabs.deinit(allocator);
    }

    var bps: std.ArrayList(BreakpointEntry) = .empty;
    errdefer {
        for (bps.items) |bp| allocator.free(bp.path);
        bps.deinit(allocator);
    }

    var layout: Layout = .{};
    var section: []const u8 = "";
    var pending_bp_path: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, snap.content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, &std.ascii.whitespace, raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') continue;
            section = std.mem.trim(u8, &std.ascii.whitespace, line[1 .. line.len - 1]);
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, &std.ascii.whitespace, line[0..equals]);
        const value = std.mem.trim(u8, &std.ascii.whitespace, line[equals + 1 ..]);

        if (std.mem.eql(u8, section, "session")) {
            parseSessionField(&layout, key, value);
        } else if (std.mem.eql(u8, section, "tabs") and std.mem.eql(u8, key, "path")) {
            if (parseQuoted(value)) |path| {
                try tabs.append(allocator, try allocator.dupe(u8, path));
            }
        } else if (std.mem.eql(u8, section, "breakpoints")) {
            if (std.mem.eql(u8, key, "path")) {
                if (pending_bp_path) |old| allocator.free(old);
                pending_bp_path = if (parseQuoted(value)) |path| try allocator.dupe(u8, path) else null;
            } else if (std.mem.eql(u8, key, "line")) {
                if (pending_bp_path) |path| {
                    const one_based = std.fmt.parseInt(usize, value, 10) catch 1;
                    try bps.append(allocator, .{ .path = path, .line = if (one_based > 0) one_based - 1 else 0 });
                    pending_bp_path = null;
                }
            }
        }
    }
    if (pending_bp_path) |path| allocator.free(path);

    return .{
        .paths = try tabs.toOwnedSlice(allocator),
        .layout = layout,
        .breakpoint_lines = try bps.toOwnedSlice(allocator),
    };
}

fn emptyResult() LoadResult {
    return .{ .paths = &.{}, .layout = .{}, .breakpoint_lines = &.{} };
}

fn parseSessionField(layout: *Layout, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "active")) {
        layout.active = std.fmt.parseInt(usize, value, 10) catch 0;
    } else if (std.mem.eql(u8, key, "editor_split")) {
        layout.editor_split = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "split_tab_index")) {
        layout.split_tab_index = std.fmt.parseInt(usize, value, 10) catch 0;
    } else if (std.mem.eql(u8, key, "editor_pane")) {
        layout.editor_pane_secondary = std.mem.eql(u8, parseQuoted(value) orelse value, "secondary");
    } else if (std.mem.eql(u8, key, "editor_scroll_y")) {
        layout.editor_scroll_y = std.fmt.parseFloat(f32, value) catch 0;
    } else if (std.mem.eql(u8, key, "editor_scroll_x")) {
        layout.editor_scroll_x = std.fmt.parseFloat(f32, value) catch 0;
    } else if (std.mem.eql(u8, key, "split_scroll_y")) {
        layout.split_scroll_y = std.fmt.parseFloat(f32, value) catch 0;
    } else if (std.mem.eql(u8, key, "split_scroll_x")) {
        layout.split_scroll_x = std.fmt.parseFloat(f32, value) catch 0;
    } else if (std.mem.eql(u8, key, "bottom_panel")) {
        layout.bottom_panel_mode = parseBottomPanel(parseQuoted(value) orelse value);
    } else if (std.mem.eql(u8, key, "sidebar_view")) {
        layout.sidebar_view = parseSidebar(parseQuoted(value) orelse value);
    } else if (std.mem.eql(u8, key, "bottom_panel_height")) {
        layout.bottom_panel_height = std.fmt.parseFloat(f32, value) catch layout.bottom_panel_height;
    }
}

fn parseQuoted(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

fn bottomPanelName(mode: commands_mod.BottomPanelMode) []const u8 {
    return switch (mode) {
        .output => "output",
        .problems => "problems",
        .terminal => "terminal",
        .debug_console => "debug_console",
        .debug_variables => "debug_variables",
        .debug_callstack => "debug_callstack",
    };
}

fn parseBottomPanel(name: []const u8) commands_mod.BottomPanelMode {
    if (std.mem.eql(u8, name, "problems")) return .problems;
    if (std.mem.eql(u8, name, "terminal")) return .terminal;
    if (std.mem.eql(u8, name, "debug_console")) return .debug_console;
    if (std.mem.eql(u8, name, "debug_variables")) return .debug_variables;
    if (std.mem.eql(u8, name, "debug_callstack")) return .debug_callstack;
    return .output;
}

fn sidebarName(view: sidebar_view_mod.SidebarView) []const u8 {
    return switch (view) {
        .explorer => "explorer",
        .search => "search",
        .git => "git",
        .run => "run",
        .extensions => "extensions",
    };
}

fn parseSidebar(name: []const u8) sidebar_view_mod.SidebarView {
    if (std.mem.eql(u8, name, "search")) return .search;
    if (std.mem.eql(u8, name, "git")) return .git;
    if (std.mem.eql(u8, name, "run")) return .run;
    if (std.mem.eql(u8, name, "extensions")) return .extensions;
    return .explorer;
}

pub fn freeLoadedSession(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    breakpoint_lines: []const BreakpointEntry,
) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
    for (breakpoint_lines) |bp| allocator.free(bp.path);
    allocator.free(breakpoint_lines);
}

// Backward-compatible aliases
pub fn saveOpenTabs(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
    paths: []const []const u8,
    active: usize,
) !void {
    var layout: Layout = .{};
    layout.active = active;
    var empty_bps = breakpoints_mod.Store.init(allocator);
    defer empty_bps.deinit();
    try saveSession(allocator, io, root, paths, layout, &empty_bps);
}

pub fn loadOpenTabs(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: workspace.WorkspaceRoot,
) !struct { paths: []const []const u8, active: usize } {
    const loaded = try loadSession(allocator, io, root);
    return .{ .paths = loaded.paths, .active = loaded.layout.active };
}

pub fn freeLoadedTabs(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

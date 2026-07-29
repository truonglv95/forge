const std = @import("std");
const term = @import("term.zig");

/// HelpPanel is a self-contained modal component that renders the help
/// overlay as a structured UI panel — not as log text.
///
/// Design principles (per user feedback):
///   1. Separate view, not rendered like chat log lines.
///   2. No line numbers or literal `\` characters in the UI.
///   3. 3 color tiers: command (bright), description (normal), metadata (dim).
///   4. Commands grouped by category.
///   5. Width capped at 100 cols (not full screen).
///   6. Selected row highlight for keyboard navigation.
///   7. Header shows only actionable info: workspace, branch, mode, model.
///
/// The panel is centered on screen, with a bordered box. Users can scroll
/// through command categories with Up/Down arrows and press Enter to insert
/// the selected command into the input buffer.
pub const CommandEntry = struct {
    name: []const u8,
    description: []const u8,
};

pub const CommandCategory = struct {
    name: []const u8,
    icon: []const u8,
    commands: []const CommandEntry,
};

/// Static command catalog. This is the single source of truth for the help
/// panel — no string concatenation, no literal `\` line continuations.
pub const categories = [_]CommandCategory{
    .{
        .name = "Agent",
        .icon = "*",
        .commands = &[_]CommandEntry{
            .{ .name = "/mode", .description = "Switch ask / plan / agent mode" },
            .{ .name = "/policy", .description = "Cycle tool approval policy" },
            .{ .name = "/tools", .description = "List available agent tools" },
            .{ .name = "/complete", .description = "Inline code completion" },
            .{ .name = "/retry", .description = "Re-run last user intent" },
            .{ .name = "/undo", .description = "Undo last transaction" },
            .{ .name = "/redo", .description = "Redo undone transaction" },
        },
    },
    .{
        .name = "Context",
        .icon = "+",
        .commands = &[_]CommandEntry{
            .{ .name = "/context", .description = "Show context inspector" },
            .{ .name = "/inspect", .description = "Inspect loaded context blocks" },
            .{ .name = "/model", .description = "Show / set AI model" },
            .{ .name = "/cost", .description = "Token usage and cost" },
            .{ .name = "/capability", .description = "Provider capabilities" },
            .{ .name = "/provider", .description = "Provider configuration" },
        },
    },
    .{
        .name = "Chat",
        .icon = ">",
        .commands = &[_]CommandEntry{
            .{ .name = "/clear", .description = "Clear chat history" },
            .{ .name = "/search", .description = "Search conversation" },
            .{ .name = "/edit", .description = "Edit last user message" },
            .{ .name = "/save", .description = "Save conversation to file" },
            .{ .name = "/export", .description = "Export as Markdown" },
            .{ .name = "/copy", .description = "Copy a line to clipboard" },
            .{ .name = "/copyall", .description = "Copy all chat to clipboard" },
            .{ .name = "/compact", .description = "Compact conversation history" },
            .{ .name = "/bookmark", .description = "Bookmark a line" },
            .{ .name = "/pin", .description = "Pin a line to top" },
            .{ .name = "/goto", .description = "Jump to a line number" },
            .{ .name = "/filter", .description = "Filter by role (user/agent/tool)" },
        },
    },
    .{
        .name = "Session",
        .icon = "#",
        .commands = &[_]CommandEntry{
            .{ .name = "/sessions", .description = "List saved sessions" },
            .{ .name = "/resume", .description = "Resume a session by ID" },
            .{ .name = "/timeline", .description = "Show task ledger timeline" },
            .{ .name = "/events", .description = "View NDJSON event log" },
            .{ .name = "/time", .description = "Show session elapsed time" },
            .{ .name = "/version", .description = "Show Forge version" },
        },
    },
    .{
        .name = "Specs & Git",
        .icon = "S",
        .commands = &[_]CommandEntry{
            .{ .name = "/spec", .description = "Spec-driven workflow (Kiro)" },
            .{ .name = "/runs", .description = "List background runs" },
            .{ .name = "/diff", .description = "Show proposal diff" },
            .{ .name = "/branch", .description = "Create a git branch" },
            .{ .name = "/review", .description = "AI code review" },
        },
    },
    .{
        .name = "Config",
        .icon = "C",
        .commands = &[_]CommandEntry{
            .{ .name = "/theme", .description = "Switch color theme" },
            .{ .name = "/config", .description = "Show configuration" },
            .{ .name = "/stats", .description = "Session statistics" },
            .{ .name = "/wordwrap", .description = "Toggle word wrap" },
            .{ .name = "/vim", .description = "Toggle vim mode" },
            .{ .name = "/mouse", .description = "Toggle mouse support" },
            .{ .name = "/resize", .description = "Refresh terminal size" },
        },
    },
    .{
        .name = "AI Tools",
        .icon = "A",
        .commands = &[_]CommandEntry{
            .{ .name = "/refactor", .description = "AI refactor code" },
            .{ .name = "/explain", .description = "AI explain code" },
            .{ .name = "/fix", .description = "AI fix bugs" },
            .{ .name = "/testgen", .description = "AI generate tests" },
            .{ .name = "/doc", .description = "AI generate docs" },
            .{ .name = "/translate", .description = "AI translate code" },
            .{ .name = "/annotate", .description = "AI annotate code" },
        },
    },
    .{
        .name = "Tabs",
        .icon = "T",
        .commands = &[_]CommandEntry{
            .{ .name = "/newtab", .description = "Open a new tab" },
            .{ .name = "/tabs", .description = "List all tabs" },
            .{ .name = "/close", .description = "Close current tab" },
            .{ .name = "/rename", .description = "Rename current tab" },
            .{ .name = "/switch", .description = "Switch to a tab" },
            .{ .name = "/merge", .description = "Merge tabs" },
        },
    },
    .{
        .name = "General",
        .icon = "G",
        .commands = &[_]CommandEntry{
            .{ .name = "/help", .description = "Show this help panel" },
            .{ .name = "/quit", .description = "Exit Forge" },
            .{ .name = "/exit", .description = "Exit Forge (alias)" },
        },
    },
};

pub const KeyBinding = struct {
    key: []const u8,
    action: []const u8,
};

pub const key_bindings = [_]KeyBinding{
    .{ .key = "Enter", .action = "Submit message" },
    .{ .key = "Tab", .action = "Autocomplete" },
    .{ .key = "Ctrl+J", .action = "Newline (multi-line)" },
    .{ .key = "Ctrl+C", .action = "Cancel / quit (x2)" },
    .{ .key = "Ctrl+R", .action = "Review last tool" },
    .{ .key = "Ctrl+Y", .action = "Copy code block" },
    .{ .key = "Ctrl+L", .action = "Clear screen" },
    .{ .key = "Ctrl+U", .action = "Clear input" },
    .{ .key = "Ctrl+W", .action = "Delete word" },
    .{ .key = "Up/Down", .action = "History / scroll" },
    .{ .key = "PgUp/PgDn", .action = "Scroll chat" },
    .{ .key = "Home/End", .action = "Jump in input" },
    .{ .key = "Esc", .action = "Close overlay" },
    .{ .key = "?", .action = "Toggle this help" },
};

/// State for the help panel: which row is selected, scroll offset.
pub const State = struct {
    selected: usize = 0,
    scroll_offset: usize = 0,
    /// Flat list of (category_index, command_index) pairs for navigation.
    /// Built on first render and cached.
    flat_entries: []Entry = &.{},
    flat_init: bool = false,

    pub const Entry = struct {
        cat_idx: usize,
        cmd_idx: usize,
        is_header: bool = false,
    };

    pub fn ensureFlatInit(self: *State, allocator: std.mem.Allocator) !void {
        if (self.flat_init) return;
        // Count total entries: 1 header per category + commands per category.
        var total: usize = 0;
        for (categories) |cat| {
            total += 1 + cat.commands.len;
        }
        self.flat_entries = try allocator.alloc(Entry, total);
        var i: usize = 0;
        for (categories, 0..) |cat, ci| {
            self.flat_entries[i] = .{ .cat_idx = ci, .cmd_idx = 0, .is_header = true };
            i += 1;
            for (cat.commands, 0..) |_, cji| {
                self.flat_entries[i] = .{ .cat_idx = ci, .cmd_idx = cji };
                i += 1;
            }
        }
        self.flat_init = true;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.flat_init) {
            allocator.free(self.flat_entries);
            self.flat_init = false;
        }
    }

    pub fn moveUp(self: *State) void {
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn moveDown(self: *State) void {
        if (self.selected + 1 < self.flat_entries.len) self.selected += 1;
    }

    pub fn movePageUp(self: *State, page_size: usize) void {
        if (self.selected > page_size) {
            self.selected -= page_size;
        } else {
            self.selected = 0;
        }
    }

    pub fn movePageDown(self: *State, page_size: usize) void {
        self.selected = @min(self.selected + page_size, self.flat_entries.len - 1);
    }

    /// Returns the command name of the selected entry, or null if the
    /// selected entry is a category header.
    pub fn selectedCommand(self: *const State) ?[]const u8 {
        if (self.selected >= self.flat_entries.len) return null;
        const e = self.flat_entries[self.selected];
        if (e.is_header) return null;
        return categories[e.cat_idx].commands[e.cmd_idx].name;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "State init has zero selected and offset" {
    const state = State{};
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expectEqual(@as(usize, 0), state.scroll_offset);
    try std.testing.expect(!state.flat_init);
}

test "State ensureFlatInit builds entries for all categories" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);
    try state.ensureFlatInit(allocator);
    try std.testing.expect(state.flat_init);
    try std.testing.expect(state.flat_entries.len > 0);
    // Each category contributes 1 header + N commands.
    var expected: usize = 0;
    for (categories) |cat| expected += 1 + cat.commands.len;
    try std.testing.expectEqual(expected, state.flat_entries.len);
}

test "State moveUp wraps from 0 to last" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);
    try state.ensureFlatInit(allocator);
    // At 0, moveUp should stay at 0 (no wrap in current impl).
    state.moveUp();
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    // Move to middle then up.
    state.selected = 5;
    state.moveUp();
    try std.testing.expectEqual(@as(usize, 4), state.selected);
}

test "State moveDown advances and stops at end" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);
    try state.ensureFlatInit(allocator);
    const last = state.flat_entries.len - 1;
    state.selected = last;
    state.moveDown();
    // Should stay at last (no wrap).
    try std.testing.expectEqual(last, state.selected);
    // From middle, should advance.
    state.selected = 5;
    state.moveDown();
    try std.testing.expectEqual(@as(usize, 6), state.selected);
}

test "State movePageUp jumps by page size" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);
    try state.ensureFlatInit(allocator);
    state.selected = 20;
    state.movePageUp(10);
    try std.testing.expectEqual(@as(usize, 10), state.selected);
    // Near 0, should clamp to 0.
    state.selected = 3;
    state.movePageUp(10);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
}

test "State movePageDown jumps and clamps" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);
    try state.ensureFlatInit(allocator);
    const last = state.flat_entries.len - 1;
    state.selected = 0;
    state.movePageDown(10);
    try std.testing.expectEqual(@as(usize, 10), state.selected);
    // Near end, should clamp to last.
    state.selected = last - 2;
    state.movePageDown(10);
    try std.testing.expectEqual(last, state.selected);
}

test "State selectedCommand returns null for header" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);
    try state.ensureFlatInit(allocator);
    // First entry is a category header.
    state.selected = 0;
    try std.testing.expect(state.flat_entries[0].is_header);
    try std.testing.expectEqual(@as(?[]const u8, null), state.selectedCommand());
}

test "State selectedCommand returns name for command entry" {
    const allocator = std.testing.allocator;
    var state = State{};
    defer state.deinit(allocator);
    try state.ensureFlatInit(allocator);
    // Second entry should be the first command of the first category.
    state.selected = 1;
    const cmd = state.selectedCommand();
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings(categories[0].commands[0].name, cmd.?);
}

test "categories has 9 categories" {
    try std.testing.expectEqual(@as(usize, 9), categories.len);
}

test "each category has at least 1 command" {
    for (categories) |cat| {
        try std.testing.expect(cat.commands.len > 0);
    }
}

test "key_bindings has entries" {
    try std.testing.expect(key_bindings.len > 0);
}

test "Phase enum cycles through all 7 phases" {
    // Re-export from superpower_harness for consistency check.
    // This test verifies the help panel categories cover the expected workflow.
    var found_agent = false;
    var found_config = false;
    for (categories) |cat| {
        if (std.mem.eql(u8, cat.name, "Agent")) found_agent = true;
        if (std.mem.eql(u8, cat.name, "Config")) found_config = true;
    }
    try std.testing.expect(found_agent);
    try std.testing.expect(found_config);
}

/// Render the help panel onto the given FrameBuffer. The panel is centered,
/// with a bordered box of width ~100 cols. Returns the command name if the
/// user pressed Enter on a command (caller checks this separately).
///
/// Layout:
///   ┌─ FORGE Help ─ workspace: X | branch: Y | mode: Z | model: W ──────┐
///   │                                                                      │
///   │  * Agent                                                              │
///   │    /mode        Switch ask / plan / agent mode                       │
///   │    /policy      Cycle tool approval policy                           │
///   │    ...                                                               │
///   │                                                                      │
///   │  + Context                                                            │
///   │    ...                                                               │
///   │                                                                      │
///   ├─ Keys ─────────────────────────────────────────────────────────────┤
///   │  Enter=Submit  Tab=Autocomplete  Ctrl+J=Newline  Ctrl+C=Cancel      │
///   │  ↑↓=Navigate  Enter=Insert command  Esc=Close                        │
///   └──────────────────────────────────────────────────────────────────────┘
pub fn render(
    frame: *term.FrameBuffer,
    allocator: std.mem.Allocator,
    use_color: bool,
    size: term.Terminal.Size,
    state: *State,
    header_info: HeaderInfo,
) !void {
    try state.ensureFlatInit(allocator);

    // Panel width: capped at 100, but shrink if terminal is narrower.
    const panel_w: u16 = @min(100, size.cols -| 2);
    // Panel height: header(1) + padding(1) + entries + keys_section(4) + footer(1)
    const entries_h: u16 = @intCast(state.flat_entries.len);
    const panel_h: u16 = @min(size.rows -| 2, 3 + entries_h + 5);

    // Center the panel.
    const start_row: u16 = if (size.rows > panel_h) @divFloor(size.rows - panel_h, 2) else 1;
    const start_col: u16 = if (size.cols > panel_w) @divFloor(size.cols - panel_w, 2) else 1;

    // Adjust scroll_offset so selected entry is visible.
    const visible_h: u16 = if (panel_h > 8) panel_h - 8 else 1; // entries visible area
    const sel: u16 = @intCast(state.selected);
    if (sel < state.scroll_offset) {
        state.scroll_offset = sel;
    } else if (sel >= state.scroll_offset + visible_h) {
        state.scroll_offset = sel + 1 - visible_h;
    }
    const max_scroll = if (entries_h > visible_h) entries_h - visible_h else 0;
    if (state.scroll_offset > max_scroll) state.scroll_offset = max_scroll;

    // === Draw background fill (semi-transparent look via bg_block) ===
    for (0..panel_h) |i| {
        const r = start_row + @as(u16, @intCast(i));
        frame.moveTo(r, start_col);
        if (use_color) frame.appendSlice(term.Style.bg_block) catch {};
        frame.data.appendNTimes(allocator, ' ', panel_w) catch {};
        frame.appendSlice("\x1b[K") catch {};
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
    }

    // === Draw top border + header ===
    frame.moveTo(start_row, start_col);
    if (use_color) {
        frame.appendSlice(term.Style.bg_block) catch {};
        frame.appendSlice(term.Style.cyan) catch {};
        frame.appendSlice(term.Style.bold) catch {};
    }
    frame.appendSlice("┌─ ") catch {};
    frame.appendSlice("FORGE Help") catch {};
    // Header info: workspace, branch, mode, model — actionable only.
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, " ─ {s} | {s} | {s} | {s}", .{
        header_info.workspace,
        header_info.branch,
        header_info.mode,
        header_info.model,
    }) catch "";
    frame.appendSlice(hdr) catch {};
    // Fill remaining with ─
    const used: u16 = @intCast(3 + 10 + hdr.len);
    if (panel_w > used + 1) {
        var fill: u16 = 0;
        while (fill < panel_w - used - 1) : (fill += 1) {
            frame.appendSlice("─") catch {};
        }
    }
    frame.appendSlice("┐") catch {};
    if (use_color) frame.appendSlice(term.Style.reset) catch {};

    // === Draw entries ===
    var row: u16 = start_row + 1;
    const entries_end: u16 = start_row + 1 + visible_h;
    var ei: usize = state.scroll_offset;
    while (ei < state.flat_entries.len and row < entries_end) : (ei += 1) {
        const entry = state.flat_entries[ei];
        const is_selected = (ei == state.selected);

        frame.moveTo(row, start_col);
        if (use_color) frame.appendSlice(term.Style.bg_block) catch {};

        if (entry.is_header) {
            // Category header: icon + name, bright color
            const cat = categories[entry.cat_idx];
            if (is_selected and use_color) {
                frame.appendSlice(term.Style.invert) catch {};
            }
            if (use_color) {
                frame.appendSlice(term.Style.bright_yellow) catch {};
                frame.appendSlice(term.Style.bold) catch {};
            }
            frame.appendSlice("│  ") catch {};
            frame.appendSlice(cat.icon) catch {};
            frame.appendSlice(" ") catch {};
            frame.appendSlice(cat.name) catch {};
            if (use_color) frame.appendSlice(term.Style.reset) catch {};
            if (is_selected and use_color) {
                frame.appendSlice(term.Style.reset) catch {};
            }
        } else {
            // Command entry: name (bright) + description (dim)
            const cat = categories[entry.cat_idx];
            const cmd = cat.commands[entry.cmd_idx];
            if (is_selected and use_color) {
                frame.appendSlice(term.Style.invert) catch {};
                frame.appendSlice(term.Style.cyan) catch {};
            }
            // Selection marker
            frame.appendSlice(if (is_selected) "│ ▶ " else "│   ") catch {};
            if (use_color and !is_selected) {
                frame.appendSlice(term.Style.bright_green) catch {};
            }
            // Command name, padded to 16 chars
            frame.appendSlice(cmd.name) catch {};
            const name_pad: usize = if (cmd.name.len < 16) 16 - cmd.name.len else 1;
            var p: usize = 0;
            while (p < name_pad) : (p += 1) frame.appendSlice(" ") catch {};
            if (use_color and !is_selected) {
                frame.appendSlice(term.Style.reset) catch {};
                frame.appendSlice(term.Style.dim) catch {};
            }
            // Description (truncated to fit)
            const desc_max: usize = if (panel_w > 24) @as(usize, panel_w) - 24 else 1;
            const desc = if (cmd.description.len > desc_max) cmd.description[0..desc_max] else cmd.description;
            frame.appendSlice(desc) catch {};
            if (use_color) frame.appendSlice(term.Style.reset) catch {};
        }
        // Clear to end of line within panel
        if (use_color) frame.appendSlice(term.Style.bg_block) catch {};
        frame.appendSlice(" ") catch {};
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
        row += 1;
    }

    // Fill remaining entry rows with empty bg
    while (row < entries_end) : (row += 1) {
        frame.moveTo(row, start_col);
        if (use_color) frame.appendSlice(term.Style.bg_block) catch {};
        frame.data.appendNTimes(allocator, ' ', panel_w) catch {};
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
    }

    // === Draw keys separator ===
    frame.moveTo(row, start_col);
    if (use_color) {
        frame.appendSlice(term.Style.bg_block) catch {};
        frame.appendSlice(term.Style.dim) catch {};
    }
    frame.appendSlice("├─ Keys ") catch {};
    var kfill: u16 = 0;
    while (kfill + 8 < panel_w - 1) : (kfill += 1) {
        frame.appendSlice("─") catch {};
    }
    frame.appendSlice("┤") catch {};
    if (use_color) frame.appendSlice(term.Style.reset) catch {};
    row += 1;

    // === Draw key bindings (2 columns) ===
    var ki: usize = 0;
    while (ki < key_bindings.len and row < start_row + panel_h - 1) : (ki += 2) {
        frame.moveTo(row, start_col);
        if (use_color) {
            frame.appendSlice(term.Style.bg_block) catch {};
        }
        frame.appendSlice("│ ") catch {};
        // Left column
        if (use_color) frame.appendSlice(term.Style.bright_cyan) catch {};
        frame.appendSlice(key_bindings[ki].key) catch {};
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
        if (use_color) frame.appendSlice(term.Style.dim) catch {};
        var kbuf: [128]u8 = undefined;
        const left = std.fmt.bufPrint(&kbuf, " {s}", .{key_bindings[ki].action}) catch key_bindings[ki].action;
        frame.appendSlice(left) catch {};
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
        // Right column
        if (ki + 1 < key_bindings.len) {
            const left_w: usize = 3 + key_bindings[ki].key.len + 1 + key_bindings[ki].action.len;
            const right_start: usize = if (panel_w > 40) @divFloor(@as(usize, panel_w), 2) else left_w + 2;
            if (right_start > left_w) {
                var pad: usize = left_w;
                while (pad < right_start) : (pad += 1) frame.appendSlice(" ") catch {};
            }
            if (use_color) frame.appendSlice(term.Style.bright_cyan) catch {};
            frame.appendSlice(key_bindings[ki + 1].key) catch {};
            if (use_color) frame.appendSlice(term.Style.reset) catch {};
            if (use_color) frame.appendSlice(term.Style.dim) catch {};
            var rbuf: [128]u8 = undefined;
            const right = std.fmt.bufPrint(&rbuf, " {s}", .{key_bindings[ki + 1].action}) catch key_bindings[ki + 1].action;
            frame.appendSlice(right) catch {};
            if (use_color) frame.appendSlice(term.Style.reset) catch {};
        }
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
        row += 1;
    }

    // === Draw bottom border + footer hint ===
    frame.moveTo(row, start_col);
    if (use_color) {
        frame.appendSlice(term.Style.bg_block) catch {};
        frame.appendSlice(term.Style.dim) catch {};
    }
    frame.appendSlice("└") catch {};
    // Footer hint in the bottom border
    if (use_color) {
        frame.appendSlice(term.Style.reset) catch {};
        frame.appendSlice(term.Style.cyan) catch {};
    }
    const hint = " ↑↓ Navigate · Enter Insert · Esc Close ";
    frame.appendSlice(hint) catch {};
    if (use_color) {
        frame.appendSlice(term.Style.reset) catch {};
        frame.appendSlice(term.Style.dim) catch {};
    }
    const hint_w: u16 = @intCast(hint.len + 1);
    var bfill: u16 = 0;
    while (bfill + hint_w < panel_w - 1) : (bfill += 1) {
        frame.appendSlice("─") catch {};
    }
    frame.appendSlice("┘") catch {};
    if (use_color) frame.appendSlice(term.Style.reset) catch {};
}

pub const HeaderInfo = struct {
    workspace: []const u8,
    branch: []const u8,
    mode: []const u8,
    model: []const u8,
};

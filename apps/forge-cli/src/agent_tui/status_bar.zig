const std = @import("std");
const term = @import("term.zig");

/// StatusBar is a self-contained component that renders the top status bar
/// of the Forge TUI. It shows actionable information only: spinner, tab,
/// model, mode, context usage, branch, edited count, and token count.
///
/// Design:
///   - 8 segments with independent color tiers
///   - Right-aligned token count
///   - Context usage mini-bar (color shifts green→yellow→red)
///   - No log-style text, no literal \ characters
///   - Width-aware: pads to fill terminal width
///
/// This component replaces the inline drawStatusBar() method in app.zig,
/// following the help_panel.zig component pattern.
pub const StatusInfo = struct {
    spinner: []const u8,
    tab_name: []const u8,
    model: []const u8,
    mode: []const u8,
    context_label: []const u8,
    branch: []const u8,
    edited_label: []const u8,
    total_tokens: u64,
    busy: bool,
};

/// Render the status bar at row 1, spanning the full terminal width.
pub fn render(
    frame: *term.FrameBuffer,
    allocator: std.mem.Allocator,
    use_color: bool,
    cols: u16,
    info: StatusInfo,
) void {
    frame.moveTo(1, 1);

    var buf: [512]u8 = undefined;
    var col: u16 = 0;

    // Segment 1: Spinner + FORGE (bold, inverted — brand segment)
    if (use_color) {
        frame.appendSlice(term.Style.invert) catch {};
        frame.appendSlice(term.Style.bold) catch {};
    }
    const seg1 = std.fmt.bufPrint(&buf, " {s} FORGE ", .{info.spinner}) catch " FORGE ";
    frame.appendSlice(seg1) catch {};
    col += @intCast(term.displayWidth(seg1));
    if (use_color) frame.appendSlice(term.Style.reset) catch {};

    // Segment 2: Tab name (cyan)
    if (use_color) frame.appendSlice(term.Style.cyan) catch {};
    const seg2 = std.fmt.bufPrint(&buf, " [{s}] ", .{info.tab_name}) catch " [] ";
    frame.appendSlice(seg2) catch {};
    col += @intCast(term.displayWidth(seg2));
    if (use_color) frame.appendSlice(term.Style.reset) catch {};

    // Segment 3: Model (bright_green — actionable, user may want to change)
    if (use_color) frame.appendSlice(term.Style.bright_green) catch {};
    const seg3 = std.fmt.bufPrint(&buf, "{s} ", .{info.model}) catch "";
    frame.appendSlice(seg3) catch {};
    col += @intCast(term.displayWidth(seg3));
    if (use_color) frame.appendSlice(term.Style.reset) catch {};

    // Segment 4: Mode (yellow — actionable, /mode to switch)
    if (use_color) frame.appendSlice(term.Style.yellow) catch {};
    const seg4 = std.fmt.bufPrint(&buf, "| {s} ", .{info.mode}) catch "";
    frame.appendSlice(seg4) catch {};
    col += @intCast(term.displayWidth(seg4));
    if (use_color) frame.appendSlice(term.Style.reset) catch {};

    // Segment 5: Context (gray) + usage bar (color-coded)
    if (use_color) frame.appendSlice(term.Style.gray) catch {};
    const seg5 = std.fmt.bufPrint(&buf, "| ctx:{s} ", .{info.context_label}) catch "";
    frame.appendSlice(seg5) catch {};
    col += @intCast(term.displayWidth(seg5));
    if (use_color) frame.appendSlice(term.Style.reset) catch {};

    // Context usage mini-bar: 5-char bar based on token count.
    // Color shifts: green (0-50%) → yellow (51-80%) → red (81-100%+)
    const ctx_usage_pct = @min(100, (info.total_tokens * 100) / 100000);
    const bar_fill: usize = ctx_usage_pct / 20;
    if (use_color) {
        if (ctx_usage_pct > 80) {
            frame.appendSlice(term.Style.bright_red) catch {};
        } else if (ctx_usage_pct > 50) {
            frame.appendSlice(term.Style.bright_yellow) catch {};
        } else {
            frame.appendSlice(term.Style.bright_green) catch {};
        }
    }
    var ctx_bar_buf: [8]u8 = undefined;
    var bi: usize = 0;
    while (bi < 5) : (bi += 1) {
        // Use ASCII chars for compatibility (█ = 0xE2 0x96 0x88 in UTF-8,
        // but we use # and . to avoid multi-byte issues in the bar).
        ctx_bar_buf[bi] = if (bi < bar_fill) '#' else '.';
    }
    frame.appendSlice(ctx_bar_buf[0..5]) catch {};
    if (use_color) frame.appendSlice(term.Style.reset) catch {};
    frame.appendSlice(" ") catch {};
    col += 6;

    // Segment 6: Branch (magenta) — only if not "no branch"
    if (!std.mem.eql(u8, info.branch, "no branch")) {
        if (use_color) frame.appendSlice(term.Style.magenta) catch {};
        const seg6 = std.fmt.bufPrint(&buf, "| git:{s} ", .{info.branch}) catch "";
        frame.appendSlice(seg6) catch {};
        col += @intCast(term.displayWidth(seg6));
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
    }

    // Segment 7: Edited count (bright_yellow) — only if > 0
    if (!std.mem.eql(u8, info.edited_label, "0 edited")) {
        if (use_color) frame.appendSlice(term.Style.bright_yellow) catch {};
        const seg7 = std.fmt.bufPrint(&buf, "| {s} ", .{info.edited_label}) catch "";
        frame.appendSlice(seg7) catch {};
        col += @intCast(term.displayWidth(seg7));
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
    }

    // Segment 8: Tokens (bright_green) — right-aligned
    const seg8 = std.fmt.bufPrint(&buf, "{d} tok", .{info.total_tokens}) catch "0 tok";
    const seg8_cols: u16 = @intCast(term.displayWidth(seg8));
    if (col + seg8_cols + 2 < cols) {
        if (cols > col + seg8_cols + 1) {
            frame.data.appendNTimes(allocator, ' ', cols - col - seg8_cols - 1) catch {};
        }
        if (use_color) frame.appendSlice(term.Style.bright_green) catch {};
        frame.appendSlice(seg8) catch {};
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
        col = cols;
    } else {
        if (use_color) frame.appendSlice(term.Style.bright_green) catch {};
        frame.appendSlice(seg8) catch {};
        if (use_color) frame.appendSlice(term.Style.reset) catch {};
        col += seg8_cols;
    }

    // Pad remaining space and clear to end of line.
    if (col < cols) {
        frame.data.appendNTimes(allocator, ' ', cols - col) catch {};
    }
    frame.appendSlice("\x1b[K") catch {};
}

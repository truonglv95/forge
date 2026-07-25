//! Streaming Diff Preview — renders inline diff views (green/red lines)
//! in the agent chat panel when the agent proposes code changes.
//!
//! When the agent's response contains code blocks that look like diffs
//! (lines starting with + or -), or when the agent uses the
//! replace_file_content / multi_edit tools, the diff is rendered
//! inline in the chat bubble with:
//! - Green background for additions (+)
//! - Red background for deletions (-)
//! - File path header
//! - Per-hunk accept/reject buttons
//! - "Accept All" / "Reject All" buttons
const std = @import("std");
const renderer = @import("forge-renderer");
const diff_line_style = @import("../diff_line_style.zig");

pub const DiffLine = struct {
    text: []const u8,
    kind: diff_line_style.Kind,
};

pub const DiffHunk = struct {
    file_path: []const u8,
    lines: []const DiffLine,
    accepted: bool = true,
    start_line: u32 = 0,

    pub fn deinit(self: *DiffHunk, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        for (self.lines) |line| allocator.free(line.text);
        allocator.free(self.lines);
    }
};

pub const DiffPreview = struct {
    allocator: std.mem.Allocator,
    hunks: std.ArrayList(DiffHunk),
    /// Height of the entire diff preview block (for layout).
    total_height: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) DiffPreview {
        return .{
            .allocator = allocator,
            .hunks = .empty,
        };
    }

    pub fn deinit(self: *DiffPreview) void {
        for (self.hunks.items) |*hunk| hunk.deinit(self.allocator);
        self.hunks.deinit(self.allocator);
    }

    /// Parse a code block from the agent response and detect if it's a diff.
    /// Returns true if the code block was parsed as a diff (contains +/- lines).
    pub fn parseFromCodeBlock(
        self: *DiffPreview,
        code: []const u8,
        lang: []const u8,
        file_hint: ?[]const u8,
    ) !bool {
        // Check if this looks like a diff (has +/- lines)
        var has_additions = false;
        var has_deletions = false;
        var lines = std.mem.splitScalar(u8, code, '\n');
        while (lines.next()) |line| {
            const kind = diff_line_style.classify(line);
            if (kind == .addition) has_additions = true;
            if (kind == .deletion) has_deletions = true;
        }

        // Only treat as diff if it has both additions and deletions,
        // or if the language is explicitly "diff"
        const is_diff = std.mem.eql(u8, lang, "diff") or (has_additions and has_deletions);
        if (!is_diff) return false;

        // Parse into a hunk
        var diff_lines: std.ArrayList(DiffLine) = .empty;
        errdefer {
            for (diff_lines.items) |line| self.allocator.free(line.text);
            diff_lines.deinit(self.allocator);
        }

        var current_line: u32 = 0;
        lines = std.mem.splitScalar(u8, code, '\n');
        while (lines.next()) |line| {
            const kind = diff_line_style.classify(line);
            const text = try self.allocator.dupe(u8, line);
            try diff_lines.append(self.allocator, .{ .text = text, .kind = kind });
            if (kind == .addition or kind == .neutral) current_line += 1;
        }

        const file_path = if (file_hint) |f| try self.allocator.dupe(u8, f) else try self.allocator.dupe(u8, "unknown");
        try self.hunks.append(self.allocator, .{
            .file_path = file_path,
            .lines = try diff_lines.toOwnedSlice(self.allocator),
            .accepted = true,
            .start_line = 0,
        });

        return true;
    }

    /// Toggle acceptance of a hunk by index.
    pub fn toggleHunk(self: *DiffPreview, index: usize) void {
        if (index < self.hunks.items.len) {
            self.hunks.items[index].accepted = !self.hunks.items[index].accepted;
        }
    }

    /// Accept all hunks.
    pub fn acceptAll(self: *DiffPreview) void {
        for (self.hunks.items) |*hunk| hunk.accepted = true;
    }

    /// Reject all hunks.
    pub fn rejectAll(self: *DiffPreview) void {
        for (self.hunks.items) |*hunk| hunk.accepted = false;
    }

    /// Clear all hunks.
    pub fn clear(self: *DiffPreview) void {
        for (self.hunks.items) |*hunk| hunk.deinit(self.allocator);
        self.hunks.clearRetainingCapacity();
    }

    /// Get the height of the diff preview block for layout.
    pub fn computeHeight(self: *const DiffPreview, content_w: f32) f32 {
        if (self.hunks.items.len == 0) return 0;

        const header_h: f32 = 22; // File path header per hunk
        const line_h: f32 = 14; // Per diff line
        const hunk_gap: f32 = 8; // Gap between hunks
        const action_bar_h: f32 = 28; // Accept All / Reject All bar

        var total: f32 = action_bar_h;
        for (self.hunks.items) |hunk| {
            total += header_h + @as(f32, @floatFromInt(hunk.lines.len)) * line_h + hunk_gap;
        }
        _ = content_w;
        return total;
    }
};

/// Draw the diff preview inline in the chat bubble.
/// Renders green/red diff lines with file headers and accept/reject buttons.
pub fn drawDiffPreview(
    preview: *const DiffPreview,
    x: f32,
    y: f32,
    content_w: f32,
    mouse_x: f32,
    mouse_y: f32,
) f32 {
    if (preview.hunks.items.len == 0) return 0;

    const line_h: f32 = 14;
    const header_h: f32 = 22;
    const hunk_gap: f32 = 8;
    var current_y = y;

    // Action bar — "Accept All" / "Reject All" buttons at top
    const bar_h: f32 = 28;
    renderer.Renderer.drawRoundedRect(x, current_y, content_w, bar_h, 6, .{ .r = 0.1, .g = 0.11, .b = 0.14, .a = 0.9 });
    renderer.Renderer.drawRoundedRect(x, current_y, content_w, 1, 4, .{ .r = 0.25, .g = 0.28, .b = 0.34, .a = 0.5 });

    // Label
    renderer.Renderer.drawText("Proposed Changes", x + 10, current_y + 7, 11.0, .{ .r = 0.7, .g = 0.75, .b = 0.85, .a = 1.0 });

    // Count summary
    var accepted_count: usize = 0;
    var total_additions: usize = 0;
    var total_deletions: usize = 0;
    for (preview.hunks.items) |hunk| {
        if (hunk.accepted) accepted_count += 1;
        for (hunk.lines) |line| {
            if (line.kind == .addition) total_additions += 1;
            if (line.kind == .deletion) total_deletions += 1;
        }
    }
    var count_buf: [64:0]u8 = undefined;
    const count_str = std.fmt.bufPrintZ(&count_buf, "{d} files  +{d}  -{d}", .{
        preview.hunks.items.len, total_additions, total_deletions,
    }) catch "";
    renderer.Renderer.drawText(@ptrCast(&count_buf), x + 130, current_y + 7, 10.0, .{ .r = 0.6, .g = 0.65, .b = 0.7, .a = 1.0 });

    // Accept All button (right side)
    const accept_btn_w: f32 = 70;
    const accept_btn_x = x + content_w - accept_btn_w - 70 - 8;
    const accept_btn_hover = mouse_x >= accept_btn_x and mouse_x < accept_btn_x + accept_btn_w and
        mouse_y >= current_y + 4 and mouse_y < current_y + 4 + 20;
    renderer.Renderer.drawRoundedRect(accept_btn_x, current_y + 4, accept_btn_w, 20, 4, if (accept_btn_hover)
        .{ .r = 0.2, .g = 0.4, .b = 0.2, .a = 0.9 }
    else
        .{ .r = 0.14, .g = 0.25, .b = 0.16, .a = 0.7 });
    renderer.Renderer.drawText("Accept All", accept_btn_x + 6, current_y + 8, 10.0, .{ .r = 0.75, .g = 0.95, .b = 0.75, .a = 1.0 });

    // Reject All button
    const reject_btn_w: f32 = 70;
    const reject_btn_x = x + content_w - reject_btn_w - 8;
    const reject_btn_hover = mouse_x >= reject_btn_x and mouse_x < reject_btn_x + reject_btn_w and
        mouse_y >= current_y + 4 and mouse_y < current_y + 4 + 20;
    renderer.Renderer.drawRoundedRect(reject_btn_x, current_y + 4, reject_btn_w, 20, 4, if (reject_btn_hover)
        .{ .r = 0.4, .g = 0.2, .b = 0.2, .a = 0.9 }
    else
        .{ .r = 0.25, .g = 0.14, .b = 0.14, .a = 0.7 });
    renderer.Renderer.drawText("Reject All", reject_btn_x + 6, current_y + 8, 10.0, .{ .r = 0.95, .g = 0.75, .b = 0.75, .a = 1.0 });

    current_y += bar_h + 4;

    // Draw each hunk
    for (preview.hunks.items, 0..) |hunk, hunk_idx| {
        const accepted = hunk.accepted;
        const dim: f32 = if (accepted) 1.0 else 0.5;

        // File path header
        const header_bg = if (accepted)
            renderer.Color{ .r = 0.14, .g = 0.22, .b = 0.16, .a = 1.0 }
        else
            renderer.Color{ .r = 0.18, .g = 0.14, .b = 0.14, .a = 1.0 };
        renderer.Renderer.drawRoundedRect(x, current_y, content_w, header_h, 4, header_bg);

        // Accept/reject checkbox
        const checkbox_x = x + 6;
        const checkbox_y = current_y + 5;
        const checkbox_hover = mouse_x >= checkbox_x and mouse_x < checkbox_x + 16 and
            mouse_y >= checkbox_y and mouse_y < checkbox_y + 12;
        const checkbox_color = if (accepted)
            renderer.Color{ .r = 0.3, .g = 0.7, .b = 0.4, .a = 1.0 }
        else
            renderer.Color{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 0.8 };
        renderer.Renderer.drawRoundedRect(checkbox_x, checkbox_y, 12, 12, 2, checkbox_color);
        if (accepted) {
            renderer.Renderer.drawText("✓", checkbox_x + 1, checkbox_y, 10.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
        }
        _ = checkbox_hover;

        // File path
        var path_buf: [256:0]u8 = undefined;
        const path_clipped = if (hunk.file_path.len > 200) hunk.file_path[0..200] else hunk.file_path;
        @memcpy(path_buf[0..path_clipped.len], path_clipped);
        path_buf[path_clipped.len] = 0;
        const path_color: renderer.Color = if (accepted)
            .{ .r = 0.75, .g = 0.95, .b = 0.75, .a = 1.0 }
        else
            .{ .r = 0.65, .g = 0.55, .b = 0.55, .a = 1.0 };
        renderer.Renderer.drawText(@ptrCast(&path_buf), x + 22, current_y + 5, 10.0, path_color);

        // Toggle hint
        if (hunk_idx == 0) {
            renderer.Renderer.drawText("(click to toggle)", x + content_w - 90, current_y + 5, 9.0, .{ .r = 0.5, .g = 0.5, .b = 0.55, .a = 0.6 });
        }

        current_y += header_h;

        // Diff lines — green/red backgrounds
        for (hunk.lines) |line| {
            const bg = diff_line_style.background(line.kind, accepted);
            if (bg) |bg_color| {
                renderer.Renderer.drawRect(x, current_y - 1, content_w, line_h, bg_color);
            }

            const clipped = if (line.text.len > 511) line.text[0..511] else line.text;
            const fg = diff_line_style.foreground(line.kind, clipped, accepted, .{ .r = 0.75 * dim, .g = 0.75 * dim, .b = 0.75 * dim, .a = dim });
            renderer.Renderer.drawText(clipped, x + 4, current_y, 9.5, fg);
            current_y += line_h;
        }

        current_y += hunk_gap;
    }

    return current_y - y;
}

/// Hit test for the diff preview — returns which element was clicked.
pub const DiffHit = union(enum) {
    none,
    accept_all,
    reject_all,
    toggle_hunk: usize,
};

pub fn hitTest(
    preview: *const DiffPreview,
    x: f32,
    y: f32,
    content_w: f32,
    click_x: f32,
    click_y: f32,
) DiffHit {
    if (preview.hunks.items.len == 0) return .none;

    const bar_h: f32 = 28;
    const header_h: f32 = 22;
    const line_h: f32 = 14;
    const hunk_gap: f32 = 8;

    // Check action bar
    if (click_y >= y and click_y < y + bar_h) {
        const accept_btn_x = x + content_w - 70 - 70 - 8;
        if (click_x >= accept_btn_x and click_x < accept_btn_x + 70) return .accept_all;
        const reject_btn_x = x + content_w - 70 - 8;
        if (click_x >= reject_btn_x and click_x < reject_btn_x + 70) return .reject_all;
        return .none;
    }

    var current_y = y + bar_h + 4;
    for (preview.hunks.items, 0..) |hunk, idx| {
        // Check header (checkbox area)
        if (click_y >= current_y and click_y < current_y + header_h) {
            if (click_x >= x and click_x < x + content_w) {
                return .{ .toggle_hunk = idx };
            }
        }
        current_y += header_h;
        current_y += @as(f32, @floatFromInt(hunk.lines.len)) * line_h;
        current_y += hunk_gap;
    }

    return .none;
}

test "DiffPreview parseFromCodeBlock detects diff" {
    const allocator = std.testing.allocator;
    var preview = DiffPreview.init(allocator);
    defer preview.deinit();

    const code =
        \\-const x = old_value;
        \\+const x = new_value;
        \\+const y = extra;
    ;
    const is_diff = try preview.parseFromCodeBlock(code, "diff", "test.zig");
    try std.testing.expect(is_diff);
    try std.testing.expectEqual(@as(usize, 1), preview.hunks.items.len);
    try std.testing.expectEqual(@as(usize, 3), preview.hunks.items[0].lines.len);
}

test "DiffPreview parseFromCodeBlock rejects non-diff" {
    const allocator = std.testing.allocator;
    var preview = DiffPreview.init(allocator);
    defer preview.deinit();

    const code = "const x = 42;\nconst y = x + 1;";
    const is_diff = try preview.parseFromCodeBlock(code, "zig", null);
    try std.testing.expect(!is_diff);
    try std.testing.expectEqual(@as(usize, 0), preview.hunks.items.len);
}

test "DiffPreview toggle and acceptAll" {
    const allocator = std.testing.allocator;
    var preview = DiffPreview.init(allocator);
    defer preview.deinit();

    const code = "-old\n+new";
    _ = try preview.parseFromCodeBlock(code, "diff", "a.zig");
    try std.testing.expect(preview.hunks.items[0].accepted);

    preview.toggleHunk(0);
    try std.testing.expect(!preview.hunks.items[0].accepted);

    preview.acceptAll();
    try std.testing.expect(preview.hunks.items[0].accepted);

    preview.rejectAll();
    try std.testing.expect(!preview.hunks.items[0].accepted);
}

test "hitTest detects accept_all button" {
    const allocator = std.testing.allocator;
    var preview = DiffPreview.init(allocator);
    defer preview.deinit();

    _ = try preview.parseFromCodeBlock("-old\n+new", "diff", "a.zig");

    const content_w: f32 = 400;
    const x: f32 = 100;
    const y: f32 = 200;
    const accept_x = x + content_w - 70 - 70 - 8 + 10;
    const hit = hitTest(&preview, x, y, content_w, accept_x, y + 10);
    try std.testing.expect(hit == .accept_all);
}

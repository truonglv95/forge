const std = @import("std");
const renderer = @import("forge-renderer");
const editor = @import("forge-editor");
const layout = @import("../core/layout.zig");
const agent_session = @import("../../agent/session.zig");
const word_wrap = @import("../editor/word_wrap.zig");
const editor_scroll = @import("../editor/editor_scroll.zig");
const scrollbar = @import("../core/scrollbar.zig");
const state = @import("../core/state.zig");

pub const prompt_font_size: f32 = 13.5;
pub const prompt_line_h: f32 = 18.0;
pub const scroll_bar_w: f32 = scrollbar.track_w;

pub const composer_pad: f32 = 12;
pub const input_min_h: f32 = 56;
pub const input_max_h: f32 = 220;
pub const composer_chrome_h: f32 = 12;
pub const composer_base_h: f32 = composer_chrome_h + input_min_h;
pub const composer_max_h: f32 = composer_chrome_h + input_max_h;
pub const attachment_row_h: f32 = 26;
pub const chip_h: f32 = 18;
pub const chip_remove_w: f32 = 16;
pub const toolbar_h: f32 = 24;
pub const input_pad: f32 = 12;

pub const ModelOption = struct {
    id: []const u8,
    label: []const u8,
    provider: []const u8,
};

pub const default_models = [_]ModelOption{
    .{ .id = "qwen3.5:35b", .label = "Qwen 3.5 35B (Ollama)", .provider = "ollama" },
    .{ .id = "qwen2.5-coder:7b", .label = "Qwen 2.5 Coder 7B (Ollama)", .provider = "ollama" },
    .{ .id = "gemini-2.5-flash", .label = "Gemini 2.5 Flash", .provider = "gemini" },
    .{ .id = "gemini-2.5-pro", .label = "Gemini 2.5 Pro", .provider = "gemini" },
    .{ .id = "gemini-2.0-flash", .label = "Gemini 2.0 Flash", .provider = "gemini" },
    .{ .id = "openai/gpt-4o-mini", .label = "GPT-4o Mini (OpenRouter)", .provider = "openrouter" },
    .{ .id = "anthropic/claude-sonnet-4", .label = "Claude Sonnet 4 (OpenRouter)", .provider = "openrouter" },
};

pub fn parseCustomModels(allocator: std.mem.Allocator, custom_str: []const u8) ![]ModelOption {
    var list: std.ArrayList(ModelOption) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, &default_models);

    var it = std.mem.splitScalar(u8, custom_str, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        var field_it = std.mem.splitScalar(u8, trimmed, '|');
        const id = field_it.next() orelse continue;
        const label = field_it.next() orelse continue;
        const provider = field_it.next() orelse continue;

        try list.append(allocator, .{
            .id = try allocator.dupe(u8, std.mem.trim(u8, id, &std.ascii.whitespace)),
            .label = try allocator.dupe(u8, std.mem.trim(u8, label, &std.ascii.whitespace)),
            .provider = try allocator.dupe(u8, std.mem.trim(u8, provider, &std.ascii.whitespace)),
        });
    }

    return list.toOwnedSlice(allocator);
}

pub const ModeOption = struct {
    mode: agent_session.Mode,
    label: []const u8,
};

pub const modes = [_]ModeOption{
    .{ .mode = .ask, .label = "Ask · read only" },
    .{ .mode = .plan, .label = "Plan · spec only" },
    .{ .mode = .agent, .label = "Agent · tools + edits" },
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub const Layout = struct {
    composer_top: f32,
    composer_h: f32,
    box_x: f32,
    box_w: f32,
    input_y: f32,
    input_h: f32,
    toolbar_y: f32,
    visual_lines: usize,
    scroll_max: f32,
    mode_btn: Rect,
    model_btn: Rect,
    scope_btn: Rect,
    send_btn: Rect,
};

pub fn promptMaxWidth(agent_w: f32) f32 {
    return @max(40, agent_w - composer_pad * 2 - input_pad * 2 - scroll_bar_w);
}

pub fn visualLineCount(prompt: *const editor.Buffer, agent_w: f32) usize {
    return word_wrap.totalVisualLines(prompt, promptMaxWidth(agent_w), prompt_font_size);
}

pub fn composerHeight(attachment_count: usize, visual_lines: usize) f32 {
    const lines = @max(1, visual_lines);
    const desired_input = @as(f32, @floatFromInt(lines)) * prompt_line_h + input_pad * 2;
    const input_h = std.math.clamp(desired_input, input_min_h, input_max_h);
    const attachment_extra = if (attachment_count > 0) attachment_row_h else 0;
    return composer_chrome_h + attachment_extra + input_h;
}

pub fn inputTextHeight(attachment_count: usize, visual_lines: usize) f32 {
    const composer_h = composerHeight(attachment_count, visual_lines);
    const attachment_extra = if (attachment_count > 0) attachment_row_h else 0;
    const input_box_h = composer_h - composer_chrome_h - attachment_extra;
    return @max(prompt_line_h, input_box_h - input_pad - 4);
}

pub fn promptScrollMax(visual_lines: usize, input_h: f32) f32 {
    const content_h = @as(f32, @floatFromInt(@max(1, visual_lines))) * prompt_line_h;
    const visible_h = @max(0, input_h - 4);
    return @max(0, content_h - visible_h);
}

pub fn clampPromptScroll(scroll_y: f32, visual_lines: usize, input_h: f32) f32 {
    return std.math.clamp(scroll_y, 0, promptScrollMax(visual_lines, input_h));
}

fn caretPosition(prompt: *const editor.Buffer, max_w: f32) struct { x: f32, y: f32 } {
    const row = prompt.cursor.row;
    const col = prompt.cursor.col;
    var visual_line: usize = 0;
    for (0..prompt.lineCount()) |line_idx| {
        const line = prompt.lineAt(line_idx);
        var start: usize = 0;
        while (start <= line.len) {
            const end = if (start < line.len) word_wrap.breakAt(line, start, max_w, prompt_font_size) else start;
            if (line_idx == row and col >= start and (col <= end or end >= line.len)) {
                const prefix_end = @min(col, line.len);
                return .{
                    .x = editor_scroll.textWidth(line[start..prefix_end], prompt_font_size),
                    .y = @as(f32, @floatFromInt(visual_line)) * prompt_line_h,
                };
            }
            visual_line += 1;
            if (end >= line.len) break;
            start = end;
            while (start < line.len and line[start] == ' ') start += 1;
        }
    }
    return .{ .x = 0, .y = 0 };
}

pub fn ensureCursorVisible(
    scroll_y: f32,
    prompt: *const editor.Buffer,
    max_w: f32,
    input_h: f32,
) f32 {
    const caret = caretPosition(prompt, max_w);
    const visible_h = @max(0, input_h - 4);
    if (caret.y < scroll_y) return caret.y;
    if (caret.y + prompt_line_h > scroll_y + visible_h) {
        return caret.y + prompt_line_h - visible_h;
    }
    return scroll_y;
}

pub fn composerTop(window_h: f32, attachment_count: usize, agent_w: f32, prompt: *const editor.Buffer) f32 {
    const visual_lines = visualLineCount(prompt, agent_w);
    const composer_h = composerHeight(attachment_count, visual_lines);
    return window_h - layout.status_height - composer_h - composer_pad;
}

pub fn computeLayout(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    attachment_count: usize,
    prompt: *const editor.Buffer,
) Layout {
    const visual_lines = visualLineCount(prompt, agent_w);
    const composer_h = composerHeight(attachment_count, visual_lines);
    const composer_top = window_h - layout.status_height - composer_h - composer_pad;
    const box_x = agent_x + composer_pad;
    const box_w = agent_w - composer_pad * 2;

    // The input box takes up the upper part of the composer height
    // The toolbar (mode, model) sits below it
    const toolbar_y = composer_top + composer_h - toolbar_h;

    // Inside the input box, text starts at input_y
    const input_y = composer_top + 8 + if (attachment_count > 0) attachment_row_h else 0;

    // Send and Scope buttons are inside the input box, at the bottom right
    const input_box_h = composer_h - composer_chrome_h;
    const inner_bottom = composer_top + input_box_h;

    // input_h is the area for the text itself
    const input_h = inputTextHeight(attachment_count, visual_lines);

    const mode_btn = Rect{ .x = box_x, .y = toolbar_y + 4, .w = 0, .h = 0 };
    const model_btn = Rect{ .x = box_x, .y = toolbar_y + 4, .w = 0, .h = 0 };

    // Send and scope are positioned at the bottom right inside the input box
    const send_btn = Rect{ .x = box_x + box_w - 32, .y = inner_bottom - 28, .w = 24, .h = 24 };
    const scope_btn = Rect{ .x = send_btn.x - 30, .y = inner_bottom - 28, .w = 24, .h = 24 };

    return .{
        .composer_top = composer_top,
        .composer_h = composer_h,
        .box_x = box_x,
        .box_w = box_w,
        .input_y = input_y,
        .input_h = input_h,
        .toolbar_y = toolbar_y,
        .visual_lines = visual_lines,
        .scroll_max = promptScrollMax(visual_lines, input_h),
        .mode_btn = mode_btn,
        .model_btn = model_btn,
        .scope_btn = scope_btn,
        .send_btn = send_btn,
    };
}

fn modeLabel(mode: agent_session.Mode) []const u8 {
    for (modes) |entry| {
        if (entry.mode == mode) return entry.label;
    }
    return @tagName(mode);
}

fn modelLabel(models: []const ModelOption, model_id: ?[]const u8) []const u8 {
    if (model_id) |id| {
        for (models) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry.label;
        }
        return id;
    }
    if (models.len > 0) return models[0].label;
    return "Unknown";
}

fn promptIsEmpty(prompt: *const editor.Buffer) bool {
    return prompt.lineCount() == 1 and prompt.lineAt(0).len == 0;
}

fn drawWrappedPrompt(
    prompt: *const editor.Buffer,
    text_x: f32,
    text_y: f32,
    max_w: f32,
    visible_h: f32,
    scroll_y: f32,
    color: renderer.Color,
) void {
    var visual_line: usize = 0;
    for (0..prompt.lineCount()) |line_idx| {
        const line = prompt.lineAt(line_idx);
        var start: usize = 0;
        while (start <= line.len) {
            const end = if (start < line.len) word_wrap.breakAt(line, start, max_w, prompt_font_size) else start;
            const slice = line[start..end];
            const y = text_y + @as(f32, @floatFromInt(visual_line)) * prompt_line_h - scroll_y;
            if (y + prompt_line_h >= text_y and y <= text_y + visible_h) {
                var line_buf: [512]u8 = undefined;
                const clipped = if (slice.len > line_buf.len) slice[0..line_buf.len] else slice;
                @memcpy(line_buf[0..clipped.len], clipped);
                renderer.Renderer.drawText(
                    line_buf[0..clipped.len],
                    text_x,
                    y,
                    prompt_font_size,
                    color,
                );
            }
            visual_line += 1;
            if (end >= line.len) break;
            start = end;
            while (start < line.len and line[start] == ' ') start += 1;
        }
    }
}

fn drawPromptScrollbar(layout_info: Layout, scroll_y: f32, x: f32, show: bool) void {
    if (!show or layout_info.scroll_max <= 0) return;
    const track_x = x;
    const track_y = layout_info.input_y + 2;
    const track_h = layout_info.input_h - 4;
    const content_h = @as(f32, @floatFromInt(@max(1, layout_info.visual_lines))) * prompt_line_h;
    scrollbar.drawVertical(track_x, track_y, track_h, scroll_y, layout_info.scroll_max, content_h, track_h, true);
}

fn drawDropdownButton(rect: Rect, label: []const u8, open: bool, enabled: bool, prefix: []const u8, color_tag: ?renderer.Color) void {
    _ = open;
    const prefix_w = if (prefix.len > 0) @as(f32, @floatFromInt(prefix.len)) * 6.5 + 4.0 else 0;
    const label_max_w = rect.w - prefix_w - 4.0;

    var label_buf: [64:0]u8 = undefined;
    const clipped = if (label.len > 58) label[0..58] else label;
    @memcpy(label_buf[0..clipped.len], clipped);
    label_buf[clipped.len] = 0;

    const fg = if (enabled)
        renderer.Color{ .r = 0.5, .g = 0.5, .b = 0.55, .a = 1.0 }
    else
        renderer.Color{ .r = 0.35, .g = 0.35, .b = 0.4, .a = 1.0 };

    var x = rect.x;

    if (prefix.len > 0) {
        const p_color = color_tag orelse fg;
        renderer.Renderer.drawText(prefix, x, rect.y + 4, 11.5, p_color);
        x += prefix_w;
    }

    var display_len = clipped.len;
    while (display_len > 0 and renderer.Renderer.measureText(label_buf[0..display_len], 11.5) > label_max_w) {
        display_len -= 1;
    }
    label_buf[display_len] = 0;

    renderer.Renderer.drawText(@ptrCast(&label_buf), x, rect.y + 4, 11.5, fg);
}

fn drawMenu(rect: Rect, labels: [][]const u8, selected: usize) void {
    const row_h: f32 = 24;
    const menu_h = @as(f32, @floatFromInt(labels.len)) * row_h + 8;
    const menu_y = rect.y - menu_h - 4;
    renderer.Renderer.drawRoundedRect(rect.x, menu_y, rect.w, menu_h, 8, .{ .r = 0.12, .g = 0.14, .b = 0.18, .a = 1.0 });
    var row_y = menu_y + 4;
    for (labels, 0..) |item, index| {
        if (index == selected) {
            renderer.Renderer.drawRoundedRect(rect.x + 4, row_y, rect.w - 8, row_h - 2, 4, .{ .r = 0.2, .g = 0.32, .b = 0.48, .a = 1.0 });
        }
        var item_buf: [64:0]u8 = undefined;
        const clipped = if (item.len > 63) item[0..63] else item;
        @memcpy(item_buf[0..clipped.len], clipped);
        item_buf[clipped.len] = 0;
        renderer.Renderer.drawText(@ptrCast(&item_buf), rect.x + 10, row_y + 4, 10.5, .{ .r = 0.92, .g = 0.94, .b = 0.98, .a = 1.0 });
        row_y += row_h;
    }
}

pub fn chipWidth(label: []const u8) f32 {
    const text_w = @as(f32, @floatFromInt(@min(label.len * 6 + 12, 100)));
    return text_w + chip_remove_w;
}

pub fn hitAttachmentRemove(
    agent: *agent_session.Session,
    layout_info: Layout,
    x: f32,
    y: f32,
) ?usize {
    agent.lock();
    defer agent.unlock();
    if (agent.attachments.items.len == 0) return null;
    var chip_x = layout_info.box_x + 12;
    const chip_y = layout_info.composer_top + 8;
    if (y < chip_y or y >= chip_y + chip_h) return null;
    for (agent.attachments.items, 0..) |attachment, index| {
        var label_buf: [96:0]u8 = undefined;
        const prefix = switch (attachment.kind) {
            .image => "img",
            .text_snippet => "txt",
        };
        const chip = std.fmt.bufPrint(&label_buf, "{s} {s}", .{ prefix, attachment.label }) catch attachment.label;
        const chip_w = chipWidth(chip);
        const remove_x = chip_x + chip_w - chip_remove_w;
        if (x >= remove_x and x < chip_x + chip_w) return index;
        chip_x += chip_w + 6;
    }
    return null;
}

pub fn draw(
    agent: *agent_session.Session,
    layout_info: Layout,
    model_id: ?[]const u8,
    models: []const ModelOption,
    prompt: *const editor.Buffer,
    prompt_scroll_y: f32,
    show_cursor: bool,
    worker_running: bool,
    show_review: bool,
) void {
    const disabled = worker_running or show_review;
    const bg = if (disabled)
        renderer.Color{ .r = 0.17, .g = 0.17, .b = 0.17, .a = 1.0 }
    else
        renderer.Color{ .r = 0.22, .g = 0.22, .b = 0.22, .a = 1.0 };
    const outline_color = renderer.Color{ .r = 0.38, .g = 0.44, .b = 0.52, .a = 0.9 };

    const input_box_h = layout_info.composer_h - composer_chrome_h;
    renderer.Renderer.drawRoundedRect(layout_info.box_x, layout_info.composer_top, layout_info.box_w, input_box_h, 6, outline_color);
    renderer.Renderer.drawRoundedRect(layout_info.box_x + 1, layout_info.composer_top + 1, layout_info.box_w - 2, input_box_h - 2, 5, bg);

    agent.lock();
    const attachment_count = agent.attachments.items.len;
    const mode_menu_open = agent.mode_menu_open;
    const model_menu_open = agent.model_menu_open;
    defer agent.unlock();

    if (attachment_count > 0) {
        var chip_x = layout_info.box_x + 12;
        const chip_y = layout_info.composer_top + 8;
        agent.lock();
        defer agent.unlock();
        for (agent.attachments.items, 0..) |attachment, index| {
            var chip_buf: [96:0]u8 = undefined;
            const prefix = switch (attachment.kind) {
                .image => "img",
                .text_snippet => "txt",
            };
            const chip = std.fmt.bufPrint(&chip_buf, "{s} {s}", .{ prefix, attachment.label }) catch attachment.label;
            chip_buf[chip.len] = 0;
            const chip_w = chipWidth(chip);
            renderer.Renderer.drawRoundedRect(chip_x, chip_y, chip_w, chip_h, 5, .{ .r = 0.18, .g = 0.26, .b = 0.36, .a = 1.0 });
            renderer.Renderer.drawText(@ptrCast(&chip_buf), chip_x + 6, chip_y + 2, 9.5, .{ .r = 0.85, .g = 0.95, .b = 1.0, .a = 1.0 });
            const remove_x = chip_x + chip_w - chip_remove_w;
            renderer.Renderer.drawText("×", remove_x + 3, chip_y + 1, 12.0, .{ .r = 0.75, .g = 0.8, .b = 0.85, .a = 1.0 });
            chip_x += chip_w + 6;
            _ = index;
        }
    }

    const text_x = layout_info.box_x + input_pad;
    const text_y = layout_info.input_y + 1;
    const max_w = @max(40, layout_info.box_w - input_pad * 2 - scroll_bar_w);
    const visible_h = layout_info.input_h;
    const text_color = renderer.Color{ .r = 0.94, .g = 0.94, .b = 0.96, .a = 1.0 };
    const scroll_y = clampPromptScroll(prompt_scroll_y, layout_info.visual_lines, layout_info.input_h);

    renderer.Renderer.setClipRect(text_x, layout_info.input_y, max_w + scroll_bar_w, layout_info.input_h);

    if (promptIsEmpty(prompt) and !disabled) {
        renderer.Renderer.drawText("Type a message...", text_x, text_y, 13.0, .{
            .r = 0.62,
            .g = 0.64,
            .b = 0.68,
            .a = 1.0,
        });
    } else {
        drawWrappedPrompt(prompt, text_x, text_y, max_w, visible_h, scroll_y, text_color);
    }

    if (show_cursor) {
        const caret = caretPosition(prompt, max_w);
        const caret_y = caret.y - scroll_y;
        if (caret_y >= 0 and caret_y + prompt_line_h <= visible_h + 4) {
            renderer.Renderer.drawRect(text_x + caret.x, text_y + caret_y, 1.5, 16, .{ .r = 0.9, .g = 0.9, .b = 0.95, .a = 1.0 });
        }
    }

    renderer.Renderer.clearClipRect();
    const show_scroll = scrollbar.hovered(
        state.last_mouse_x,
        state.last_mouse_y,
        layout_info.box_x,
        layout_info.composer_top,
        layout_info.box_w,
        layout_info.composer_h,
    );
    drawPromptScrollbar(layout_info, scroll_y, layout_info.box_x + layout_info.box_w - scroll_bar_w - 4, show_scroll);

    _ = mode_menu_open;
    _ = model_menu_open;
    _ = model_id;
    _ = models;

    // Render Attach (Scope) button
    const scope_hover = if (disabled) false else state.last_mouse_x >= layout_info.scope_btn.x and state.last_mouse_x < layout_info.scope_btn.x + layout_info.scope_btn.w and state.last_mouse_y >= layout_info.scope_btn.y and state.last_mouse_y < layout_info.scope_btn.y + layout_info.scope_btn.h;
    if (scope_hover) {
        renderer.Renderer.drawRoundedRect(layout_info.scope_btn.x, layout_info.scope_btn.y, layout_info.scope_btn.w, layout_info.scope_btn.h, 4, .{ .r = 0.25, .g = 0.25, .b = 0.3, .a = 1.0 });
    }
    renderer.Renderer.drawSvg(renderer.icons.paperclip, layout_info.scope_btn.x + 2, layout_info.scope_btn.y + 2, 20, 20, .{ .r = 0.68, .g = 0.72, .b = 0.78, .a = 1.0 });

    // Render Send button
    const send_hover = if (disabled) false else state.last_mouse_x >= layout_info.send_btn.x and state.last_mouse_x < layout_info.send_btn.x + layout_info.send_btn.w and state.last_mouse_y >= layout_info.send_btn.y and state.last_mouse_y < layout_info.send_btn.y + layout_info.send_btn.h;
    if (send_hover) {
        renderer.Renderer.drawRoundedRect(layout_info.send_btn.x, layout_info.send_btn.y, layout_info.send_btn.w, layout_info.send_btn.h, 4, .{ .r = 0.25, .g = 0.25, .b = 0.3, .a = 1.0 });
    }
    const send_c = if (disabled) renderer.Color{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 1.0 } else renderer.Color{ .r = 0.72, .g = 0.76, .b = 0.84, .a = 1.0 };
    renderer.Renderer.drawSvg(renderer.icons.send, layout_info.send_btn.x + 2, layout_info.send_btn.y + 2, 20, 20, send_c);
}

pub const Hit = enum {
    none,
    input,
    mode_menu,
    model_menu,
    scope,
    send,
    attachment,
    mode_item,
    model_item,
};

pub fn hitTest(
    agent: *agent_session.Session,
    layout_info: Layout,
    models: []const ModelOption,
    x: f32,
    y: f32,
) Hit {
    agent.lock();
    defer agent.unlock();

    if (agent.mode_menu_open) {
        const row_h: f32 = 24;
        const menu_h = @as(f32, @floatFromInt(modes.len)) * row_h + 8;
        const menu_y = layout_info.mode_btn.y - menu_h - 4;
        if (x >= layout_info.mode_btn.x and x < layout_info.mode_btn.x + layout_info.mode_btn.w and y >= menu_y and y < menu_y + menu_h) {
            const row = @as(usize, @intFromFloat((y - menu_y - 4) / row_h));
            if (row < modes.len) return .mode_item;
        }
    }

    if (agent.model_menu_open) {
        const row_h: f32 = 24;
        const menu_h = @as(f32, @floatFromInt(models.len)) * row_h + 8;
        const menu_y = layout_info.model_btn.y - menu_h - 4;
        if (x >= layout_info.model_btn.x and x < layout_info.model_btn.x + layout_info.model_btn.w and y >= menu_y and y < menu_y + menu_h) {
            const row = @as(usize, @intFromFloat((y - menu_y - 4) / row_h));
            if (row < models.len) return .model_item;
        }
    }

    const input_rect = Rect{
        .x = layout_info.box_x + input_pad,
        .y = layout_info.input_y,
        .w = layout_info.box_w - input_pad * 2,
        .h = layout_info.input_h,
    };
    if (input_rect.contains(x, y)) return .input;

    if (layout_info.mode_btn.contains(x, y)) return .mode_menu;
    if (layout_info.model_btn.contains(x, y)) return .model_menu;
    if (layout_info.scope_btn.contains(x, y)) return .scope;
    if (layout_info.send_btn.contains(x, y)) return .send;
    return .none;
}

pub fn modeIndexAt(agent: *agent_session.Session, layout_info: Layout, x: f32, y: f32) ?usize {
    agent.lock();
    defer agent.unlock();
    if (!agent.mode_menu_open) return null;
    const row_h: f32 = 24;
    const menu_h = @as(f32, @floatFromInt(modes.len)) * row_h + 8;
    const menu_y = layout_info.mode_btn.y - menu_h - 4;
    if (x < layout_info.mode_btn.x or x >= layout_info.mode_btn.x + layout_info.mode_btn.w) return null;
    if (y < menu_y or y >= menu_y + menu_h) return null;
    const row = @as(usize, @intFromFloat((y - menu_y - 4) / row_h));
    if (row >= modes.len) return null;
    return row;
}

pub fn modelIndexAt(agent: *agent_session.Session, layout_info: Layout, models: []const ModelOption, x: f32, y: f32) ?usize {
    agent.lock();
    defer agent.unlock();
    if (!agent.model_menu_open) return null;
    const row_h: f32 = 24;
    const menu_h = @as(f32, @floatFromInt(models.len)) * row_h + 8;
    const menu_y = layout_info.model_btn.y - menu_h - 4;
    if (x < layout_info.model_btn.x or x >= layout_info.model_btn.x + layout_info.model_btn.w) return null;
    if (y < menu_y or y >= menu_y + menu_h) return null;
    const row = @as(usize, @intFromFloat((y - menu_y - 4) / row_h));
    if (row >= models.len) return null;
    return row;
}

pub fn hitPromptInput(
    agent_x: f32,
    agent_w: f32,
    window_h: f32,
    attachment_count: usize,
    prompt: *const editor.Buffer,
    x: f32,
    y: f32,
) bool {
    const layout_info = computeLayout(agent_x, agent_w, window_h, attachment_count, prompt);
    const input_rect = Rect{
        .x = layout_info.box_x + input_pad,
        .y = layout_info.input_y,
        .w = layout_info.box_w - input_pad * 2,
        .h = layout_info.input_h,
    };
    return input_rect.contains(x, y);
}

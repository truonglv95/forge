const std = @import("std");
const context_inspector_mod = @import("../ui/agent/context_inspector.zig");
const agent_panel_mod = @import("../ui/agent/agent_panel.zig");
const chat_bubble_mod = @import("../ui/agent/chat_bubble.zig");
const tool_step_card_mod = @import("../ui/agent/tool_step_card.zig");
const chat_message_lines_mod = @import("../ui/agent/chat_message_lines.zig");

pub const Cache = struct {
    content_w: f32 = -1,
    agent_h: f32 = -1,
    history_len: usize = 0,
    built_revision: u32 = 0,
    stream_len: usize = 0,
    thinking_len: usize = 0,
    steps_len: usize = 0,
    worker_running: bool = false,
    bottom_reserved: f32 = -1,
    history_content_h: f32 = 0,
    content_h: f32 = 0,
    viewport_h: f32 = 0,
    max_scroll: f32 = 0,
    message_heights: std.ArrayList(f32) = .empty,
    message_prefix: std.ArrayList(f32) = .empty,
    message_lines: std.ArrayList(chat_message_lines_mod.Entry) = .empty,
    stream_entry: chat_message_lines_mod.Entry = .{},
    stream_built_len: usize = 0,
    chrome_prompt_lines: usize = 0,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.message_lines.items) |*entry| entry.deinit(allocator);
        self.stream_entry.deinit(allocator);
        self.message_heights.deinit(allocator);
        self.message_prefix.deinit(allocator);
        self.message_lines.deinit(allocator);
    }

    pub fn invalidate(self: *Cache) void {
        self.content_w = -1;
    }
};

fn agentChrome(wb: anytype) struct {
    entry_count: usize,
    expanded: bool,
    has_detail: bool,
    attachment_count: usize,
    has_routing: bool,
} {
    wb.agent.lock();
    defer wb.agent.unlock();
    const expanded = wb.agent.context_inspector_expanded;
    return .{
        .entry_count = wb.agent.context_entries.items.len,
        .expanded = expanded,
        .has_detail = wb.agent.context_selected_index != null and expanded,
        .attachment_count = wb.agent.attachments.items.len,
        .has_routing = wb.agent.routing_task_intent.len > 0,
    };
}

fn liveContentHeight(wb: anytype, content_w: f32) f32 {
    wb.agent.lock();
    defer wb.agent.unlock();
    const worker_running = wb.agent.worker_running;
    const steps_len = wb.agent.agent_steps.items.len;
    if (!worker_running and steps_len == 0) return 0;

    var lines: usize = 0;
    lines += chat_bubble_mod.estimateLiveLines(
        wb.agent.thinking_text.items,
        wb.agent.stream_text.items,
        worker_running,
        content_w,
    );
    const steps_h = tool_step_card_mod.totalStepsHeight(wb.agent.agent_steps.items, content_w, wb.agent.mode);
    lines += @as(usize, @intFromFloat(std.math.ceil(steps_h / chat_bubble_mod.line_h)));
    return @as(f32, @floatFromInt(lines)) * chat_bubble_mod.line_h;
}

fn appendMessageMetrics(cache: *Cache, wb: anytype, msg_h: f32, line_entry: chat_message_lines_mod.Entry) void {
    const prefix = if (cache.message_prefix.items.len > 0)
        cache.message_prefix.items[cache.message_prefix.items.len - 1] + cache.message_heights.items[cache.message_heights.items.len - 1]
    else
        0;
    cache.message_heights.append(wb.allocator, msg_h) catch {
        var owned = line_entry;
        owned.deinit(wb.allocator);
        return;
    };
    cache.message_prefix.append(wb.allocator, prefix) catch {
        _ = cache.message_heights.pop();
        var owned = line_entry;
        owned.deinit(wb.allocator);
        return;
    };
    cache.message_lines.append(wb.allocator, line_entry) catch {
        _ = cache.message_prefix.pop();
        _ = cache.message_heights.pop();
        var owned = line_entry;
        owned.deinit(wb.allocator);
    };
}

fn messageTextWidth(content_w: f32, is_user: bool) f32 {
    if (is_user) return chat_bubble_mod.textMaxWidth(content_w);
    return content_w;
}

fn buildLineEntry(wb: anytype, msg: anytype, content_w: f32) chat_message_lines_mod.Entry {
    const text_w = messageTextWidth(content_w, msg.role == .user);
    return chat_message_lines_mod.build(wb.allocator, msg.content, text_w) catch .{};
}

fn messageHeight(line_entry: chat_message_lines_mod.Entry, is_user: bool, text: []const u8, content_w: f32) f32 {
    if (!agent_panel_mod.chatHasVisibleContent(text)) return 0;
    return chat_message_lines_mod.layoutHeight(line_entry, is_user, text, content_w);
}

fn rebuildHistory(wb: anytype, cache: *Cache, content_w: f32) void {
    const total = wb.chat_history.items.len;
    if (cache.content_w == content_w and cache.message_heights.items.len < total) {
        var history_h = cache.history_content_h;
        var i = cache.message_heights.items.len;
        while (i < total) : (i += 1) {
            const msg = wb.chat_history.items[i];
            const line_entry = buildLineEntry(wb, msg, content_w);
            const msg_h = messageHeight(line_entry, msg.role == .user, msg.content, content_w);
            appendMessageMetrics(cache, wb, msg_h, line_entry);
            history_h += msg_h;
        }
        cache.history_content_h = history_h;
        cache.history_len = total;
        cache.built_revision = wb.chat_history_revision;
        return;
    }

    cache.message_heights.clearRetainingCapacity();
    cache.message_prefix.clearRetainingCapacity();
    for (cache.message_lines.items) |*entry| entry.deinit(wb.allocator);
    cache.message_lines.clearRetainingCapacity();
    var history_h: f32 = 0;
    for (wb.chat_history.items) |msg| {
        const line_entry = buildLineEntry(wb, msg, content_w);
        const msg_h = messageHeight(line_entry, msg.role == .user, msg.content, content_w);
        appendMessageMetrics(cache, wb, msg_h, line_entry);
        history_h += msg_h;
    }
    cache.history_content_h = history_h;
    cache.history_len = total;
    cache.content_w = content_w;
    cache.built_revision = wb.chat_history_revision;
}

pub fn firstVisibleIndex(cache: *const Cache, scroll_y: f32, content_prefix: f32) usize {
    if (cache.message_prefix.items.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = cache.message_prefix.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const end = content_prefix + cache.message_prefix.items[mid] + cache.message_heights.items[mid];
        if (end <= scroll_y) lo = mid + 1 else hi = mid;
    }
    return lo;
}

pub fn lastVisibleIndex(cache: *const Cache, scroll_y: f32, content_prefix: f32, viewport_h: f32) usize {
    if (cache.message_prefix.items.len == 0) return 0;
    const bottom = scroll_y + viewport_h;
    var lo: usize = 0;
    var hi: usize = cache.message_prefix.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const start = content_prefix + cache.message_prefix.items[mid];
        if (start < bottom) lo = mid + 1 else hi = mid;
    }
    return @min(lo, cache.message_prefix.items.len);
}

pub fn historyYOffset(cache: *const Cache, index: usize) f32 {
    if (index >= cache.message_prefix.items.len) return cache.history_content_h;
    return cache.message_prefix.items[index];
}

fn layoutChrome(wb: anytype, agent_h: f32) struct {
    bottom: f32,
    viewport: f32,
} {
    const chrome = agentChrome(wb);
    const bottom = agent_panel_mod.bottomReserved(chrome.attachment_count, wb.agent_panel_width, &wb.prompt_buffer) +
        context_inspector_mod.stripHeight(chrome.expanded, chrome.entry_count, chrome.has_detail, chrome.has_routing);
    const strip_top = context_inspector_mod.stripTop(
        agent_h,
        chrome.expanded,
        chrome.entry_count,
        chrome.attachment_count,
        wb.agent_panel_width,
        &wb.prompt_buffer,
        chrome.has_detail,
        chrome.has_routing,
    );
    const chat_top = agent_panel_mod.chat_content_top + 8.0;
    const viewport = @max(0, strip_top - 4 - chat_top);
    return .{ .bottom = bottom, .viewport = viewport };
}

pub fn ensure(wb: anytype, agent_h: f32) void {
    const content_w = @max(40, wb.agent_panel_width - 40);
    const cache = &wb.chat_layout;

    const history_dirty = cache.content_w != content_w or cache.built_revision != wb.chat_history_revision;
    if (!history_dirty and
        cache.agent_h == agent_h and
        !cache.worker_running and
        cache.steps_len == 0 and
        cache.chrome_prompt_lines == wb.prompt_buffer.lineCount())
    {
        return;
    }

    const chrome = layoutChrome(wb, agent_h);

    wb.agent.lock();
    const stream_len = wb.agent.stream_text.items.len;
    const thinking_len = wb.agent.thinking_text.items.len;
    const steps_len = wb.agent.agent_steps.items.len;
    const worker_running = wb.agent.worker_running;
    wb.agent.unlock();

    const live_dirty = history_dirty or
        cache.stream_len != stream_len or
        cache.thinking_len != thinking_len or
        cache.steps_len != steps_len or
        cache.worker_running != worker_running;
    const chrome_dirty = cache.agent_h != agent_h or cache.bottom_reserved != chrome.bottom;

    if (!history_dirty and !live_dirty and !chrome_dirty) return;

    if (history_dirty) rebuildHistory(wb, cache, content_w);

    if (history_dirty or live_dirty) {
        const live_h = liveContentHeight(wb, content_w);
        cache.content_h = cache.history_content_h + live_h;
        cache.stream_len = stream_len;
        cache.thinking_len = thinking_len;
        cache.steps_len = steps_len;
        cache.worker_running = worker_running;

        if (stream_len != cache.stream_built_len) {
            cache.stream_entry.deinit(wb.allocator);
            wb.agent.lock();
            const stream_text = wb.agent.stream_text.items;
            wb.agent.unlock();
            cache.stream_entry = chat_message_lines_mod.build(wb.allocator, stream_text, content_w) catch .{};
            cache.stream_built_len = stream_len;
        }
    }

    cache.agent_h = agent_h;
    cache.bottom_reserved = chrome.bottom;
    cache.viewport_h = chrome.viewport;
    cache.max_scroll = @max(0, cache.content_h - chrome.viewport);
    cache.chrome_prompt_lines = wb.prompt_buffer.lineCount();
}

pub fn clampScrollY(wb: anytype, agent_h: f32) void {
    ensure(wb, agent_h);
    wb.chat_scroll_y = std.math.clamp(wb.chat_scroll_y, 0, wb.chat_layout.max_scroll);
}

pub fn scrollToEnd(wb: anytype, agent_h: f32) void {
    ensure(wb, agent_h);
    wb.chat_scroll_y = wb.chat_layout.max_scroll;
}

pub fn invalidate(wb: anytype) void {
    wb.chat_layout.invalidate();
}

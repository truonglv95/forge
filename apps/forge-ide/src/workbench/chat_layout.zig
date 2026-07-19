const std = @import("std");
const context_inspector_mod = @import("../ui/agent/context_inspector.zig");
const agent_panel_mod = @import("../ui/agent/agent_panel.zig");
const chat_bubble_mod = @import("../ui/agent/chat_bubble.zig");
const tool_step_card_mod = @import("../ui/agent/tool_step_card.zig");
const chat_message_lines_mod = @import("../ui/agent/chat_message_lines.zig");
const agent_session_mod = @import("../agent/session.zig");

const chat_composer_gap: f32 = 6.0;
const chat_bottom_padding: f32 = 32.0;

fn phaseShowsLive(phase: anytype) bool {
    return switch (phase) {
        .building_context, .sending, .streaming, .parsing, .waiting_approval => true,
        else => false,
    };
}

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
    wb.agent_ui.session.lock();
    defer wb.agent_ui.session.unlock();
    const expanded = wb.agent_ui.session.context_inspector_expanded;
    return .{
        .entry_count = wb.agent_ui.session.context_entries.items.len,
        .expanded = expanded,
        .has_detail = wb.agent_ui.session.context_selected_index != null and expanded,
        .attachment_count = wb.agent_ui.session.attachments.items.len,
        .has_routing = wb.agent_ui.session.routing_task_intent.len > 0,
    };
}

fn liveContentHeight(wb: anytype, content_w: f32) f32 {
    wb.agent_ui.session.lock();
    defer wb.agent_ui.session.unlock();
    const worker_running = wb.agent_ui.session.worker_running or phaseShowsLive(wb.agent_ui.session.phase);
    const steps_len = wb.agent_ui.session.agent_steps.items.len;
    _ = steps_len;
    if (!worker_running) return 0;

    var h: f32 = 0;
    if (worker_running and wb.agent_ui.session.stream_text.items.len == 0) {
        h += chat_bubble_mod.thinkingLineHeight();
    }
    if (wb.agent_ui.session.stream_text.items.len > 0) {
        h += chat_bubble_mod.agentMessageHeight(wb.agent_ui.session.stream_text.items, content_w);
    }
    return h;
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
    return chat_bubble_mod.agentTextWidth(content_w);
}

fn buildLineEntry(wb: anytype, msg: anytype, content_w: f32) chat_message_lines_mod.Entry {
    if (msg.role == .tool) return .{};
    const text_w = messageTextWidth(content_w, msg.role == .user);
    return chat_message_lines_mod.build(wb.allocator, msg.content, text_w) catch .{};
}

pub fn toolStepFromMessage(msg: anytype) [1]agent_session_mod.AgentStep {
    return .{.{
        .index = msg.tool_index,
        .kind = msg.tool_kind orelse "tool",
        .summary = msg.content,
        .expanded = agent_session_mod.shouldAutoExpandStep(msg.tool_kind orelse "tool", msg.tool_content),
        .content = msg.tool_content,
        .running = msg.tool_running,
    }};
}

fn messageHeight(line_entry: chat_message_lines_mod.Entry, msg: anytype, content_w: f32) f32 {
    if (msg.role == .tool) {
        var step = toolStepFromMessage(msg);
        return tool_step_card_mod.stepHeight(step[0..], 0, content_w, .agent) + 8.0;
    }
    const is_user = msg.role == .user;
    const text = msg.content;
    if (!agent_panel_mod.chatHasVisibleContent(text)) return 0;
    return chat_message_lines_mod.layoutHeight(line_entry, is_user, text, content_w);
}

fn rebuildHistory(wb: anytype, cache: *Cache, content_w: f32) void {
    const total = wb.agent_ui.chat_history.items.len;
    if (cache.content_w == content_w and cache.message_heights.items.len < total) {
        var history_h = cache.history_content_h;
        var i = cache.message_heights.items.len;
        while (i < total) : (i += 1) {
            const msg = wb.agent_ui.chat_history.items[i];
            const line_entry = buildLineEntry(wb, msg, content_w);
            const msg_h = messageHeight(line_entry, msg, content_w);
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
    for (wb.agent_ui.chat_history.items) |msg| {
        const line_entry = buildLineEntry(wb, msg, content_w);
        const msg_h = messageHeight(line_entry, msg, content_w);
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

pub fn hitTestMessageOpen(wb: anytype, agent_x: f32, agent_w: f32, event_x: f32, event_y: f32) ?usize {
    const pad: f32 = 20;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;

    if (event_x < inner_x or event_x > inner_x + content_w) return null;

    const cache = &wb.chat_layout;
    const chat_top = agent_panel_mod.chat_content_top + 8.0;

    wb.agent_ui.session.lock();
    const post_apply_visible = wb.agent_ui.session.post_apply_visible;
    const validation_failed = wb.agent_ui.session.phase == .failed;
    const validation_count = wb.agent_ui.session.validation_results.items.len;
    const resume_offer_visible = wb.agent_ui.session.resume_offer_visible;
    var resume_intent: []const u8 = "previous run";
    var resume_state: []const u8 = "interrupted";
    if (wb.agent_ui.session.resume_intent) |i| resume_intent = i;
    if (wb.agent_ui.session.resume_state) |s| resume_state = s;
    wb.agent_ui.session.unlock();

    var history_prefix: f32 = 0;
    if (post_apply_visible) {
        history_prefix += agent_panel_mod.applyBannerHeight(validation_failed, validation_count) + 4;
    }
    if (resume_offer_visible) {
        history_prefix += agent_panel_mod.resumeBannerHeight(agent_w, resume_intent, resume_state) + 4;
    }

    const scroll_y = wb.chat_scroll_y;
    const base_y = chat_top - scroll_y + history_prefix;
    const start_i = firstVisibleIndex(cache, scroll_y, history_prefix);
    const end_i = lastVisibleIndex(cache, scroll_y, history_prefix, cache.viewport_h);

    for (wb.agent_ui.chat_history.items[start_i..end_i], start_i..) |msg, i| {
        if (msg.role != .agent) continue;
        if (i >= cache.message_heights.items.len) break;
        const msg_h = cache.message_heights.items[i];
        if (msg_h <= 0) continue;
        const msg_y = base_y + historyYOffset(cache, i);

        if (chat_bubble_mod.hitTestAgentOpen(inner_x, content_w, msg_y, event_x, event_y)) {
            return i;
        }
    }
    return null;
}

pub fn hitTestMessageCopy(wb: anytype, agent_x: f32, agent_w: f32, event_x: f32, event_y: f32) ?usize {
    const pad: f32 = 20;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;

    if (event_x < inner_x or event_x > inner_x + content_w) return null;

    const cache = &wb.chat_layout;
    const chat_top = agent_panel_mod.chat_content_top + 8.0;

    wb.agent_ui.session.lock();
    const post_apply_visible = wb.agent_ui.session.post_apply_visible;
    const validation_failed = wb.agent_ui.session.phase == .failed;
    const validation_count = wb.agent_ui.session.validation_results.items.len;
    const resume_offer_visible = wb.agent_ui.session.resume_offer_visible;
    var resume_intent: []const u8 = "previous run";
    var resume_state: []const u8 = "interrupted";
    if (wb.agent_ui.session.resume_intent) |i| resume_intent = i;
    if (wb.agent_ui.session.resume_state) |s| resume_state = s;
    wb.agent_ui.session.unlock();

    var history_prefix: f32 = 0;
    if (post_apply_visible) {
        history_prefix += agent_panel_mod.applyBannerHeight(validation_failed, validation_count) + 4;
    }
    if (resume_offer_visible) {
        history_prefix += agent_panel_mod.resumeBannerHeight(agent_w, resume_intent, resume_state) + 4;
    }

    const scroll_y = wb.chat_scroll_y;
    const base_y = chat_top - scroll_y + history_prefix;
    const start_i = firstVisibleIndex(cache, scroll_y, history_prefix);
    const end_i = lastVisibleIndex(cache, scroll_y, history_prefix, cache.viewport_h);

    for (wb.agent_ui.chat_history.items[start_i..end_i], start_i..) |msg, i| {
        if (msg.role != .agent) continue;
        if (i >= cache.message_heights.items.len) break;
        const msg_h = cache.message_heights.items[i];
        if (msg_h <= 0) continue;
        const msg_y = base_y + historyYOffset(cache, i);

        if (chat_bubble_mod.hitTestAgentCopy(inner_x, content_w, msg_y, event_x, event_y)) {
            return i;
        }
    }
    return null;
}

fn layoutChrome(wb: anytype, agent_h: f32) struct {
    bottom: f32,
    viewport: f32,
} {
    const chrome = agentChrome(wb);
    _ = chrome.expanded;
    _ = chrome.entry_count;
    _ = chrome.has_detail;
    _ = chrome.has_routing;
    const bottom = agent_panel_mod.bottomReserved(chrome.attachment_count, wb.agent_panel_width, &wb.agent_ui.prompt_buffer);
    const composer_top = @import("../ui/agent/agent_composer.zig").composerTop(agent_h, chrome.attachment_count, wb.agent_panel_width, &wb.agent_ui.prompt_buffer);
    const chat_top = agent_panel_mod.chat_content_top + 8.0;
    const viewport = @max(0, composer_top - chat_composer_gap - chat_top);
    return .{ .bottom = bottom, .viewport = viewport };
}

pub fn ensure(wb: anytype, agent_h: f32) void {
    const content_w = @max(40, wb.agent_panel_width - 40);
    const cache = &wb.chat_layout;

    const history_dirty = cache.content_w != content_w or cache.built_revision != wb.chat_history_revision;
    wb.agent_ui.session.lock();
    const stream_len = wb.agent_ui.session.stream_text.items.len;
    const thinking_len = wb.agent_ui.session.thinking_text.items.len;
    const steps_len = wb.agent_ui.session.agent_steps.items.len;
    const worker_running = wb.agent_ui.session.worker_running or phaseShowsLive(wb.agent_ui.session.phase);
    wb.agent_ui.session.unlock();

    if (!history_dirty and
        cache.agent_h == agent_h and
        cache.worker_running == worker_running and
        cache.steps_len == steps_len and
        cache.stream_len == stream_len and
        cache.thinking_len == thinking_len and
        cache.bottom_reserved == layoutChrome(wb, agent_h).bottom)
    {
        return;
    }

    const chrome = layoutChrome(wb, agent_h);

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
        cache.content_h = cache.history_content_h + live_h + chat_bottom_padding;
        cache.stream_len = stream_len;
        cache.thinking_len = thinking_len;
        cache.steps_len = steps_len;
        cache.worker_running = worker_running;

        if (stream_len != cache.stream_built_len) {
            cache.stream_entry.deinit(wb.allocator);
            wb.agent_ui.session.lock();
            const stream_text = wb.agent_ui.session.stream_text.items;
            wb.agent_ui.session.unlock();
            cache.stream_entry = chat_message_lines_mod.build(wb.allocator, stream_text, chat_bubble_mod.agentTextWidth(content_w)) catch .{};
            cache.stream_built_len = stream_len;
        }
    }

    cache.agent_h = agent_h;
    cache.bottom_reserved = chrome.bottom;
    cache.viewport_h = chrome.viewport;
    cache.max_scroll = @max(0, cache.content_h - chrome.viewport);
    cache.chrome_prompt_lines = wb.agent_ui.prompt_buffer.lineCount();
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

pub fn hitTestChatSelection(wb: anytype, agent_x: f32, agent_w: f32, event_x: f32, event_y: f32) ?struct { msg_hash: u64, char_idx: usize } {
    const pad: f32 = 20;
    const inner_x = agent_x + pad;
    const content_w = agent_w - pad * 2;

    if (event_x < inner_x or event_x > inner_x + content_w) return null;

    const cache = &wb.chat_layout;
    const chat_top = agent_panel_mod.chat_content_top + 8.0;

    wb.agent_ui.session.lock();
    const post_apply_visible = wb.agent_ui.session.post_apply_visible;
    const validation_failed = wb.agent_ui.session.phase == .failed;
    const validation_count = wb.agent_ui.session.validation_results.items.len;
    const resume_offer_visible = wb.agent_ui.session.resume_offer_visible;
    var resume_intent: []const u8 = "previous run";
    var resume_state: []const u8 = "interrupted";
    if (wb.agent_ui.session.resume_intent) |i| resume_intent = i;
    if (wb.agent_ui.session.resume_state) |s| resume_state = s;
    wb.agent_ui.session.unlock();

    var history_prefix: f32 = 0;
    if (post_apply_visible) {
        history_prefix += agent_panel_mod.applyBannerHeight(validation_failed, validation_count) + 4;
    }
    if (resume_offer_visible) {
        history_prefix += agent_panel_mod.resumeBannerHeight(agent_w, resume_intent, resume_state) + 4;
    }

    const scroll_y = wb.chat_scroll_y;
    const base_y = chat_top - scroll_y + history_prefix;
    const start_i = firstVisibleIndex(cache, scroll_y, history_prefix);
    const end_i = lastVisibleIndex(cache, scroll_y, history_prefix, cache.viewport_h);

    for (wb.agent_ui.chat_history.items[start_i..end_i], start_i..) |msg, i| {
        if (msg.role == .tool or msg.content.len == 0) continue;
        if (i >= cache.message_heights.items.len) break;
        const msg_h = cache.message_heights.items[i];
        if (msg_h <= 0) continue;
        const msg_y = base_y + historyYOffset(cache, i);

        if (event_y >= msg_y and event_y <= msg_y + msg_h) {
            if (msg.role == .agent) {
                if (chat_bubble_mod.hitTestMessageContent(wb.allocator, msg.content, inner_x, content_w, msg_y, event_x, event_y)) |idx| {
                    return .{ .msg_hash = @as(u64, i), .char_idx = idx };
                }
            } else if (msg.role == .user) {
                // Approximate hit testing for user message
                const text_x = inner_x + chat_bubble_mod.bubble_pad_x;
                const text_w = chat_bubble_mod.textMaxWidth(content_w);
                if (event_y >= msg_y + chat_bubble_mod.bubble_pad_y) {
                    if (chat_bubble_mod.hitTestMessageContent(wb.allocator, msg.content, text_x - 28, text_w, msg_y + chat_bubble_mod.bubble_pad_y, event_x, event_y)) |idx| {
                        return .{ .msg_hash = @as(u64, i), .char_idx = idx };
                    }
                }
            }
        }
    }
    return null;
}

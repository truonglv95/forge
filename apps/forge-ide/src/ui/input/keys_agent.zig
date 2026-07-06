const std = @import("std");
const renderer = @import("forge-renderer");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn handleScopePickerKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    const scope_picker_mod = @import("../../agent/scope_picker.zig");
    if (event.keycode == 53) {
        wb.dispatch(.agent_scope_picker_close) catch {};
        return;
    }
    if (event.keycode == 36) {
        wb.dispatch(.agent_scope_picker_select) catch {};
        return;
    }
    if (event.keycode == 125) {
        wb.agent.lock();
        const query = wb.agent.scope_query[0..wb.agent.scope_query_len];
        const total = scope_picker_mod.visibleRowCount(wb.scope_picker_filtered.items.len, query);
        if (total > 0) {
            wb.agent.scope_picker_selected +%= 1;
            if (wb.agent.scope_picker_selected >= total) {
                wb.agent.scope_picker_selected = total - 1;
            }
        }
        wb.agent.unlock();
        return;
    }
    if (event.keycode == 126) {
        wb.agent.lock();
        if (wb.agent.scope_picker_selected > 0) wb.agent.scope_picker_selected -= 1;
        wb.agent.unlock();
        return;
    }
    if (event.keycode == 51) {
        wb.agent.lock();
        if (wb.agent.scope_query_len > 0) wb.agent.scope_query_len -= 1;
        wb.agent.unlock();
        wb.applyScopePickerFilter() catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.agent.lock();
        if (wb.agent.scope_query_len < wb.agent.scope_query.len) {
            wb.agent.scope_query[wb.agent.scope_query_len] = event.chars[0];
            wb.agent.scope_query_len += 1;
        }
        wb.agent.unlock();
        wb.applyScopePickerFilter() catch {};
    }
}

pub fn submitAgentPrompt(wb: *Workbench) void {
    if (wb.agent.worker_running) {
        wb.setStatus("Agent is already running") catch {};
        return;
    }

    const prompt_text = wb.prompt_buffer.content() catch return;
    defer wb.prompt_buffer.allocator.free(prompt_text);
    const trimmed = std.mem.trim(u8, prompt_text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    wb.focused_panel = .agent;
    wb.dispatch(.agent_submit) catch {};
}

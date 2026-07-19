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
        wb.agent_ui.session.lock();
        const query = wb.agent_ui.session.scope_query[0..wb.agent_ui.session.scope_query_len];
        const total = scope_picker_mod.visibleRowCount(wb.scope_picker_filtered.items.len, query);
        if (total > 0) {
            wb.agent_ui.session.scope_picker_selected +%= 1;
            if (wb.agent_ui.session.scope_picker_selected >= total) {
                wb.agent_ui.session.scope_picker_selected = total - 1;
            }
        }
        wb.agent_ui.session.unlock();
        return;
    }
    if (event.keycode == 126) {
        wb.agent_ui.session.lock();
        if (wb.agent_ui.session.scope_picker_selected > 0) wb.agent_ui.session.scope_picker_selected -= 1;
        wb.agent_ui.session.unlock();
        return;
    }
    if (event.keycode == 51) {
        wb.agent_ui.session.lock();
        if (wb.agent_ui.session.scope_query_len > 0) wb.agent_ui.session.scope_query_len -= 1;
        wb.agent_ui.session.unlock();
        @import("../../workbench/agent_ops.zig").applyScopePickerFilter(wb) catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.agent_ui.session.lock();
        if (wb.agent_ui.session.scope_query_len < wb.agent_ui.session.scope_query.len) {
            wb.agent_ui.session.scope_query[wb.agent_ui.session.scope_query_len] = event.chars[0];
            wb.agent_ui.session.scope_query_len += 1;
        }
        wb.agent_ui.session.unlock();
        @import("../../workbench/agent_ops.zig").applyScopePickerFilter(wb) catch {};
    }
}

pub fn submitAgentPrompt(wb: *Workbench) void {
    if (wb.agent_ui.session.worker_running) {
        wb.setStatus("Agent is already running") catch {};
        return;
    }

    const prompt_text = wb.agent_ui.prompt_buffer.content() catch return;
    defer wb.agent_ui.prompt_buffer.allocator.free(prompt_text);
    const trimmed = std.mem.trim(u8, prompt_text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    wb.focused_panel = .agent;
    wb.dispatch(.agent_submit) catch {};
}

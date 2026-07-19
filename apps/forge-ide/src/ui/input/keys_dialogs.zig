const renderer = @import("forge-renderer");
const Workbench = @import("../../workbench.zig").Workbench;

pub fn handleConflictKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 36) {
        wb.dispatch(.reload_active_from_disk) catch {};
        return;
    }
    if (event.keycode == 53) {
        wb.dispatch(.dismiss_external_conflict) catch {};
    }
}

pub fn handleRecoveryKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 36) {
        wb.dispatch(.restore_recovery_snapshots) catch {};
        return;
    }
    if (event.keycode == 53) {
        wb.dispatch(.discard_recovery_snapshots) catch {};
    }
}

pub fn handlePaletteKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.dispatch(.palette_close) catch {};
        return;
    }
    if (event.keycode == 36) {
        wb.executePaletteSelection() catch {};
        return;
    }
    if (event.keycode == 125) {
        wb.palette.moveSelection(1);
        return;
    }
    if (event.keycode == 126) {
        wb.palette.moveSelection(-1);
        return;
    }
    if (event.keycode == 51) {
        wb.palette.backspace() catch {};
        return;
    }
    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.palette.insertChar(event.chars) catch {};
    }
}

pub fn handleWorkspaceSymbolPickerKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.dispatch(.workspace_symbol_picker_close) catch {};
        return;
    }

    if (event.keycode == 36) {
        wb.dispatch(.workspace_symbol_picker_select) catch {};
        return;
    }

    if (event.keycode == 125) {
        wb.workspace_symbol_picker.moveSelection(1);
        return;
    }

    if (event.keycode == 126) {
        wb.workspace_symbol_picker.moveSelection(-1);
        return;
    }

    if (event.keycode == 51) {
        wb.workspace_symbol_picker.backspace() catch {};
        return;
    }

    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.workspace_symbol_picker.insertChar(event.chars) catch {};
        return;
    }
}

pub fn handleGitBranchPickerKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.git_branch_picker.close();
        wb.focused_panel = wb.previous_focus;
        return;
    }

    if (event.keycode == 36) {
        if (wb.git_branch_picker.filtered.items.len > 0) {
            const selected_idx = wb.git_branch_picker.filtered.items[wb.git_branch_picker.selected];
            const branch_name = wb.git_branch_picker.entries.items[selected_idx].name;
            @import("../../workbench/git_ops.zig").gitCheckout(wb, branch_name) catch {};
        }
        wb.git_branch_picker.close();
        wb.focused_panel = wb.previous_focus;
        return;
    }

    if (event.keycode == 125) {
        wb.git_branch_picker.moveSelection(1);
        return;
    }

    if (event.keycode == 126) {
        wb.git_branch_picker.moveSelection(-1);
        return;
    }

    if (event.keycode == 51) {
        wb.git_branch_picker.backspace() catch {};
        return;
    }

    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.git_branch_picker.insertChar(event.chars) catch {};
        return;
    }
}

pub fn handleOutputChannelPickerKeys(wb: *Workbench, event: renderer.KeyEvent) void {
    if (event.keycode == 53) {
        wb.output_channel_picker.close();
        if (wb.previous_focus == .output_channels) {
            wb.focused_panel = .editor;
        } else {
            wb.focused_panel = wb.previous_focus;
        }
        return;
    }

    if (event.keycode == 36) {
        if (wb.output_channel_picker.filtered.items.len > 0) {
            const selected_idx = wb.output_channel_picker.filtered.items[wb.output_channel_picker.selected];
            const channel_id = wb.output_channel_picker.entries.items[selected_idx].id;

            // Switch to this channel
            if (wb.getOutputChannel(channel_id) != null) {
                // Free previous if it was dupe, but we shouldn't free the old one here,
                // wait, active_output_channel_id is NOT owned. It points to string literal or we should make it point to the channel's id.
                wb.active_output_channel_id = wb.getOutputChannel(channel_id).?.id;
                wb.task_scroll_y = 0;
            }
        }
        wb.output_channel_picker.close();
        wb.focused_panel = .editor; // After selecting output, focus back to editor or output?
        return;
    }

    if (event.keycode == 125) {
        wb.output_channel_picker.moveSelection(1);
        return;
    }

    if (event.keycode == 126) {
        wb.output_channel_picker.moveSelection(-1);
        return;
    }

    if (event.keycode == 51) {
        wb.output_channel_picker.backspace() catch {};
        return;
    }

    if (event.chars.len > 0 and event.chars[0] >= 32) {
        wb.output_channel_picker.insertChar(event.chars) catch {};
        return;
    }
}

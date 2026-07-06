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

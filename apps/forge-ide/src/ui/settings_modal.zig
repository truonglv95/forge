const std = @import("std");
const renderer = @import("forge-renderer");
const workspace = @import("forge-workspace");
const layout = @import("core/layout.zig");
const state = @import("core/state.zig");
const theme_loader = @import("../theme_loader.zig");
const Workbench = @import("../workbench.zig").Workbench;

fn color(rgba: workspace.Rgba) renderer.Color {
    return theme_loader.toColor(rgba);
}

pub const Tab = enum {
    general,
    account,
    permissions,
    appearance,
    models,
    customizations,
    browser,
    app,
    project_forge,
};

pub const Hit = union(enum) {
    close_modal,
    switch_tab: Tab,
    none,
};

pub fn draw(wb: *Workbench, window_w: f32, window_h: f32) void {
    if (!wb.settings_modal_open) return;

    const theme = &wb.theme;

    // Draw Backdrop
    renderer.Renderer.drawRect(0, 0, window_w, window_h, .{ .r = 0, .g = 0, .b = 0, .a = 0.6 });

    // Draw Modal Container
    const modal_w: f32 = 860;
    const modal_h: f32 = 620;
    const modal_x: f32 = (window_w - modal_w) / 2.0;
    const modal_y: f32 = (window_h - modal_h) / 2.0;

    const bg_color = color(theme.colors.editor_bg);
    const border_color = color(theme.colors.border);
    const text_primary = color(theme.colors.text_primary);
    const text_muted = color(theme.colors.text_muted);

    renderer.Renderer.drawRoundedRect(modal_x - 1, modal_y - 1, modal_w + 2, modal_h + 2, 12, border_color);
    renderer.Renderer.drawRoundedRect(modal_x, modal_y, modal_w, modal_h, 12, bg_color);

    // Layout
    const sidebar_w: f32 = 220;
    const content_x: f32 = modal_x + sidebar_w;
    const content_w: f32 = modal_w - sidebar_w;

    // Sidebar line
    renderer.Renderer.drawRect(content_x, modal_y, 1, modal_h, border_color);

    // Sidebar Tab Menu
    var sy: f32 = modal_y + 20;
    const tab_h: f32 = 32;

    const tabs = [_]struct { label: []const u8, id: Tab }{
        .{ .label = "General", .id = .general },
        .{ .label = "Account", .id = .account },
        .{ .label = "Permissions", .id = .permissions },
        .{ .label = "Appearance", .id = .appearance },
        .{ .label = "Models", .id = .models },
        .{ .label = "Customizations", .id = .customizations },
        .{ .label = "Browser", .id = .browser },
        .{ .label = "App", .id = .app },
    };

    for (tabs) |tab| {
        const is_active = wb.settings_modal_tab == tab.id;
        if (is_active) {
            renderer.Renderer.drawRoundedRect(modal_x + 12, sy, sidebar_w - 24, tab_h, 6, color(theme.colors.tab_active_bg));
            renderer.Renderer.drawText(tab.label, modal_x + 24, sy + 10, 13.0, text_primary);
        } else {
            renderer.Renderer.drawText(tab.label, modal_x + 24, sy + 10, 13.0, text_muted);
        }
        sy += tab_h;
    }

    sy += 20;
    renderer.Renderer.drawText("Projects", modal_x + 16, sy, 11.0, text_muted);
    sy += 24;

    const project_tabs = [_]struct { label: []const u8, id: Tab }{
        .{ .label = wb.workspace_name, .id = .project_forge },
    };

    for (project_tabs) |tab| {
        const is_active = wb.settings_modal_tab == tab.id;
        if (is_active) {
            renderer.Renderer.drawRoundedRect(modal_x + 12, sy, sidebar_w - 24, tab_h, 6, color(theme.colors.tab_active_bg));
            renderer.Renderer.drawText(tab.label, modal_x + 24, sy + 10, 13.0, text_primary);
        } else {
            renderer.Renderer.drawText(tab.label, modal_x + 24, sy + 10, 13.0, text_muted);
        }
        sy += tab_h;
    }

    // Content Area
    var cy: f32 = modal_y + 32;
    renderer.Renderer.setClipRect(content_x + 1, modal_y, content_w - 1, modal_h);

    if (wb.settings_modal_tab == .project_forge) {
        // Draw Project Header
        renderer.Renderer.drawText(wb.workspace_name, content_x + 32, cy, 20.0, text_primary);
        cy += 28;
        renderer.Renderer.drawText("Manage project folders, agent settings, and permissions.", content_x + 32, cy, 13.0, text_muted);
        cy += 40;

        // Draw "Agent Settings"
        renderer.Renderer.drawText("Agent Settings", content_x + 32, cy, 14.0, text_primary);
        cy += 24;

        // Settings Card
        const card_h: f32 = 80;
        renderer.Renderer.drawRoundedRect(content_x + 32, cy, content_w - 64, card_h, 8, color(theme.colors.selection));
        renderer.Renderer.drawText("Security Preset", content_x + 48, cy + 16, 14.0, text_primary);
        renderer.Renderer.drawText("Choose a predefined security preset for the agent.", content_x + 48, cy + 38, 12.0, text_muted);

        // Placeholder Dropdown
        const drop_w: f32 = 120;
        renderer.Renderer.drawRoundedRect(content_x + 32 + content_w - 64 - drop_w - 16, cy + 16, drop_w, 32, 6, color(theme.colors.editor_bg));
        renderer.Renderer.drawText("Default", content_x + 32 + content_w - 64 - drop_w - 16 + 12, cy + 26, 13.0, text_primary);

        cy += card_h + 32;
    } else {
        renderer.Renderer.drawText("Settings not implemented yet.", content_x + 32, cy, 14.0, text_muted);
    }

    renderer.Renderer.clearClipRect();

    // Close button
    const close_btn_x = modal_x + modal_w - 40;
    const close_btn_y = modal_y + 16;
    renderer.Renderer.drawText("×", close_btn_x + 12, close_btn_y + 8, 20.0, text_muted);
}

pub fn hitTestPoint(wb: *Workbench, window_w: f32, window_h: f32, px: f32, py: f32) Hit {
    if (!wb.settings_modal_open) return .none;

    const modal_w: f32 = 860;
    const modal_h: f32 = 620;
    const modal_x: f32 = (window_w - modal_w) / 2.0;
    const modal_y: f32 = (window_h - modal_h) / 2.0;

    // Check if click is outside modal
    if (px < modal_x or px > modal_x + modal_w or py < modal_y or py > modal_y + modal_h) {
        return .close_modal;
    }

    // Check Close Button
    const close_btn_x = modal_x + modal_w - 40;
    const close_btn_y = modal_y + 16;
    if (px >= close_btn_x and px <= close_btn_x + 32 and py >= close_btn_y and py <= close_btn_y + 32) {
        return .close_modal;
    }

    // Check Sidebar Tabs
    const sidebar_w: f32 = 220;
    if (px >= modal_x and px < modal_x + sidebar_w) {
        var sy: f32 = modal_y + 20;
        const tab_h: f32 = 32;

        const tabs = [_]struct { id: Tab }{
            .{ .id = .general },
            .{ .id = .account },
            .{ .id = .permissions },
            .{ .id = .appearance },
            .{ .id = .models },
            .{ .id = .customizations },
            .{ .id = .browser },
            .{ .id = .app },
        };

        for (tabs) |tab| {
            if (py >= sy and py < sy + tab_h) return .{ .switch_tab = tab.id };
            sy += tab_h;
        }

        sy += 20 + 24; // Projects header space
        const project_tabs = [_]struct { id: Tab }{
            .{ .id = .project_forge },
        };

        for (project_tabs) |tab| {
            if (py >= sy and py < sy + tab_h) return .{ .switch_tab = tab.id };
            sy += tab_h;
        }
    }

    // Returning none because the click was inside the modal but not on anything interactive yet.
    // It prevents the click from falling through to the background.
    return .none;
}

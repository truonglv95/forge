const std = @import("std");
const core = @import("forge-core");
const renderer = @import("forge-renderer");
const mcp_capability = @import("forge-ai").mcp_capability;
const Workbench = @import("../../../workbench.zig").Workbench;

pub fn drawAiPanel(wb: *Workbench, start_x: f32, w: f32, h: f32) void {
    _ = h;
    const layout = @import("../../core/layout.zig");
    const theme = wb.theme;

    // Draw header
    renderer.Renderer.drawText("AI & MCP Settings", start_x + 16, layout.header_height + 16, 14, .{ .r = theme.colors.text_primary.r, .g = theme.colors.text_primary.g, .b = theme.colors.text_primary.b, .a = theme.colors.text_primary.a });
    renderer.Renderer.drawRect(start_x, layout.header_height + 40, w, 1, .{ .r = theme.colors.border.r, .g = theme.colors.border.g, .b = theme.colors.border.b, .a = theme.colors.border.a });

    var cy: f32 = layout.header_height + 56;

    if (wb.ai_mcp_registry) |reg| {
        renderer.Renderer.drawText("MCP Audit Log", start_x + 16, cy, 13, .{ .r = theme.colors.text_primary.r, .g = theme.colors.text_primary.g, .b = theme.colors.text_primary.b, .a = theme.colors.text_primary.a });
        cy += 20;

        for (reg.tools) |tool| {
            const policy = mcp_capability.inferPolicy(tool.annotations_json);

            // Tool name
            const label = std.fmt.allocPrint(wb.allocator, "• {s}/{s}", .{ tool.server_name, tool.tool_name }) catch continue;
            defer wb.allocator.free(label);
            renderer.Renderer.drawText(label, start_x + 24, cy, 12, .{ .r = theme.colors.text_primary.r, .g = theme.colors.text_primary.g, .b = theme.colors.text_primary.b, .a = theme.colors.text_primary.a });
            cy += 16;

            // Capability / Risk
            const risk_str = switch (policy.risk) {
                .low => "Low Risk",
                .medium => "Medium Risk",
                .high => "High Risk",
            };
            const cap_str = switch (policy.capability) {
                .read_only => "Read-only",
                .mutate => "Mutate",
                .unknown => "Unknown",
            };
            const audit_info = std.fmt.allocPrint(wb.allocator, "  Capability: {s} | {s}", .{ cap_str, risk_str }) catch continue;
            defer wb.allocator.free(audit_info);

            const base_color = if (policy.risk == .high) theme.colors.diff_remove else if (policy.risk == .low) theme.colors.diff_add else theme.colors.text_muted;
            const color = @import("../../../theme_loader.zig").toColor(base_color);

            renderer.Renderer.drawText(audit_info, start_x + 24, cy, 11, color);
            cy += 24;
        }
    } else {
        renderer.Renderer.drawText("MCP Registry not loaded.", start_x + 16, cy, 12, .{ .r = theme.colors.text_primary.r, .g = theme.colors.text_primary.g, .b = theme.colors.text_primary.b, .a = 0.5 });
    }
}

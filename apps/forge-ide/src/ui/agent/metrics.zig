const std = @import("std");
const renderer = @import("forge-renderer");
const scrollbar = @import("../core/scrollbar.zig");
const tokens = @import("../tokens.zig");

pub const chat = struct {
    pub const outer_pad: f32 = tokens.space.xxl;
    pub const min_content_w: f32 = 40.0;
    pub const composer_gap: f32 = 24.0;
    pub const bottom_padding: f32 = 56.0;
    pub const thinking_bottom_padding: f32 = 28.0;
    pub const bottom_anchor_threshold: f32 = 96.0;
    pub const hit_pad: f32 = 20.0;
};

pub const panel = struct {
    pub const chat_content_top: f32 = 68.0;
    pub const chat_top_gap: f32 = 8.0;
    pub const banner_surface_inset: f32 = chat.outer_pad / 2.0;
    pub const apply_banner_h: f32 = 34.0;
    pub const apply_banner_validation_line_h: f32 = 14.0;
    pub const apply_banner_validation_pad: f32 = 8.0;
    pub const resume_detail_line_h: f32 = 14.0;
    pub const review_action_offset: f32 = 36.0;
    pub const approval_action_offset: f32 = 36.0;
    pub const approval_overlay_offset: f32 = 112.0;
    pub const approval_overlay_h: f32 = 72.0;
};

pub const typography = struct {
    pub const prose_style = renderer.TextStyle.prose;
    pub const strong_style = renderer.TextStyle.prose_semibold;
    pub const code_style = renderer.TextStyle.mono;
};

pub const markdown = struct {
    pub const default_body_font_size: f32 = 15.5;
    pub var body_font_size: f32 = default_body_font_size;
    pub var body_line_h: f32 = 26.0;
    pub var code_font_size: f32 = 13.0;
    pub var code_line_h: f32 = 22.0;
    pub var code_pad: f32 = tokens.space.md + 2.0;
    pub var code_gap: f32 = tokens.space.md;
    pub var heading_font_size: f32 = 17.0;
    pub var heading_line_h: f32 = 28.0;
    pub var list_indent: f32 = 20.0;
    pub var quote_indent: f32 = 14.0;
    pub var paragraph_gap: f32 = 13.0;
    pub var list_item_gap: f32 = 7.0;
    pub var quote_pad_x: f32 = 10.0;
    pub var quote_pad_y: f32 = 8.0;
    pub var inline_code_pad_x: f32 = 3.5;
    pub var inline_code_gap: f32 = 4.0;
    pub var block_gap: f32 = 10.0;
    pub var heading_gap_top: f32 = 15.0;
    pub var heading_gap_bottom: f32 = 10.0;
    pub var runtime_safety_pad: f32 = 72.0;
};

pub const bubble = struct {
    pub const pad_x: f32 = tokens.space.lg;
    pub const pad_y: f32 = 12.0;
    pub const title_h: f32 = 16.0;
    pub const gap: f32 = 18.0;
    pub const agent_icon_size: f32 = 20.0;
    pub const agent_header_h: f32 = agent_icon_size + tokens.space.sm;
};

pub const composer = struct {
    pub const prompt_font_size: f32 = 13.5;
    pub const prompt_line_h: f32 = tokens.font.body_line;
    pub const scroll_bar_w: f32 = scrollbar.track_w;
    pub const pad: f32 = tokens.space.lg;
    pub const input_min_h: f32 = 72.0;
    pub const input_max_h: f32 = 220.0;
    pub const toolbar_gap: f32 = 10.0;
    pub const toolbar_h: f32 = 24.0;
    pub const chrome_h: f32 = toolbar_h + toolbar_gap;
    pub const base_h: f32 = chrome_h + input_min_h;
    pub const max_h: f32 = chrome_h + input_max_h;
    pub const attachment_row_h: f32 = 26.0;
    pub const chip_h: f32 = 18.0;
    pub const chip_remove_w: f32 = 16.0;
    pub const input_pad: f32 = tokens.space.lg;
};

pub const context = struct {
    pub const inset: f32 = chat.outer_pad / 2.0;
    pub const inner_pad: f32 = chat.outer_pad;
    pub const strip_gap: f32 = 6.0;
    pub const chat_gap: f32 = 18.0;
    pub const header_h: f32 = 22.0;
    pub const row_h: f32 = 15.0;
    pub const max_visible_rows: usize = 5;
    pub const detail_h: f32 = 36.0;
    pub const pill_h: f32 = 18.0;
    pub const routing_row_h: f32 = 14.0;
};

pub const tool_step = struct {
    pub const card_h: f32 = 28.0;
    pub const card_gap: f32 = tokens.space.xs;
    pub const child_h: f32 = 20.0;
    pub const child_indent: f32 = 28.0;
    pub const expanded_content_pad: f32 = tokens.space.md;
    pub const history_tool_gap: f32 = 8.0;
};

pub fn configureAiPanelFontSize(raw_size: f32) void {
    const size = std.math.clamp(raw_size, 12.0, 20.0);
    markdown.body_font_size = size;
    markdown.body_line_h = @round(size * 1.68);
    markdown.code_font_size = @max(11.5, size - 2.0);
    markdown.code_line_h = @round(markdown.code_font_size * 1.62);
    markdown.heading_font_size = size + 1.5;
    markdown.heading_line_h = @round(markdown.heading_font_size * 1.62);
    markdown.paragraph_gap = @round(size * 0.82);
    markdown.list_item_gap = @round(size * 0.46);
    markdown.heading_gap_top = @round(size * 1.15);
    markdown.heading_gap_bottom = @round(size * 0.72);
    markdown.runtime_safety_pad = markdown.body_line_h * 3.0;
}

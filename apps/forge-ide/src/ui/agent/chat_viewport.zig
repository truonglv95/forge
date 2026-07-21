const std = @import("std");
const editor = @import("forge-editor");
const layout = @import("../core/layout.zig");
const agent_composer = @import("agent_composer.zig");
const context_inspector = @import("context_inspector.zig");
const agent_panel = @import("agent_panel.zig");
const metrics = @import("metrics.zig");

pub const Input = struct {
    agent_x: f32 = 0,
    agent_w: f32,
    window_h: f32,
    attachment_count: usize = 0,
    context_entry_count: usize = 0,
    context_used_bytes: usize = 0,
    context_expanded: bool = true,
    context_has_detail: bool = false,
    scope_count: usize = 0,
    has_routing: bool = false,
    prompt: *const editor.Buffer,
};

pub const Layout = struct {
    composer: agent_composer.Layout,
    chat_top: f32,
    chat_bottom: f32,
    chat_viewport_h: f32,
    context_visible: bool,
    context_top: f32,
    context_h: f32,
    bottom_reserved: f32,

    pub fn assertValid(self: Layout) void {
        std.debug.assert(self.chat_top >= 0);
        std.debug.assert(self.chat_bottom >= self.chat_top);
        std.debug.assert(self.chat_viewport_h >= 0);
        std.debug.assert(self.composer.composer_top >= self.chat_bottom + metrics.chat.hit_pad or self.chat_viewport_h == 0);
    }
};

pub fn compute(input: Input) Layout {
    const composer = agent_composer.computeLayout(
        input.agent_x,
        input.agent_w,
        input.window_h,
        input.attachment_count,
        input.prompt,
    );
    const chat_top = metrics.panel.chat_content_top + metrics.panel.chat_top_gap;
    const context_visible = context_inspector.isVisible(
        input.context_entry_count,
        input.context_used_bytes,
        input.scope_count > 0,
        input.has_routing,
    );
    const context_top = context_inspector.stripTop(
        input.window_h,
        input.context_expanded,
        input.context_entry_count,
        input.attachment_count,
        input.agent_w,
        input.prompt,
        input.context_has_detail,
        input.has_routing,
    );
    const context_h = if (context_visible)
        context_inspector.stripHeight(input.context_expanded, input.context_entry_count, input.context_has_detail, input.has_routing)
    else
        0;
    const chat_bottom = if (context_visible)
        @min(composer.composer_top - metrics.chat.composer_gap, context_top - context_inspector.chat_gap)
    else
        composer.composer_top - metrics.chat.composer_gap;
    const chat_viewport_h = @max(0, chat_bottom - chat_top);
    var bottom_reserved = bottomReserved(input.attachment_count, input.agent_w, input.prompt);
    if (context_visible) bottom_reserved += context_h + context_inspector.chat_gap;
    const result = Layout{
        .composer = composer,
        .chat_top = chat_top,
        .chat_bottom = chat_bottom,
        .chat_viewport_h = chat_viewport_h,
        .context_visible = context_visible,
        .context_top = context_top,
        .context_h = context_h,
        .bottom_reserved = bottom_reserved,
    };
    return result;
}

fn bottomReserved(attachment_count: usize, agent_w: f32, prompt: *const editor.Buffer) f32 {
    _ = layout.status_height;
    return agent_panel.bottomReserved(attachment_count, agent_w, prompt);
}

test "chat viewport keeps composer clear when resized" {
    var prompt = try editor.Buffer.init(std.testing.allocator);
    defer prompt.deinit();
    try prompt.insertString("hello");

    const widths = [_]f32{ 300, 420, 760 };
    for (widths) |w| {
        const out = compute(.{
            .agent_w = w,
            .window_h = 720,
            .prompt = &prompt,
        });
        try std.testing.expect(out.chat_viewport_h > 0);
        try std.testing.expect(out.chat_bottom <= out.composer.composer_top - metrics.chat.composer_gap);
        try std.testing.expect(out.composer.composer_top + out.composer.composer_h + agent_composer.composer_pad <= 720 - layout.status_height + out.composer.composer_h);
    }
}

test "chat viewport reserves context strip before composer" {
    var prompt = try editor.Buffer.init(std.testing.allocator);
    defer prompt.deinit();
    try prompt.insertString("prompt");

    const plain = compute(.{ .agent_w = 420, .window_h = 720, .prompt = &prompt });
    const with_context = compute(.{
        .agent_w = 420,
        .window_h = 720,
        .prompt = &prompt,
        .context_entry_count = 6,
        .context_used_bytes = 1200,
        .context_expanded = true,
    });
    try std.testing.expect(with_context.context_visible);
    try std.testing.expect(with_context.chat_bottom <= plain.chat_bottom);
    try std.testing.expect(with_context.bottom_reserved > plain.bottom_reserved);
}

test "chat viewport survives tall prompt without negative viewport" {
    var prompt = try editor.Buffer.init(std.testing.allocator);
    defer prompt.deinit();
    try prompt.insertString("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen");

    const out = compute(.{
        .agent_w = 260,
        .window_h = 420,
        .prompt = &prompt,
        .attachment_count = 1,
        .context_entry_count = 12,
        .context_used_bytes = 4096,
        .context_expanded = true,
        .context_has_detail = true,
        .scope_count = 3,
        .has_routing = true,
    });
    try std.testing.expect(out.chat_viewport_h >= 0);
    try std.testing.expect(out.chat_bottom >= out.chat_top or out.chat_viewport_h == 0);
}

test "chat viewport visual regression matrix keeps input overlay clear" {
    var prompt = try editor.Buffer.init(std.testing.allocator);
    defer prompt.deinit();
    try prompt.insertString(
        "review the latest Forge AI workflow, explain bottlenecks, then propose changes with enough detail that the input grows and wraps across several visual lines",
    );

    const widths = [_]f32{ 260, 320, 480, 760, 1180 };
    const heights = [_]f32{ 420, 580, 760, 980 };
    for (widths) |w| {
        for (heights) |window_h| {
            const out = compute(.{
                .agent_w = w,
                .window_h = window_h,
                .attachment_count = 2,
                .context_entry_count = 18,
                .context_used_bytes = 7 * 1024 * 1024,
                .context_expanded = true,
                .context_has_detail = true,
                .scope_count = 4,
                .has_routing = true,
                .prompt = &prompt,
            });
            out.assertValid();
            try std.testing.expect(out.composer.box_w >= metrics.chat.min_content_w);
            try std.testing.expect(out.composer.composer_top >= layout.header_height);
            try std.testing.expect(out.composer.composer_top >= out.chat_bottom + metrics.chat.hit_pad or out.chat_viewport_h == 0);
            try std.testing.expect(out.context_top + out.context_h <= out.composer.composer_top - context_inspector.strip_gap + 1);
            try std.testing.expect(out.composer.composer_top + out.composer.composer_h <= window_h - layout.status_height);
        }
    }
}

test "chat viewport bottom scroll reservation covers composer and thinking rows" {
    var prompt = try editor.Buffer.init(std.testing.allocator);
    defer prompt.deinit();
    try prompt.insertString("short prompt");

    const out = compute(.{
        .agent_w = 360,
        .window_h = 620,
        .context_entry_count = 3,
        .context_used_bytes = 2048,
        .context_expanded = false,
        .has_routing = true,
        .prompt = &prompt,
    });
    try std.testing.expect(out.bottom_reserved >= out.composer.composer_h + metrics.chat.bottom_padding);
    try std.testing.expect(out.chat_bottom + metrics.chat.composer_gap <= out.composer.composer_top);
}

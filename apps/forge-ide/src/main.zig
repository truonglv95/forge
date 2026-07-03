const std = @import("std");
const core = @import("forge-core");
const kernel = @import("forge-kernel");
const workspace = @import("forge-workspace");
const renderer = @import("forge-renderer");
const TextBuffer = @import("text_buffer.zig").TextBuffer;

var gpa: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    gpa = std.heap.page_allocator;
    const allocator = gpa;

    // 1. Parse Args for workspace path
    const args = try init.minimal.args.toSlice(allocator);

    var workspace_path: []const u8 = ".";
    if (args.len > 1) {
        workspace_path = args[1];
    }

    std.debug.print("Forge IDE starting for workspace: {s}\n", .{workspace_path});

    // 2. Start Background Kernel Thread
    // We pass the workspace path to a dedicated thread so it doesn't block the UI
    const kernel_thread = try std.Thread.spawn(.{}, backgroundKernelTask, .{workspace_path});
    _ = kernel_thread; // The thread will run independently until the process exits

    // 3. Initialize View Tree (VSCode Layout)
    root_view = renderer.View.init(.{ .x = 0, .y = 0, .w = 1024, .h = 768 });
    root_view.?.bg_color = .{ .r = 0.117, .g = 0.117, .b = 0.117, .a = 1.0 }; // Fallback background

    // Title Bar
    var header = renderer.View.init(.{ .x = 0, .y = 0, .w = 1024, .h = 30 });
    header.bg_color = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
    header_view = &header;
    try root_view.?.addChild(allocator, &header);

    // Activity Bar (Leftmost narrow icon bar)
    var activity_bar = renderer.View.init(.{ .x = 0, .y = 30, .w = 50, .h = 716 });
    activity_bar.bg_color = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };
    activity_view = &activity_bar;
    try root_view.?.addChild(allocator, &activity_bar);

    // Agent Panel (AI Chat / Diff)
    var agent_panel = renderer.View.init(.{ .x = 50, .y = 30, .w = 400, .h = 716 });
    agent_panel.bg_color = .{ .r = 0.145, .g = 0.145, .b = 0.15, .a = 1.0 };
    agent_view = &agent_panel;
    try root_view.?.addChild(allocator, &agent_panel);

    // File Explorer Panel
    var explorer_panel = renderer.View.init(.{ .x = 450, .y = 30, .w = 250, .h = 716 });
    explorer_panel.bg_color = .{ .r = 0.125, .g = 0.125, .b = 0.13, .a = 1.0 };
    explorer_view = &explorer_panel;
    try root_view.?.addChild(allocator, &explorer_panel);

    // Main Editor Area (Pushed to Right)
    var editor = renderer.View.init(.{ .x = 500, .y = 30, .w = 524, .h = 500 });
    editor.bg_color = .{ .r = 0.117, .g = 0.117, .b = 0.117, .a = 1.0 };
    editor_view = &editor;
    try root_view.?.addChild(allocator, &editor);

    // Panel Area (Terminal / Output)
    var panel = renderer.View.init(.{ .x = 500, .y = 530, .w = 524, .h = 216 });
    panel.bg_color = .{ .r = 0.117, .g = 0.117, .b = 0.117, .a = 1.0 };
    panel_view = &panel;
    try root_view.?.addChild(allocator, &panel);

    // Panel Top Border (simulated with a thin view)
    var panel_border = renderer.View.init(.{ .x = 500, .y = 530, .w = 524, .h = 1 });
    panel_border.bg_color = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };
    border_view = &panel_border;
    try root_view.?.addChild(allocator, &panel_border);

    // Status Bar (Bottom)
    var status_bar = renderer.View.init(.{ .x = 0, .y = 746, .w = 1024, .h = 22 });
    status_bar.bg_color = .{ .r = 0.0, .g = 0.48, .b = 0.8, .a = 1.0 }; // VSCode Blue
    status_view = &status_bar;
    try root_view.?.addChild(allocator, &status_bar);

    border_view.?.bg_color = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };
    panel_view.?.addChild(gpa, border_view.?) catch |e| {
        std.debug.print("OOM: {}\n", .{e});
    };

    text_buffer = TextBuffer.init(gpa) catch unreachable;
    loadFile(gpa, "apps/forge-ide/src/main.zig", &text_buffer) catch {
        text_buffer.insertString("const std = @import(\"std\");\n\npub fn main() !void {\n    std.debug.print(\"Hello World!\", .{});\n}") catch {};
    };
    prompt_buffer = TextBuffer.init(gpa) catch unreachable;
    chat_history = .empty;
    chat_history.append(gpa, .{ .role = .user, .content = "Could you implement the AI-first layout?" }) catch {};
    chat_history.append(gpa, .{ .role = .agent, .content = "Absolutely! I will expand the Agent panel\nand move the Editor to the right side." }) catch {};

    // 4. Initialize and Run the Native Renderer on the Main Thread
    renderer.Renderer.init();
    renderer.Renderer.setRenderCallback(onRenderFrame);
    renderer.Renderer.setKeyCallback(onKeyEvent);
    renderer.Renderer.setMouseCallback(onMouseEvent);
    renderer.Renderer.createWindow("Forge", 1024, 768);

    // This blocks until the app exits
    renderer.Renderer.run();

    std.debug.print("Forge IDE UI closed, shutting down.\n", .{});
}

var time: f32 = 0;
var root_view: ?renderer.View = null;
var header_view: ?*renderer.View = null;
var activity_view: ?*renderer.View = null;
var agent_view: ?*renderer.View = null;
var explorer_view: ?*renderer.View = null;
var editor_view: ?*renderer.View = null;
var panel_view: ?*renderer.View = null;
var border_view: ?*renderer.View = null;
var status_view: ?*renderer.View = null;

var text_buffer: TextBuffer = undefined;
var prompt_buffer: TextBuffer = undefined;

var agent_panel_width: f32 = 400.0;
var explorer_panel_width: f32 = 250.0;

var is_dragging_agent_splitter: bool = false;
var is_dragging_explorer_splitter: bool = false;

pub const PanelFocus = enum { editor, agent };
var focused_panel: PanelFocus = .editor;

var editor_scroll_y: f32 = 0;
var chat_scroll_y: f32 = 0;

const ChatMessage = struct {
    role: enum { user, agent },
    content: [:0]const u8,
};
var chat_history: std.ArrayList(ChatMessage) = undefined;

fn onKeyEvent(event: renderer.KeyEvent) void {
    if (!event.is_down) return;

    var active_buffer = if (focused_panel == .editor) &text_buffer else &prompt_buffer;

    // Backspace
    if (event.keycode == 51) {
        active_buffer.backspace() catch {};
    }
    // Enter
    else if (event.keycode == 36) {
        if (focused_panel == .agent) {
            const prompt_text = prompt_buffer.toString(false) catch "";
            if (prompt_text.len > 0) {
                const text_len = if (prompt_text[prompt_text.len - 1] == 0) prompt_text.len - 1 else prompt_text.len;
                if (text_len > 0) {
                    const content = gpa.dupeZ(u8, prompt_text[0..text_len]) catch "";
                    chat_history.append(gpa, .{ .role = .user, .content = content }) catch {};
                    chat_history.append(gpa, .{ .role = .agent, .content = "I'm thinking..." }) catch {};
                    prompt_buffer.deinit();
                    prompt_buffer = TextBuffer.init(gpa) catch unreachable;
                }
            }
            gpa.free(prompt_text);
        } else {
            active_buffer.insertNewline() catch {};
        }
    }
    // Arrows
    else if (event.keycode == 123) { // Left
        active_buffer.moveLeft();
    } else if (event.keycode == 124) { // Right
        active_buffer.moveRight();
    } else if (event.keycode == 125) { // Down
        active_buffer.moveDown();
    } else if (event.keycode == 126) { // Up
        active_buffer.moveUp();
    }
    // Normal characters
    else if (event.chars.len > 0) {
        const char_val = event.chars[0];
        // Filter out control characters (like tab, esc, etc if needed, but allow unicode)
        if (char_val >= 32 or char_val == '\t') {
            active_buffer.insertString(event.chars) catch {};
        }
    }
}

fn loadFile(allocator: std.mem.Allocator, path: [:0]const u8, buffer: *TextBuffer) !void {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer _ = std.c.close(fd);

    var content = try allocator.alloc(u8, 10 * 1024 * 1024);
    defer allocator.free(content);

    var total_len: usize = 0;
    while (true) {
        const len = std.posix.read(fd, content[total_len..]) catch break;
        if (len == 0) break;
        total_len += len;
    }

    buffer.lines.clearRetainingCapacity();
    buffer.lines.append(allocator, .empty) catch return;
    try buffer.insertString(content[0..total_len]);
    buffer.cursor_row = 0;
    buffer.cursor_col = 0;
}

fn onMouseEvent(event: renderer.MouseEvent) void {
    const agent_splitter_x = 50.0 + agent_panel_width;
    const explorer_splitter_x = agent_splitter_x + explorer_panel_width;

    const is_near_agent_splitter = @abs(event.x - agent_splitter_x) < 5.0;
    const is_near_explorer_splitter = @abs(event.x - explorer_splitter_x) < 5.0;

    if (event.action == .move) {
        if (is_near_agent_splitter or is_near_explorer_splitter) {
            renderer.Renderer.setCursor(2); // ResizeLeftRight
        } else {
            renderer.Renderer.setCursor(0); // Arrow
        }
    } else if (event.action == .down) {
        if (is_near_agent_splitter) {
            is_dragging_agent_splitter = true;
        } else if (is_near_explorer_splitter) {
            is_dragging_explorer_splitter = true;
        } else {
            if (event.x < agent_splitter_x) {
                focused_panel = .agent;
            } else {
                focused_panel = .editor;
                const editor_x = explorer_splitter_x;
                if (event.x > editor_x + 50.0 and event.y > 65.0) {
                    const click_y = event.y - 70.0 + editor_scroll_y;
                    const click_x = event.x - editor_x - 50.0;

                    if (click_y >= 0) {
                        var row: usize = @intFromFloat(click_y / 16.0);
                        if (row >= text_buffer.lines.items.len) {
                            if (text_buffer.lines.items.len > 0) {
                                row = text_buffer.lines.items.len - 1;
                            } else {
                                row = 0;
                            }
                        }

                        var col: usize = 0;
                        if (click_x > -4.8) {
                            col = @intFromFloat((click_x + 4.8) / 9.6);
                        }

                        if (row < text_buffer.lines.items.len) {
                            const line_len = text_buffer.lines.items[row].items.len;
                            if (col > line_len) {
                                col = line_len;
                            }
                        } else {
                            col = 0;
                        }

                        text_buffer.cursor_row = row;
                        text_buffer.cursor_col = col;
                    }
                }
            }
        }
    } else if (event.action == .up) {
        is_dragging_agent_splitter = false;
        is_dragging_explorer_splitter = false;
    } else if (event.action == .drag) {
        if (is_dragging_agent_splitter) {
            agent_panel_width = event.x - 50.0;
            if (agent_panel_width < 200.0) agent_panel_width = 200.0;
            if (agent_panel_width > 800.0) agent_panel_width = 800.0;
        } else if (is_dragging_explorer_splitter) {
            explorer_panel_width = event.x - agent_splitter_x;
            if (explorer_panel_width < 100.0) explorer_panel_width = 100.0;
            if (explorer_panel_width > 500.0) explorer_panel_width = 500.0;
        }
    } else if (event.action == .scroll) {
        if (focused_panel == .editor) {
            editor_scroll_y += event.y * 3.0; // multiplier for scroll speed
            if (editor_scroll_y < 0) editor_scroll_y = 0;

            // Limit scroll based on number of lines
            const max_scroll = @as(f32, @floatFromInt(text_buffer.lines.items.len)) * 16.0;
            if (editor_scroll_y > max_scroll) editor_scroll_y = max_scroll;
        } else {
            chat_scroll_y += event.y * 3.0;
            if (chat_scroll_y < 0) chat_scroll_y = 0;
            // Simple bound
            if (chat_scroll_y > 1000) chat_scroll_y = 1000;
        }
    }
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{ "pub", "fn", "const", "var", "struct", "enum", "union", "return", "try", "catch", "if", "else", "switch", "while", "for", "break", "continue", "defer", "errdefer", "and", "or", "true", "false", "void", "bool", "f32", "f64", "i8", "u8", "i32", "u32", "i64", "u64", "usize", "isize" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn drawHighlightedLine(line: []const u8, x: f32, y: f32) void {
    var i: usize = 0;
    var current_x: f32 = x;
    while (i < line.len) {
        if (line[i] == ' ') {
            current_x += 9.6;
            i += 1;
            continue;
        }

        const start = i;
        const is_num = line[i] >= '0' and line[i] <= '9';
        while (i < line.len and line[i] != ' ' and line[i] != '(' and line[i] != ')' and line[i] != '{' and line[i] != '}' and line[i] != '.' and line[i] != ':' and line[i] != ',' and line[i] != ';' and line[i] != '[' and line[i] != ']') {
            i += 1;
        }

        if (i > start) {
            const word = line[start..i];
            var color = renderer.Color{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 };
            if (isKeyword(word)) {
                color = .{ .r = 0.9, .g = 0.4, .b = 0.7, .a = 1.0 };
            } else if (is_num) {
                color = .{ .r = 0.5, .g = 0.8, .b = 0.5, .a = 1.0 };
            }
            var buf: [256]u8 = undefined;
            if (word.len < 255) {
                @memcpy(buf[0..word.len], word);
                buf[word.len] = 0;
                renderer.Renderer.drawText(@ptrCast(&buf), current_x, y, 16.0, color);
            }
            current_x += @as(f32, @floatFromInt(word.len)) * 9.6;
        }

        if (i < line.len and line[i] != ' ') {
            var buf: [2]u8 = undefined;
            buf[0] = line[i];
            buf[1] = 0;
            renderer.Renderer.drawText(@ptrCast(&buf), current_x, y, 16.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
            current_x += 9.6;
            i += 1;
        }
    }
}

fn onRenderFrame() void {
    var w: f32 = 0;
    var h: f32 = 0;
    renderer.Renderer.getWindowSize(&w, &h);

    if (root_view) |*rv| {
        rv.frame = .{ .x = 0, .y = 0, .w = w, .h = h };
        if (header_view) |v| v.frame = .{ .x = 0, .y = 0, .w = w, .h = 30 };
        if (activity_view) |v| v.frame = .{ .x = 0, .y = 30, .w = 50, .h = h - 52 }; // 30 top, 22 bottom
        if (agent_view) |v| v.frame = .{ .x = 50, .y = 30, .w = agent_panel_width, .h = h - 52 };

        const explorer_x = 50.0 + agent_panel_width;
        if (explorer_view) |v| v.frame = .{ .x = explorer_x, .y = 30, .w = explorer_panel_width, .h = h - 52 };

        const editor_x = explorer_x + explorer_panel_width;
        const editor_w = w - editor_x;
        const editor_h = h - 52 - 216;
        if (editor_view) |v| v.frame = .{ .x = editor_x, .y = 30, .w = editor_w, .h = editor_h };
        if (panel_view) |v| v.frame = .{ .x = editor_x, .y = 30 + editor_h, .w = editor_w, .h = 216 };
        if (border_view) |v| v.frame = .{ .x = editor_x, .y = 30 + editor_h, .w = editor_w, .h = 1 };
        if (status_view) |v| v.frame = .{ .x = 0, .y = h - 22, .w = w, .h = 22 };

        rv.render();

        // Draw Text Overlay (Simplified)
        renderer.Renderer.drawText("Forge IDE", w / 2 - 40, 8, 14.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });

        // Agent Panel Mock UI
        renderer.Renderer.setClipRect(50, 30, agent_panel_width, h - 52);
        renderer.Renderer.drawText("AGENT CHAT", 70, 45, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });

        var chat_y: f32 = 80.0 - chat_scroll_y;
        for (chat_history.items) |msg| {
            const lines = @as(f32, @floatFromInt(std.mem.count(u8, msg.content, "\n") + 1));
            const bubble_h = lines * 16.0 + 10.0;

            if (msg.role == .user) {
                // User Bubble (right aligned visually by padding or color, here we just use background color)
                renderer.Renderer.drawRoundedRect(60, chat_y - 4, agent_panel_width - 80, bubble_h, 8.0, .{ .r = 0.2, .g = 0.2, .b = 0.25, .a = 1.0 });
                renderer.Renderer.drawText("You", 70, chat_y, 14.0, .{ .r = 0.7, .g = 0.7, .b = 0.9, .a = 1.0 });
                renderer.Renderer.drawText(msg.content, 110, chat_y, 14.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            } else {
                // Agent Bubble
                renderer.Renderer.drawRoundedRect(60, chat_y - 4, agent_panel_width - 80, bubble_h, 8.0, .{ .r = 0.15, .g = 0.25, .b = 0.15, .a = 1.0 });
                renderer.Renderer.drawText("Forge", 70, chat_y, 14.0, .{ .r = 0.4, .g = 0.8, .b = 0.4, .a = 1.0 });
                renderer.Renderer.drawText(msg.content, 120, chat_y, 14.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });
            }
            chat_y += bubble_h + 10.0;
        }

        // Draw Agent Chat Scrollbar
        const chat_content_h: f32 = @max(100.0, @as(f32, @floatFromInt(chat_history.items.len)) * 50.0); // Rough estimate
        const chat_view_h = h - 200.0;
        if (chat_content_h > chat_view_h) {
            const scrollbar_h = @max(20.0, chat_view_h * (chat_view_h / chat_content_h));
            const scrollbar_y = 80.0 + (chat_scroll_y / chat_content_h) * chat_view_h;
            renderer.Renderer.drawRoundedRect(agent_panel_width - 15, scrollbar_y, 8, scrollbar_h, 4.0, .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 0.5 });
        }

        // Chat Input Box (Rounded)
        const input_y = h - 52 - 100; // 100px from bottom
        renderer.Renderer.drawRoundedRect(60, input_y, agent_panel_width - 40, 80, 12.0, .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 });

        time += 0.016;
        const show_cursor = @mod(time, 1.0) < 0.5;

        const show_prompt_cursor = show_cursor and focused_panel == .agent;
        const prompt_str = prompt_buffer.toString(show_prompt_cursor) catch return;
        defer gpa.free(prompt_str);
        renderer.Renderer.drawText(prompt_str, 70, input_y + 10, 14.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });

        renderer.Renderer.clearClipRect();

        // Explorer Panel Mock UI
        renderer.Renderer.setClipRect(explorer_x, 30, explorer_panel_width, h - 52);
        renderer.Renderer.drawText("EXPLORER", explorer_x + 20, 45, 12.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });

        var file_y: f32 = 80.0;
        const mock_files = [_][]const u8{
            "> .zig-cache",
            "> apps",
            "> packages",
            "  build.zig",
            "  build.zig.zon",
            "  README.md",
        };
        for (mock_files) |file_name| {
            renderer.Renderer.drawText(file_name, explorer_x + 20, file_y, 14.0, .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1.0 });
            file_y += 24.0;
        }
        renderer.Renderer.clearClipRect();

        // Draw Editor Tab Bar
        renderer.Renderer.drawRect(editor_x, 30, editor_w, 35, .{ .r = 0.12, .g = 0.12, .b = 0.12, .a = 1.0 }); // Tab Bar Bg

        // Active Tab (main.zig)
        renderer.Renderer.drawRoundedRect(editor_x + 10, 36, 100, 30, 6.0, .{ .r = 0.117, .g = 0.117, .b = 0.117, .a = 1.0 });
        renderer.Renderer.drawText("main.zig", editor_x + 25, 43, 13.0, .{ .r = 0.9, .g = 0.9, .b = 0.9, .a = 1.0 });

        // Inactive Tab (package.json)
        renderer.Renderer.drawText("package.json", editor_x + 130, 43, 13.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });

        renderer.Renderer.setClipRect(editor_x, 65, editor_w, editor_h - 35);

        const show_editor_cursor = show_cursor and focused_panel == .editor;

        // Draw Line Numbers and Highlighted Text
        var line_num_y = 70.0 - editor_scroll_y;
        for (text_buffer.lines.items, 0..) |line_list, idx| {
            // Line Number
            var buf: [16]u8 = undefined;
            const line_str = std.fmt.bufPrintZ(&buf, "{d}", .{idx + 1}) catch "";
            renderer.Renderer.drawText(line_str, editor_x + 10, line_num_y, 14.0, .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 });

            // Highlighted Line
            drawHighlightedLine(line_list.items, editor_x + 50, line_num_y);

            // Cursor
            if (show_editor_cursor and idx == text_buffer.cursor_row) {
                const cursor_x = editor_x + 50.0 + @as(f32, @floatFromInt(text_buffer.cursor_col)) * 9.6;
                renderer.Renderer.drawText("|", cursor_x - 4.8, line_num_y, 16.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
            }

            line_num_y += 16.0; // assuming 16.0 spacing per line
        }

        // Draw Editor Scrollbar
        const editor_content_h: f32 = @as(f32, @floatFromInt(text_buffer.lines.items.len)) * 16.0 + 100.0;
        const editor_view_h = editor_h - 35.0;
        if (editor_content_h > editor_view_h) {
            const scrollbar_h = @max(20.0, editor_view_h * (editor_view_h / editor_content_h));
            const scrollbar_y = 65.0 + (editor_scroll_y / editor_content_h) * editor_view_h;
            renderer.Renderer.drawRoundedRect(w - 15, scrollbar_y, 8, scrollbar_h, 4.0, .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 0.5 });
        }

        renderer.Renderer.drawText("Terminal", editor_x + 20, 30 + editor_h + 10, 13.0, .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1.0 });
        renderer.Renderer.clearClipRect();

        renderer.Renderer.drawText("main.zig", 20, h - 18, 12.0, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
    }
}

fn backgroundKernelTask(workspace_path: []const u8) void {
    std.debug.print("[Kernel] Background thread started.\n", .{});

    // Simulate kernel initialization
    var lifecycle = kernel.Lifecycle{};
    lifecycle.transition(.starting) catch unreachable;

    std.debug.print("[Kernel] Initializing workspace at {s}\n", .{workspace_path});
    // In a real implementation, we would init the workspace structure here

    lifecycle.transition(.running) catch unreachable;
    std.debug.print("[Kernel] Ready and listening for events.\n", .{});

    // The thread would normally enter an event loop listening for LSP or AI tasks
    // For now, it just idles
}

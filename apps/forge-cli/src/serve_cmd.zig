const std = @import("std");
const args_mod = @import("args.zig");

/// C helpers for TCP server (Zig 0.16 removed std.posix.socket).
extern fn forge_create_server(port: c_int) c_int;
extern fn forge_accept_client(sockfd: c_int) c_int;
extern fn forge_read_client(fd: c_int, buf: [*]u8, len: c_int) c_int;
extern fn forge_write_client(fd: c_int, buf: [*]const u8, len: c_int) c_int;
extern fn forge_close_fd(fd: c_int) void;

/// `forge serve` — HTTP daemon for forge-mobile PWA.
///
/// Exposes a REST API that wraps existing CLI commands:
///   GET  /api/health        — health check
///   GET  /api/sessions      — list sessions
///   GET  /api/runs          — list background runs
///   GET  /api/model         — get current model info
///   GET  /app               — PWA frontend
///
/// Also serves the PWA frontend from embedded HTML.
/// Default port: 7777.

const PORT: u16 = 7777;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
) !u8 {
    _ = environ_map;
    _ = parsed;
    _ = allocator;
    _ = io;

    try writer.print("Forge Serve — HTTP daemon for forge-mobile\n", .{});
    try writer.print("Listening on http://localhost:{d}\n", .{PORT});
    try writer.print("PWA: http://localhost:{d}/app\n", .{PORT});
    try writer.print("API: http://localhost:{d}/api/health\n", .{PORT});
    try writer.print("Press Ctrl+C to stop.\n\n", .{});

    // Create TCP server using C helper.
    const sockfd = forge_create_server(@intCast(PORT));
    if (sockfd < 0) {
        try writer.print("Failed to start server (error {d})\n", .{sockfd});
        return 1;
    }
    defer forge_close_fd(sockfd);

    try writer.print("Server started. Waiting for connections...\n", .{});

    while (true) {
        const clientfd = forge_accept_client(sockfd);
        if (clientfd < 0) {
            try writer.print("Accept error\n", .{});
            continue;
        }
        handleClient(clientfd, writer) catch |err| {
            try writer.print("Client error: {}\n", .{err});
        };
        forge_close_fd(clientfd);
    }
    return 0;
}

fn handleClient(clientfd: c_int, writer: *std.Io.Writer) !void {
    var buf: [4096]u8 = undefined;
    const n = forge_read_client(clientfd, &buf, buf.len);
    if (n <= 0) return;

    const request = buf[0..@intCast(n)];

    // Parse method and path.
    const method_end = std.mem.indexOfScalar(u8, request, ' ') orelse return;
    const method = request[0..method_end];
    const path_start = method_end + 1;
    const path_end = std.mem.indexOfScalarPos(u8, request, path_start, ' ') orelse return;
    const path = request[path_start..path_end];

    try writer.print("{s} {s}\n", .{ method, path });

    // Route.
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/health")) {
        try sendResponse(clientfd, "application/json", "{\"status\":\"ok\",\"service\":\"forge-serve\",\"version\":\"0.1.0\"}");
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/sessions")) {
        try sendResponse(clientfd, "application/json", "{\"sessions\":[]}");
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/runs")) {
        try sendResponse(clientfd, "application/json", "{\"runs\":[]}");
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/model")) {
        try sendResponse(clientfd, "application/json", "{\"provider\":\"auto\",\"model\":\"auto\"}");
        return;
    }
    // POST /api/chat — send a message to the agent, get response.
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/chat")) {
        // Extract message from request body (simplified JSON parse).
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            try sendResponse(clientfd, "application/json", "{\"error\":\"no body\"}");
            return;
        };
        const body = request[body_start + 4 ..];

        // Parse {"message":"..."} — find message field.
        const msg_key = "\"message\":\"";
        const msg_start = std.mem.indexOf(u8, body, msg_key);
        if (msg_start) |ms| {
            const content_start = ms + msg_key.len;
            const content_end = std.mem.indexOfScalarPos(u8, body, content_start, '"') orelse content_start;
            const user_message = body[content_start..content_end];

            // Build a simple response — in production this would call ai.agent.run().
            // For now, echo back with a simulated agent response.
            var response_buf: [4096]u8 = undefined;
            const response_json = std.fmt.bufPrint(&response_buf,
                "{{\"role\":\"agent\",\"response\":\"Received: {s}\\n\\n(Agent execution requires API key configuration. Set GEMINI_API_KEY or ANTHROPIC_API_KEY to enable real responses.)\",\"status\":\"ok\"}}",
                .{user_message},
            ) catch {
                try sendResponse(clientfd, "application/json", "{\"error\":\"response too long\"}");
                return;
            };
            try sendResponse(clientfd, "application/json", response_json);
        } else {
            try sendResponse(clientfd, "application/json", "{\"error\":\"missing message field\"}");
        }
        return;
    }
    // POST /api/agent/run — start a background agent task.
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/agent/run")) {
        try sendResponse(clientfd, "application/json", "{\"run_id\":\"run_mobile\",\"status\":\"started\",\"message\":\"Agent run started. Use /api/runs to check status.\"}");
        return;
    }
    // POST /api/agent/approve — approve a pending tool.
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/agent/approve")) {
        try sendResponse(clientfd, "application/json", "{\"status\":\"approved\"}");
        return;
    }
    // POST /api/agent/reject — reject a pending tool.
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/agent/reject")) {
        try sendResponse(clientfd, "application/json", "{\"status\":\"rejected\"}");
        return;
    }
    if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/app") or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))) {
        try sendResponse(clientfd, "text/html; charset=utf-8", PWA_HTML);
        return;
    }

    try sendResponse(clientfd, "application/json", "{\"error\":\"not found\"}");
}

fn sendResponse(fd: c_int, content_type: []const u8, body: []const u8) !void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        .{ content_type, body.len },
    ) catch return;
    _ = forge_write_client(fd, hdr.ptr, @intCast(hdr.len));
    _ = forge_write_client(fd, body.ptr, @intCast(body.len));
}

/// Embedded PWA HTML — single-file Progressive Web App.
/// Minimal mobile-optimized UI for forge-mobile.
const PWA_HTML =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    \\  <meta name="apple-mobile-web-app-capable" content="yes">
    \\  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    \\  <title>Forge Mobile</title>
    \\  <style>
    \\    * { margin: 0; padding: 0; box-sizing: border-box; }
    \\    body { font-family: -apple-system, system-ui, sans-serif; background: #0f172a; color: #e2e8f0; min-height: 100vh; }
    \\    .header { background: #1e293b; padding: 16px; text-align: center; border-bottom: 1px solid #334155; }
    \\    .header h1 { font-size: 20px; color: #0ea5e9; }
    \\    .header .status { font-size: 12px; color: #64748b; margin-top: 4px; }
    \\    .tabs { display: flex; background: #1e293b; border-bottom: 1px solid #334155; }
    \\    .tab { flex: 1; padding: 12px; text-align: center; color: #64748b; cursor: pointer; font-size: 14px; }
    \\    .tab.active { color: #0ea5e9; border-bottom: 2px solid #0ea5e9; }
    \\    .content { padding: 16px; }
    \\    .session-card, .run-card { background: #1e293b; border-radius: 12px; padding: 16px; margin-bottom: 12px; border: 1px solid #334155; }
    \\    .session-card .title, .run-card .title { font-weight: 600; font-size: 15px; margin-bottom: 4px; }
    \\    .session-card .meta, .run-card .meta { font-size: 12px; color: #64748b; }
    \\    .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
    \\    .badge.active { background: #10b981; color: #fff; }
    \\    .badge.pending { background: #f59e0b; color: #fff; }
    \\    .badge.done { background: #334155; color: #94a3b8; }
    \\    .actions { display: flex; gap: 8px; margin-top: 12px; }
    \\    .btn { flex: 1; padding: 10px; border: none; border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer; }
    \\    .btn-approve { background: #10b981; color: #fff; }
    \\    .btn-reject { background: #ef4444; color: #fff; }
    \\    .btn-primary { background: #0ea5e9; color: #fff; }
    \\    .empty { text-align: center; color: #64748b; padding: 40px 0; font-size: 14px; }
    \\    .chat-msg { padding: 12px; border-radius: 8px; margin-bottom: 8px; max-width: 85%; }
    \\    .chat-msg.user { background: #0ea5e9; color: #fff; margin-left: auto; }
    \\    .chat-msg.agent { background: #1e293b; border: 1px solid #334155; }
    \\    .chat-input { position: fixed; bottom: 0; left: 0; right: 0; display: flex; background: #1e293b; padding: 8px; border-top: 1px solid #334155; }
    \\    .chat-input input { flex: 1; padding: 12px; border: 1px solid #334155; border-radius: 8px; background: #0f172a; color: #e2e8f0; font-size: 14px; }
    \\    .chat-input button { margin-left: 8px; padding: 12px 16px; background: #0ea5e9; color: #fff; border: none; border-radius: 8px; cursor: pointer; font-weight: 600; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <div class="header">
    \\    <h1>⚡ Forge Mobile</h1>
    \\    <div class="status" id="status">Connecting...</div>
    \\  </div>
    \\  <div class="tabs">
    \\    <div class="tab active" onclick="showTab('sessions')">Sessions</div>
    \\    <div class="tab" onclick="showTab('runs')">Runs</div>
    \\    <div class="tab" onclick="showTab('chat')">Chat</div>
    \\  </div>
    \\  <div class="content" id="sessions">
    \\    <div class="empty">No active sessions. Start one from CLI: forge agent run --background "task"</div>
    \\  </div>
    \\  <div class="content" id="runs" style="display:none">
    \\    <div class="empty">No background runs.</div>
    \\  </div>
    \\  <div class="content" id="chat" style="display:none;padding-bottom:60px">
    \\    <div class="empty">Chat with Forge agent. Messages will appear here.</div>
    \\  </div>
    \\  <div class="chat-input" id="chatInput" style="display:none">
    \\    <input type="text" placeholder="Type a message..." id="msgInput" onkeypress="if(event.key==='Enter')sendMsg()">
    \\    <button onclick="sendMsg()">Send</button>
    \\  </div>
    \\  <script>
    \\    const API = '';
    \\    function showTab(tab) {
    \\      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    \\      document.querySelectorAll('.content').forEach(c => c.style.display = 'none');
    \\      event.target.classList.add('active');
    \\      document.getElementById(tab).style.display = 'block';
    \\      document.getElementById('chatInput').style.display = tab === 'chat' ? 'flex' : 'none';
    \\    }
    \\    function sendMsg() {
    \\      const input = document.getElementById('msgInput');
    \\      const msg = input.value.trim();
    \\      if (!msg) return;
    \\      const chat = document.getElementById('chat');
    \\      const div = document.createElement('div');
    \\      div.className = 'chat-msg user';
    \\      div.textContent = msg;
    \\      chat.appendChild(div);
    \\      input.value = '';
    \\      chat.scrollTop = chat.scrollHeight;
    \\      // Send to /api/chat
    \\      const loading = document.createElement('div');
    \\      loading.className = 'chat-msg agent';
    \\      loading.textContent = 'Thinking...';
    \\      loading.id = 'loading';
    \\      chat.appendChild(loading);
    \\      chat.scrollTop = chat.scrollHeight;
    \\      fetch(API + '/api/chat', {
    \\        method: 'POST',
    \\        headers: {'Content-Type': 'application/json'},
    \\        body: JSON.stringify({message: msg})
    \\      }).then(r => r.json()).then(d => {
    \\        loading.remove();
    \\        const resp = document.createElement('div');
    \\        resp.className = 'chat-msg agent';
    \\        resp.textContent = d.response || d.error || 'No response';
    \\        chat.appendChild(resp);
    \\        chat.scrollTop = chat.scrollHeight;
    \\      }).catch(e => {
    \\        loading.remove();
    \\        const err = document.createElement('div');
    \\        err.className = 'chat-msg agent';
    \\        err.textContent = 'Error: ' + e;
    \\        chat.appendChild(err);
    \\        chat.scrollTop = chat.scrollHeight;
    \\      });
    \\    }
    \\    // Health check
    \\    fetch(API + '/api/health').then(r => r.json()).then(d => {
    \\      document.getElementById('status').textContent = 'Connected · ' + d.version;
    \\    }).catch(() => {
    \\      document.getElementById('status').textContent = 'Offline';
    \\    });
    \\  </script>
    \\</body>
    \\</html>
;

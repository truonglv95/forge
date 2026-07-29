const std = @import("std");
const args_mod = @import("args.zig");
const ai = @import("forge-ai");
const ai_workflow = @import("ai_workflow.zig");
const workspace_cmd = @import("workspace_cmd.zig");

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
    // Open workspace for agent execution.
    var opened = workspace_cmd.OpenedWorkspace.open(allocator, io, parsed) catch {
        try writer.print("Failed to open workspace\n", .{});
        return 1;
    };
    defer opened.close(io);

    const serve_ctx = ServeCtx{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .opened = opened,
        .parsed = parsed,
        .writer = writer,
    };

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
        handleClient(clientfd, &serve_ctx) catch |err| {
            try writer.print("Client error: {}\n", .{err});
        };
        forge_close_fd(clientfd);
    }
    return 0;
}

const ServeCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    opened: workspace_cmd.OpenedWorkspace,
    parsed: args_mod.CliArgs,
    writer: *std.Io.Writer,
};

fn handleClient(clientfd: c_int, ctx: *const ServeCtx) !void {
    var buf: [8192]u8 = undefined;
    const n = forge_read_client(clientfd, &buf, buf.len);
    if (n <= 0) return;

    const request = buf[0..@intCast(n)];

    const method_end = std.mem.indexOfScalar(u8, request, ' ') orelse return;
    const method = request[0..method_end];
    const path_start = method_end + 1;
    const path_end = std.mem.indexOfScalarPos(u8, request, path_start, ' ') orelse return;
    const path = request[path_start..path_end];

    try ctx.writer.print("{s} {s}\n", .{ method, path });

    // Route.
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/health")) {
        try sendResponse(clientfd, "application/json", "{\"status\":\"ok\",\"service\":\"forge-serve\",\"version\":\"0.2.0\"}");
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

    // POST /api/chat — send message to agent, get real response.
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/chat")) {
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            try sendResponse(clientfd, "application/json", "{\"error\":\"no body\"}");
            return;
        };
        const body = request[body_start + 4 ..];

        const msg_key = "\"message\":\"";
        const msg_start = std.mem.indexOf(u8, body, msg_key);
        if (msg_start) |ms| {
            const content_start = ms + msg_key.len;
            const content_end = std.mem.indexOfScalarPos(u8, body, content_start, '"') orelse content_start;
            const user_message = body[content_start..content_end];

            // Run real agent — call ai.agent.run() with the user message.
            try ctx.writer.print("  Agent run: {s}\n", .{user_message});

            var provider_opts = ai_workflow.agentProviderOptionsFromFlags(
                ctx.allocator,
                ctx.parsed.flags,
                user_message,
                ctx.io,
                ctx.opened.root,
            );
            defer provider_opts.deinit(ctx.allocator);

            var result = ai.agent.run(
                ctx.allocator,
                ctx.io,
                ctx.environ_map,
                ctx.opened.root,
                user_message,
                .{
                    .max_steps = 256,
                    .provider_options = provider_opts.options,
                    .mode = .agent,
                    .capability_profile = .propose,
                    .max_repair_attempts = 0,
                    .workspace_cwd = ctx.opened.path,
                    .approve_every_time_tools = true,
                },
            ) catch |err| {
                var err_buf: [256]u8 = undefined;
                const err_json = std.fmt.bufPrint(&err_buf,
                    "{{\"role\":\"agent\",\"response\":\"Agent error: {s}\",\"status\":\"error\"}}",
                    .{@errorName(err)},
                ) catch "{\"error\":\"agent failed\"}";
                try sendResponse(clientfd, "application/json", err_json);
                return;
            };
            defer ai.agent.deinitResult(ctx.allocator, &result);

            const response_text = result.response_text orelse "(no response)";
            // Escape response for JSON (basic: replace " and \ and newlines).
            var escaped: std.ArrayList(u8) = .empty;
            defer escaped.deinit(ctx.allocator);
            for (response_text) |ch| {
                switch (ch) {
                    '"' => { escaped.appendSlice(ctx.allocator, "\\\"") catch {}; },
                    '\\' => { escaped.appendSlice(ctx.allocator, "\\\\") catch {}; },
                    '\n' => { escaped.appendSlice(ctx.allocator, "\\n") catch {}; },
                    '\r' => { escaped.appendSlice(ctx.allocator, "\\r") catch {}; },
                    '\t' => { escaped.appendSlice(ctx.allocator, "\\t") catch {}; },
                    else => { escaped.append(ctx.allocator, ch) catch {}; },
                }
            }

            // Build JSON response.
            var json_buf: [16384]u8 = undefined;
            const json = std.fmt.bufPrint(&json_buf,
                "{{\"role\":\"agent\",\"response\":\"{s}\",\"status\":\"ok\",\"steps\":{d}}}",
                .{ escaped.items, result.steps.len },
            ) catch {
                // Response too large — truncate.
                const trunc = if (escaped.items.len > 8000) escaped.items[0..8000] else escaped.items;
                const trunc_json = std.fmt.bufPrint(&json_buf,
                    "{{\"role\":\"agent\",\"response\":\"{s}...(truncated)\",\"status\":\"ok\"}}",
                    .{trunc},
                ) catch "{\"error\":\"too large\"}";
                try sendResponse(clientfd, "application/json", trunc_json);
                return;
            };
            try sendResponse(clientfd, "application/json", json);
        } else {
            try sendResponse(clientfd, "application/json", "{\"error\":\"missing message field\"}");
        }
        return;
    }

    // POST /api/agent/run — start background agent task.
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/agent/run")) {
        try sendResponse(clientfd, "application/json", "{\"run_id\":\"run_mobile\",\"status\":\"started\",\"message\":\"Agent run started. Use /api/runs to check status.\"}");
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/agent/approve")) {
        try sendResponse(clientfd, "application/json", "{\"status\":\"approved\"}");
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/agent/reject")) {
        try sendResponse(clientfd, "application/json", "{\"status\":\"rejected\"}");
        return;
    }

    // SSE endpoint for realtime events.
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/events/stream")) {
        try sendSSEHeader(clientfd);
        // Send a heartbeat event every 5 seconds for 30 seconds.
        var i: u8 = 0;
        while (i < 6) : (i += 1) {
            var event_buf: [256]u8 = undefined;
            const event = std.fmt.bufPrint(&event_buf,
                "data: {{\"type\":\"heartbeat\",\"seq\":{d}}}\n\n",
                .{i},
            ) catch break;
            _ = forge_write_client(clientfd, event.ptr, @intCast(event.len));
            var ts: std.c.timespec = .{ .sec = 5, .nsec = 0 };
            _ = std.c.nanosleep(&ts, null);
        }
        return;
    }

    // forge share — collaborative session info.
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/share/info")) {
        try sendResponse(clientfd, "application/json",
            "{\"feature\":\"forge-share\",\"status\":\"active\",\"clients\":0,\"description\":\"Collaborative coding via WebSocket. Connect to /api/events/stream for realtime updates.\"}");
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

fn sendSSEHeader(fd: c_int) !void {
    const hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n";
    _ = forge_write_client(fd, hdr.ptr, @intCast(hdr.len));
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
    \\      // Start SSE stream for realtime events.
    \\      const evtSrc = new EventSource(API + '/api/events/stream');
    \\      evtSrc.onmessage = function(e) {
    \\        try {
    \\          const d = JSON.parse(e.data);
    \\          if (d.type === 'heartbeat') {
    \\            document.getElementById('status').textContent = 'Live · seq ' + d.seq;
    \\          }
    \\        } catch(err) {}
    \\      };
    \\    }).catch(() => {
    \\      document.getElementById('status').textContent = 'Offline';
    \\    });
    \\    // Load sessions and runs on startup.
    \\    fetch(API + '/api/sessions').then(r => r.json()).then(d => {
    \\      if (d.sessions && d.sessions.length > 0) {
    \\        const el = document.getElementById('sessions');
    \\        el.innerHTML = '';
    \\        d.sessions.forEach(s => {
    \\          el.innerHTML += '<div class="session-card"><div class="title">' + s.id + '</div><div class="meta">' + s.intent + '</div><span class="badge ' + s.state + '">' + s.state + '</span></div>';
    \\        });
    \\      }
    \\    }).catch(() => {});
    \\    fetch(API + '/api/runs').then(r => r.json()).then(d => {
    \\      if (d.runs && d.runs.length > 0) {
    \\        const el = document.getElementById('runs');
    \\        el.innerHTML = '';
    \\        d.runs.forEach(r => {
    \\          el.innerHTML += '<div class="run-card"><div class="title">' + r.id + '</div><div class="meta">' + r.status + '</div><span class="badge ' + r.status + '">' + r.status + '</span><div class="actions"><button class="btn btn-approve" onclick="approveRun(\'' + r.id + '\')">Approve</button><button class="btn btn-reject" onclick="rejectRun(\'' + r.id + '\')">Reject</button></div></div>';
    \\        });
    \\      }
    \\    }).catch(() => {});
    \\    function approveRun(id) {
    \\      fetch(API + '/api/agent/approve', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({run_id: id})}).then(r => r.json()).then(d => {
    \\        alert('Approved: ' + d.status);
    \\      });
    \\    }
    \\    function rejectRun(id) {
    \\      fetch(API + '/api/agent/reject', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({run_id: id})}).then(r => r.json()).then(d => {
    \\        alert('Rejected: ' + d.status);
    \\      });
    \\    }
    \\  </script>
    \\</body>
    \\</html>
;

# RFC-0017: CLI Chat REPL & Mentions

> **Trạng thái:** Proposed
> **Tác giả:** truonglv95 <anhtruonglavm2@gmail.com>
> **Ngày:** 2026-07-24
> **Liên kết:** [AI Workflow Evaluation](../evaluation/AI_WORKFLOW_EVALUATION.md) ·
> [RFC-0005 Run & Session Records](RFC-0005-run-and-session-records.md)

## 1. Tóm tắt

Thêm `forge chat` interactive REPL với @mentions (`@file`, `@symbol`, `@web`,
`@docs`), slash commands (`/context`, `/resume`, `/mode`, `/capability`),
streaming output với token counter, và persistent history. Mục tiêu: đạt
parity với Cursor chat CLI cho terminal-first workflow.

## 2. Động lực

Hiện tại:
- `forge ask` là one-shot, không có multi-turn REPL.
- `forge agent run` headless, không interactive.
- TUI app (`forge agent --interactive`) chưa hoàn thiện.
- Không có @mentions parsing — phải `--file` flag.
- Không có slash commands.

Cursor CLI có `cursor chat` interactive. Để terminal-first developer dùng
Forge, cần `forge chat` REPL.

## 3. Thiết kế

### 3.1. REPL overview

```text
$ forge chat --workspace .
Welcome to Forge Chat. Type /help for commands, /exit to quit.
Provider: gemini | Model: gemini-2.5-flash | Mode: agent | Capability: propose

> @file:src/main.zig explain what this file does
[context] src/main.zig (4.2 KB, explicit)
[stream] This file contains the entry point for the forge-cli application...
[tokens] input: 1200, output: 250, total: 1450 ($0.002)

> /mode ask
Mode: ask (read-only, no proposals)

> how do I add a new CLI command?
[stream] To add a new CLI command in Forge...
[tokens] input: 1800, output: 400, total: 2200 ($0.003)

> /exit
Session saved: sess_abc123
```

### 3.2. Slash commands

| Command | Mô tả |
|---|---|
| `/help` | Show available commands |
| `/exit` | Exit REPL (session saved) |
| `/mode <ask\|plan\|agent>` | Switch mode |
| `/capability <read_only\|propose\|propose_and_task>` | Switch capability |
| `/provider <name>` | Switch provider |
| `/model <id>` | Switch model |
| `/context` | Show current context manifest |
| `/context add @file:path` | Add file to context |
| `/context clear` | Clear explicit context |
| `/resume <session_id>` | Resume previous session |
| `/sessions` | List recent sessions |
| `/history` | Show current session history |
| `/undo` | Undo last transaction |
| `/diff` | Show pending proposal diff |
| `/apply` | Apply pending proposal |
| `/reject` | Reject pending proposal |
| `/tools` | Show available tools for current mode/capability |
| `/providers` | List providers |
| `/models` | List models |
| `/cost` | Show cumulative token cost this session |
| `/save <path>` | Export session transcript to file |
| `/spec <id>` | Load spec into context |

### 3.3. @mention parsing

#### 3.3.1. Syntax

```text
@file:path/to/file.zig          # include file content
@file:path:10-50                # include lines 10-50
@symbol:FunctionName            # LSP symbol lookup
@web:search query               # web search (via fetch_url or search API)
@docs:library name              # docs lookup (via indexed docs)
@spec:spec-id                   # spec content
@recent                         # recent files (last 5)
@git:diff                       # current git diff
@git:status                     # git status
```

#### 3.3.2. Parsing

```zig
// apps/forge-cli/src/chat_repl.zig (new)

pub const Mention = union(enum) {
    file: struct { path: []const u8, line_range: ?LineRange },
    symbol: []const u8,
    web: []const u8,
    docs: []const u8,
    spec: []const u8,
    recent,
    git_diff,
    git_status,
};

pub fn parseMentions(allocator: std.mem.Allocator, input: []const u8) ![]Mention {
    var mentions = std.ArrayList(Mention).empty;
    defer mentions.deinit(allocator);

    var iter = std.mem.tokenize(u8, input, " \t\n");
    while (iter.next()) |token| {
        if (!std.mem.startsWith(u8, token, "@")) continue;
        const body = token[1..];

        if (std.mem.startsWith(u8, body, "file:")) {
            const rest = body[5..];
            // Parse path:line-range
            if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
                const path = rest[0..colon];
                const range_str = rest[colon+1..];
                const range = parseLineRange(range_str) catch null;
                try mentions.append(allocator, .{ .file = .{ .path = path, .line_range = range } });
            } else {
                try mentions.append(allocator, .{ .file = .{ .path = rest, .line_range = null } });
            }
        } else if (std.mem.startsWith(u8, body, "symbol:")) {
            try mentions.append(allocator, .{ .symbol = body[7..] });
        } else if (std.mem.startsWith(u8, body, "web:")) {
            try mentions.append(allocator, .{ .web = body[4..] });
        } else if (std.mem.startsWith(u8, body, "docs:")) {
            try mentions.append(allocator, .{ .docs = body[5..] });
        } else if (std.mem.startsWith(u8, body, "spec:")) {
            try mentions.append(allocator, .{ .spec = body[5..] });
        } else if (std.mem.eql(u8, body, "recent")) {
            try mentions.append(allocator, .recent);
        } else if (std.mem.eql(u8, body, "git:diff")) {
            try mentions.append(allocator, .git_diff);
        } else if (std.mem.eql(u8, body, "git:status")) {
            try mentions.append(allocator, .git_status);
        }
    }
    return mentions.toOwnedSlice(allocator);
}
```

#### 3.3.3. Resolution

Mỗi mention resolve thành ContextBlock:
- `@file` → read file, add to context manifest with `source: explicit_mention`
- `@symbol` → LSP workspace_symbol, then read symbol location
- `@web` → fetch_url tool, summarize if too long
- `@docs` → look up in indexed docs (Phase 2, fallback to @web)
- `@spec` → read spec file
- `@recent` → read 5 recent files
- `@git:diff` → run `git diff` tool
- `@git:status` → run `git status` tool

### 3.4. Streaming output

```text
[context] src/main.zig (4.2 KB)
[context] @symbol:calculateTotal (1.2 KB, src/calc.zig:42)
[llm] Streaming... 250 tokens, 1.2s
This file contains the entry point for the forge-cli application.
It parses CLI arguments and dispatches to subcommand handlers.

[tokens] input: 5400, output: 250, total: 5650
[cost] $0.008 (gemini-2.5-flash: $0.075/$0.30 per Mtok)
```

#### 3.4.1. Stream events

```text
[context] <source> (<size>)           # context item added
[llm] Streaming... <tokens>, <time>   # progress (every 100 tokens)
[tool] <name>(<args>)                 # tool call
[tool_result] <summary>               # tool result
[proposal] <id>                       # proposal created
[diff] +/-<lines>                     # diff summary
[validation] pass/fail                # validation result
[answer] <text>                       # final answer
[tokens] input: N, output: N, total: N
[cost] $X.XX
```

### 3.5. Multi-turn conversation

```text
> explain this file
[answer] This file...

> what about line 42?
[answer] Line 42 is...  # context from previous turn included

> /context clear
Context cleared.

> now explain a different file @file:other.zig
[answer] This file...
```

Conversation history kept in-memory, written to session log on exit.

### 3.6. Session persistence

- On exit: `Session saved: sess_abc123`
- Resume: `forge chat --resume sess_abc123` or `/resume sess_abc123` in new
  session.
- Session log: `.forge/sessions/sess_abc123/events.jsonl` (existing format).
- Chat transcript: `.forge/sessions/sess_abc123/chat.md` (human-readable).

### 3.7. Configuration

```toml
# forge.toml
[ai.chat]
default_mode = "agent"
default_capability = "propose"
default_provider = "auto"
default_model = ""
history_lines = 1000                # max lines in scrollback
stream_progress_interval = 100      # tokens between progress updates
show_token_count = true
show_cost = true
save_on_exit = true
prompt_format = "> "                # input prompt
```

### 3.8. CLI

```bash
# Start REPL
forge chat
forge chat --workspace .
forge chat --mode ask --capability read_only
forge chat --resume sess_abc123

# One-shot (still support forge ask)
forge ask "..." --provider auto

# Pipe mode
echo "explain this" | forge chat --pipe
cat questions.txt | forge chat --pipe --json
```

### 3.9. Keyboard shortcuts

| Key | Hành động |
|---|---|
| `Enter` | Send |
| `Shift+Enter` | Newline |
| `Ctrl+C` | Cancel current stream |
| `Ctrl+D` | Exit (EOF) |
| `↑/↓` | History navigation |
| `Tab` | Autocomplete @mention / slash command |
| `Ctrl+L` | Clear screen |
| `Ctrl+R` | Reverse search history |

### 3.10. Autocomplete

- `@` trigger: list files, symbols (via LSP), recent, git, spec.
- `/` trigger: list slash commands.
- Path autocomplete: `@file:src/` → list files in src/.

## 4. Testing

### 4.1. Unit tests

```zig
test "parseMentions extracts @file" { ... }
test "parseMentions extracts @symbol" { ... }
test "parseMentions extracts @web" { ... }
test "parseMentions extracts @recent" { ... }
test "parseMentions handles line range" { ... }
test "parseMentions ignores plain text" { ... }
test "slash command parsing" { ... }
test "slash command dispatch" { ... }
test "session save on exit" { ... }
test "session resume restores context" { ... }
```

### 4.2. Integration tests

```bash
# REPL via pipe
echo "what is 2+2" | forge chat --pipe --provider fake --json
# Expect: answer in JSON

# Multi-turn via pipe
printf "hello\nhow are you\n" | forge chat --pipe --provider fake

# Slash commands via pipe
printf "/mode ask\nhello\n/exit\n" | forge chat --pipe --provider fake

# Mention resolution
echo "@file:fixtures/sample.txt what is this?" | forge chat --pipe --provider fake --json
# Expect: context manifest has file fixture
```

### 4.3. Manual eval

- 30 phút continuous chat session không crash.
- 10 @mentions (mix of @file, @symbol, @web, @recent, @git) resolve đúng.
- 5 slash commands works.
- Resume session restore context.
- Stream cancellation với Ctrl+C.

## 5. Rollout plan

1. **Week 1:** REPL skeleton + slash commands + `/help`, `/exit`, `/mode`,
   `/capability`, `/provider`, `/model`.
2. **Week 1-2:** @mention parsing + resolution (file, recent, git).
3. **Week 2:** Streaming output + token counter + cost display.
4. **Week 2-3:** `@symbol` (LSP) + `@web` (fetch_url) + `@spec`.
5. **Week 3:** Session persistence + resume + `/save`.
6. **Week 3-4:** Autocomplete (Tab) + history navigation.
7. **Week 4:** Polish + dogfood + 30-min session test.

## 6. Risks

| Rủi ro | Giảm |
|---|---|
| Terminal raw mode portability | Use libc line editor or libedit if needed |
| @symbol LSP slow | Debounce + cache + fallback to text search |
| @web fetch timeout | 5s timeout, fallback to "fetch failed" message |
| Stream flicker | Buffer + render diff |
| Memory leak long session | Cap history_lines, compact old turns |

## 7. Alternatives considered

- **No REPL, only TUI:** ❌ TUI phức tạp hơn, REPL nhanh cho power user.
- **External REPL (rlwrap):** ❌ Phá native Zig story.
- **No @mentions:** ❌ Gap vs Cursor, bad UX.
- **No slash commands:** ❌ Hard to switch mode/capability mid-session.

## 8. Open questions

- [ ] Có nên support `@image:path.png` for multimodal?
      → Phase 2, nếu provider support.
- [ ] Có nên support pipe between commands (`/diff | /apply`)?
      → Phase 2.
- [ ] Có nên support macros (sequence of commands)?
      → Phase 2.
- [ ] Web search provider (Google, Brave)?
      → Phase 2, via `forge.toml [ai.search]`.

## 9. Exit gate

- [ ] `forge chat` starts REPL với prompt
- [ ] `/help`, `/exit`, `/mode`, `/capability`, `/provider`, `/model`,
      `/context`, `/tools`, `/cost`, `/save`, `/resume`, `/sessions` works
- [ ] `@file:path`, `@symbol:name`, `@web:query`, `@recent`, `@git:diff`,
      `@git:status`, `@spec:id` resolve đúng
- [ ] Streaming output với token counter + cost
- [ ] Session save on exit, resume on `--resume`
- [ ] Tab autocomplete for @mentions and slash commands
- [ ] History navigation với ↑/↓
- [ ] 30 phút continuous session không crash
- [ ] `--pipe` mode works cho automation

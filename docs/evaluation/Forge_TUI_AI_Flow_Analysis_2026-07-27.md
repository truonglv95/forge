# Forge TUI + AI Flow — Competitive Analysis (2026-07-27)

> Bản phân tích code-level toàn diện Forge AI flow (`packages/ai/`) và TUI
> (`apps/forge-cli/src/agent_tui/`), đối chiếu với 9 competitor mạnh nhất:
> Cursor, Kiro, Antigravity, Claude Code, Aider, Crush, gemini-cli, codex, opencode.
>
> **Tác giả:** truonglv95 <anhtruonglavm2@gmail.com>
> **Ngày:** 2026-07-27
> **Commit phân tích:** 182cb08
> **Phương pháp:** Code-level review + docs analysis + competitive landscape
> **PDF đầy đủ:** `Forge_TUI_AI_Flow_Analysis_2026-07-27.pdf`

---

## 1. Tóm tắt điều hành

Forge đã sở hữu **xương sống của một AI IDE thật**: transaction an toàn với
content-hash precondition, agent loop với tool registry có phân quyền 3 cấp,
context engine có manifest và 3-tier budget, NDJSON event stream, session
persistence, và **3 surfaces (CLI / TUI / IDE) dùng chung một kernel**. Đây là
nền tảng vững hơn nhiều so với các IDE Electron ở cùng giai đoạn pre-alpha.

Tuy nhiên, Forge đang bị kẹt ở giai đoạn **"wire-but-not-render"**: nhiều feature
đã khai báo trong code/docs nhưng chưa thực sự hoạt động hoặc chưa có UI hiển
thị. 5 gap P0 cần fix trước khi claim "Cursor 2 parity":

1. **Anthropic provider tool loop bị hỏng** — `completeTurnImpl` wrap
   `conversation_json` as text, `toolDeclarationsJsonImpl` trả `"[]"`.
2. **TUI streaming bị block khi `agent_busy`** — user không thấy token stream
   trong multi-step agent turn (`app.zig:4639`).
3. **Background agent control plane stubs** — `wait/cancel/approve/reject` chỉ
   in message, không implement (`agent_cmd.zig:1107-1161`).
4. **OS sandbox backend thiếu** — release blocker, chỉ có snapshot isolation
   (CAPABILITY_MATRIX #1).
5. **Linux IDE build fail** — IME callbacks không implement trong `x11_window.c`
   (CAPABILITY_MATRIX #6).

### Đánh giá tổng hợp

| Lĩnh vực | Điểm | Nhận định |
|---|---|---|
| Foundation (agent loop, transaction, providers, MCP, context) | 9/10 | Production-grade |
| Cursor parity (inline, Composer, @mentions, chat REPL) | 7/10 | Wired nhưng nhiều stubs |
| Kiro parity (spec-driven, hooks, steerables) | 6/10 | CLI đầy đủ, IDE chưa |
| Antigravity parity (timeline, background, multi-agent) | 5/10 | Primitives có, control stubs |
| TUI polish (streaming, themes, mouse, vim, @mention picker) | 4/10 | 4 gap critical |
| Provider correctness (đặc biệt Anthropic) | 5/10 | Anthropic tool loop BROKEN |
| Security (sandbox, secret scanner, command allowlist) | 7/10 | Mac OK, Linux thiếu |

---

## 2. Kiến trúc tổng quan

### Sơ đồ luồng AI (6 tầng)

| Tầng | Module chính | Vai trò |
|---|---|---|
| Intent routing | `routing.zig`, `intent_classifier.zig`, `route_resolver.zig` | Heuristic + LLM arbiter → 6 TaskIntent + 3 CapabilityProfile |
| Context assembly | `context_loader.zig`, `context_budget.zig`, `context_rerank.zig`, `context_manifest.zig` | Hybrid retrieval + RRF fusion + 3-tier budget + secret redaction |
| Adaptive budget | `adaptive_budget.zig`, `task_ledger.zig` | Step budget theo intent (answer=4, debug=24, cap 64) |
| Tool loop | `agent/loop.zig`, `agent/turn.zig`, `agent/tool_phase.zig` | Provider-agnostic Transport vtable, evidence-gated writes |
| Edit pipeline | `proposal_workflow.zig`, `proposal_normalize.zig`, `proposal_precondition.zig` | WorkspaceEdit schema v1 + expected_hash + disposable trial |
| Validation | `validation_runner.zig`, `repair_loop.zig` | Trial workspace copy + fmt/build/test + auto-repair |
| Persistence | `run_record.zig`, `agent/session_docs.zig`, `agent/event_logger.zig` | Run schema v1 + checkpoint v3 + NDJSON events |

### Ba surfaces dùng chung kernel

- **CLI** (`forge-cli`): trưởng thành nhất, 60+ subcommands cho workspace,
  transaction, AI, agent, spec, providers, models.
- **TUI** (`apps/forge-cli/src/agent_tui/`): raw-termios + ANSI renderer,
  6600+ dòng, 70+ slash commands, agent worker thread giao tiếp qua mutex +
  ApprovalGate.
- **IDE** (`apps/forge-ide/`): native app macOS/Linux/Windows với GPU rendering
  (Metal/OpenGL/D3D11), LSP controller, sidebar panels, agent panel với
  timeline cards.

Cả 3 surfaces dùng chung `packages/ai`, `packages/workspace`, `packages/lsp`,
`packages/kernel` — đảm bảo cùng schema Run/Proposal/TransactionId, cùng
semantics context budget, cùng approval gating.

---

## 3. Phân tích AI Flow — 16 tầng

Chi tiết bảng đánh giá với ✅/⚠️/❌ và dẫn chứng file:line cho mỗi tầng (agent
loop, context engine, tool calling, provider abstraction, multi-file edit,
inline completion, spec-driven, background agents, subagents, validation & repair,
memory, MCP, intent routing, streaming & events, security, observability) —
xem PDF đầy đủ `Forge_TUI_AI_Flow_Analysis_2026-07-27.pdf` mục 3.

### Top findings AI flow

- ✅ **Agent loop** rõ ràng, có mid-turn cancellation, ContextLengthExceeded
  recovery, malformed response auto-repair, final gate block.
- ✅ **Context engine** hybrid RRF retrieval với Vietnamese intent expansion
  (80+ phrases).
- ✅ **Tool calling** 24 native tools với CapabilityProfile 3 cấp, structured
  WorkspaceEdit schema v1 với expected_hash.
- ⚠️ **Anthropic provider tool loop BROKEN** — `toolDeclarationsJsonImpl`
  trả `"[]"`, Claude không bao giờ trigger tool_call.
- ⚠️ **`multi_file_edit.zig` ComposerBatch orphaned** — chỉ re-export, không
  có caller.
- ⚠️ **Inline completion không FIM native** — prompt plain text thay vì
  `<PRE>/<SUF>/<MID>`.
- ⚠️ **Spec approval không enforced trong `agent.zig`** — `forge agent run`
  edit dù spec chưa approved.
- ⚠️ **`chat_memory.zig` MemoryStore orphan** — cross-session recall không
  hoạt động.
- ⚠️ **`spawn_subagent` tool là stub** — luôn tạo fake provider.
- ⚠️ **Parallel tool execution** — sequential MVP, không concurrent.
- ⚠️ **Thinking block parsing thiếu** — chỉ Gemini, Anthropic/OpenAI không
  parse `thinking`/`reasoning_content`.

---

## 4. Phân tích TUI — 16 tầng

Chi tiết bảng đánh giá với ✅/⚠️/❌ cho mỗi tầng (terminal I/O, layout & panels,
input handling, streaming, tool call display, slash commands, @mention picker,
diff review, sessions & history, themes, modes, help & onboarding, error UX,
performance, accessibility, comparison với TUI competitors) — xem PDF đầy đủ
mục 4.

### Top 4 gap critical của TUI (blocker cho daily use)

1. **Token streaming bị block khi `agent_busy`** (`app.zig:4639`) — user chỉ
   thấy "Thinking..." spinner trong multi-step turn, response ồ ạt qua
   `workerDone`. Mọi leading TUI (Claude Code, Aider, Crush, gemini-cli,
   codex) đều stream live.
2. **KHÔNG có @mention picker UI** — `extractFileMentions` (app.zig:4483) chỉ
   parse `@path` text. Không có popover fuzzy search files, không
   @symbol/@docs/@web.
3. **KHÔNG có hunk-level diff accept/reject** — chỉ `a` (apply all) hoặc `n`
   (dismiss all). Aider, Claude Code, Cursor, OpenCode đều có per-hunk.
4. **KHÔNG có real themes** — `setTheme` chỉ toggle `use_color`. Aider, Crush,
   gemini-cli, OpenCode đều có palettes thật.

### 4 stub features wired-but-not-rendered

- `filter_role` (app.zig:160, 2369) — set field nhưng render không đọc.
- `pinned` (app.zig:162, 2528) — stored nhưng không prepend to top.
- `bookmarks` (app.zig:158, 2188) — stored nhưng không có indicator.
- `tags` (app.zig:185, 2936) — stored nhưng không hiển thị.

### Render cache dead code

- `render_cache_version` (app.zig:176) — declared dead code, mỗi frame decorate
  + wrap + dupe ALL lines, O(N) allocations per frame.
- `FrameBuffer.prev_rows` (term.zig:160-161) — diff rendering declared nhưng
  không implement, vẫn full-frame rewrite.

---

## 5. So sánh với competitors

### vs Cursor

| Killer feature | Forge status |
|---|---|
| Tab inline completion (fast, multi-line, caching, FIM native) | ⚠️ Wired nhưng không FIM native, không caching wire IDE |
| Composer multi-file (Cmd+K + multi-select) | ⚠️ CLI works, IDE single-file, ComposerBatch orphan |
| Background cloud agents | ❌ CLI `--background` works, wait/cancel/approve stubs |
| Checkpoints | ✅ Transaction undo, mạnh hơn (atomic multi-file) |
| Memory / .cursorrules | ✅ FORGE.md + AGENTS.md parity đạt |
| YOLO mode | ✅ `--trust-all` parity đạt |

### vs Kiro

| Killer feature | Forge status |
|---|---|
| Spec-driven development (IDE first-class UX) | ⚠️ CLI full, IDE chỉ approve button |
| Hooks (pre/post file save, post agent) | ⚠️ On-save hooks có, agent hooks chưa |
| Steerables (mode-based behavior) | ✅ Ask/Plan/Agent + capability profile, mạnh hơn |

### vs Antigravity

| Killer feature | Forge status |
|---|---|
| Agent timeline (DAG view) | ❌ IDE chỉ 3-dot static card |
| Background runs + multi-agent parallel cards | ⚠️ Primitives có, control stubs, không parallel cards UI |
| Trajectory editor (replay + edit step) | ❌ Không replay, branch copy all events verbatim |
| Cloud sessions + sync | ❌ Local only (ROADMAP §16 deferred) |

### vs Claude Code

| Killer feature | Forge status |
|---|---|
| Live token streaming trong TUI | ❌ `onStreamChunk` returns early khi `agent_busy` |
| `/agents` subagents command | ⚠️ Subagents có nhưng không có TUI command manage |
| `/memory` persistent memory file | ⚠️ `agent_memory.zig` có nhưng không có `/memory` command |
| `/permissions` interactive grant | ⚠️ Session grant có nhưng không có TUI command manage |
| Plan mode (read-only structured plan) | ✅ Plan mode có |
| Hooks (PreToolUse/PostToolUse/etc.) | ⚠️ On-save hooks có, agent hooks chưa |
| Headless mode (`claude -p`) | ⚠️ `--json --non-interactive`, chưa có `forge agent exec` |
| Web search built-in | ❌ Chỉ có `fetch_url` tool |

### vs Aider

| Killer feature | Forge status |
|---|---|
| `/architect /code /ask` mode | ✅ Ask/Plan/Agent mode parity đạt |
| Repo map (call-graph based context) | ⚠️ `import_graph` + RRF rerank, không Aider-style explicit |
| Light/dark themes thật | ❌ Chỉ toggle `use_color` |
| Auto-commit per-edit | ⚠️ `git` tools có, auto-commit chưa wire |

### vs Crush (Charm)

| Killer feature | Forge status |
|---|---|
| Bubble Tea architecture | ❌ Forge TUI custom raw-termios |
| Themes (lipstick palette system) | ❌ Only color toggle |
| Vim mode + mouse support | ❌ No vim, no mouse |

### vs gemini-cli

| Killer feature | Forge status |
|---|---|
| @mentions file completion (fuzzy) | ❌ `@file:path` parser, không fuzzy picker |
| MCP support | ✅ Parity đạt |
| Themes | ❌ Only color toggle |

### vs codex (OpenAI)

| Killer feature | Forge status |
|---|---|
| Approvals system | ✅ `every_time`/`review`/`automatic` parity đạt |
| Sandboxed execution (kernel-default) | ❌ **RELEASE BLOCKER** — chỉ snapshot isolation |
| `codex exec` headless CI | ⚠️ Tương đương nhưng `forge agent exec` chưa có |

### vs opencode (sst)

| Killer feature | Forge status |
|---|---|
| Diff accept/reject per-hunk | ❌ Chỉ whole-proposal apply/dismiss |
| LSP-style editor integration trong TUI | ❌ `packages/lsp` có, TUI không wire |

---

## 6. 12 unique advantages của Forge

| # | Unique advantage | Vì sao là advantage thật |
|---|---|---|
| A1 | Native Zig CPU rendering | 5-12ms/frame, ~100MB RSS, <1s startup; VSCode Electron 300-500MB |
| A2 | Transactional apply/undo với content-hash precondition + crash journal | Cursor agent ghi file trực tiếp không hash precondition |
| A3 | Inspectable context manifest + secret scanner + 3-tier budget | Cursor không cho user thấy context chi tiết |
| A4 | 3-surface kernel sharing (CLI/TUI/IDE) | Cursor CLI khác semantics IDE; Antigravity chỉ IDE; Claude Code chỉ CLI |
| A5 | Disposable snapshot repair trials | Cursor apply-then-restore failure mode |
| A6 | Command/event split + capability-scoped tool registry (defense-in-depth) | Defense-in-depth không competitor nào match |
| A7 | 7 providers + smart router (RFC-0016 DONE) | Đa dạng hơn Cursor (chỉ OpenAI/Anthropic) |
| A8 | MCP early adoption (stdio + HTTP) | Đã wire từ pre-alpha; TUI tools (Aider, Crush) chưa có MCP |
| A9 | Real eval harness (5 suites + provider comparison) | Hầu hết TUI tools có ZERO eval harness |
| A10 | Spec-driven CLI (forge spec) đầy đủ 11 subcommands | Chỉ Kiro có spec-driven first-class |
| A11 | Session resume + branching (CLI) | Antigravity có visual; Forge có CLI primitives đủ |
| A12 | `forge chat` REPL + @mentions (8 kinds) | Đa dạng hơn Claude Code (chỉ @file + @url) và Aider (chỉ /add /drop) |

---

## 7. Top 15 cải thiện ưu tiên

Bảng đầy đủ với cột Files ảnh hưởng / Effort / Priority / Risk — xem PDF mục 7.
Tóm tắt theo priority:

### P0 (5 items — Blockers & Foundation Fix)

1. **Fix Anthropic tool loop round-trip** (L) — rewrite `completeTurnImpl` pass
   structured messages[] với content blocks, parse `tool_use_id`, add SSE
   streaming.
2. **Enable live token streaming trong TUI** (M) — bỏ early-return trong
   `onStreamChunk`, track `stream_line_index` per-turn.
3. **Complete background agent primitives (wait/cancel/approve/reject)** (L) —
   impl wait/cancel/approve/reject via events.jsonl + SIGTERM + heartbeat
   zombie detection.
4. **OS sandbox backend (Seatbelt/Landlock)** (XL) — release blocker, impl
   `packages/workspace/src/sandbox.zig` trait + 20 safety trap fixtures.
5. **Fix Linux IDE build (IME callbacks)** (M) — impl XIM/XIC composition trong
   `x11_window.c`.

### P1 (4 items — Parity với Cursor/Kiro/Antigravity)

6. **IDE spec panel + agent hooks** (L) — impl `spec_panel.zig` (list + status
   badge + click-to-open), wire agent hooks inject spec vào context, enforce
   spec approval gate trong `agent.zig:run`.
7. **Agent timeline UI component** (L) — impl `timeline_view.zig` với horizontal
   step nodes, click expand detail, keyboard nav.
8. **Hunk-level diff accept/reject** (L) — extend `proposal.zig` với
   `apply_subset(file_indices, hunk_indices)`, add per-hunk keys in IDE/TUI.
9. **Wire filter_role/pinned/bookmarks/tags vào render** (S) — quick win, thêm
   conditional logic trong render loop.

### P2 (5 items — TUI/UX Polish)

10. **True theme palettes + vim mode** (M) — refactor `term.Style` thành
    function theo theme, add vim normal/insert/visual mode.
11. **@mention picker UI (fuzzy)** (M) — impl `mention_picker.zig` popup với
    fuzzy match (file + LSP symbol + spec + recent + git).
12. **Multi-file Composer IDE UX (Cmd+K)** (L) — extend `inline_edit.zig` với
    `composer_mode` + `composer_files[]`, wire `ComposerBatch` (đang orphan).
13. **Persistent session token ledger + cost dashboard** (S) — persist
    `usage.jsonl` per turn, add `forge cost` CLI + `/cost` TUI.
14. **File-watch incremental re-indexing** (M) — wire `watch.zig` vào
    `rag/index.zig`, incremental update on file change.

### P3 (1 item — Competitive Moats)

15. **Parallel tool execution + thinking-block parsing** (L) — batch independent
    tool calls (cap 4 threads), add thinking block parser trong Anthropic +
    OpenAI providers.

---

## 8. Lộ trình 4 phase

### Phase P0 — Blockers & Foundation Fix (4 tuần)

| Tuần | Item | RFC/Doc ref |
|---|---|---|
| 1-2 | Fix Anthropic tool loop round-trip | AI_FEATURE_AUDIT §2 |
| 1 | Enable live token streaming trong TUI | Task 6 finding |
| 2-3 | Complete background agent primitives | RFC-0015 |
| 2-4 | OS sandbox backend (Seatbelt/Landlock) | CAPABILITY_MATRIX #1 |
| 1 | Fix Linux IDE build (IME callbacks) | CAPABILITY_MATRIX #6 |

**Exit gate P0:**

- Anthropic Claude provider chạy agent mode end-to-end với `claude-sonnet-4-5`.
- TUI stream token live; 30-min session không crash; memory < 200MB.
- `forge agent run --background` + wait/cancel/approve/reject work; 3 concurrent
  runs không corrupt workspace.
- 20 safety trap fixtures pass với sandbox enabled.
- `zig build` green trên Linux X11.

### Phase P1 — Parity với Cursor/Kiro/Antigravity (6 tuần)

| Tuần | Item |
|---|---|
| 1-3 | IDE spec panel + agent hooks |
| 3-5 | Agent timeline UI component |
| 4-6 | Hunk-level diff accept/reject |
| 4-5 | Wire filter_role/pinned/bookmarks/tags vào render |
| 5-6 | Multi-file Composer IDE UX (Cmd+K) |

**Exit gate P1:**

- 5 specs implement end-to-end bằng Forge IDE.
- Timeline UI render tất cả step types; click expand; keyboard nav.
- Per-hunk accept/reject work; không phá transaction atomicity.
- Cmd+K Composer edit 3 files cùng lúc work.
- CLI vs IDE parity: cùng task → cùng transaction outcome.

### Phase P2 — TUI/UX Polish (6 tuần)

| Tuần | Item |
|---|---|
| 1-2 | True theme palettes + vim mode |
| 2-3 | @mention picker UI (fuzzy) |
| 3-4 | Persistent session token ledger + cost dashboard |
| 4-6 | File-watch incremental re-indexing |
| 5-6 | Mouse + kitty keyboard + SIGWINCH + bracketed-paste parsing |

**Exit gate P2:**

- 3 themes (dark/light/solarized) palette swap thật.
- Vim normal/insert/visual mode work.
- `@` trigger fuzzy picker, `↑↓` nav, `Enter` select.
- `forge cost` show cumulative session total ±5% vs provider bill.
- Warm `forge context @codebase` < 500ms (vs 3s hiện tại).
- Mouse click scroll + selection work; kitty keyboard parse tất cả modifier
  combos.

### Phase P3 — Competitive Moats (open-ended)

- Parallel tool execution + thinking-block parsing (#15)
- Skills system (`.forge/skills/<name>/SKILL.md` + frontmatter)
- Agent hooks (before_tool/after_tool/on_approval)
- `forge agent exec` headless CI
- Git worktree parallel agents
- Cloud sessions + sync (optional, cần security review)
- WASM extension marketplace + threat model
- GPU rendering (Metal/OpenGL/D3D11) + SDF text (RFC-0018)
- Web search provider integration
- Session search (full-text search final answers + proposals)
- Session export/import (share giữa developers)

---

## 9. Top 3 actions ngay (P0 week 1)

### Action 1: Fix Anthropic provider tool loop (2 ngày)

**Vì sao trước tiên:** Claude Sonnet 4.5 là model agentic coding tốt nhất hiện
nay. Không support đúng = mất 40% user base. Đây là **blocker kỹ thuật** chứ
không phải nice-to-have.

- Rewrite `providers/anthropic/provider.zig:completeTurnImpl` để pass structured
  `messages[]` array với content blocks (text/tool_use/tool_result).
- Impl `toolDeclarationsJsonImpl` trả về tools array từ `native_declarations_json`
  + MCP tools (hiện trả `"[]"`).
- Parse response `content` blocks cho `type: "tool_use"` → trả
  `Completion.tool_call`/`tool_calls` với `tool_use_id`.
- Add SSE streaming qua `/v1/messages` với `stream: true`, parse event stream
  `data:` blocks.
- Add round-trip test với fake Anthropic server (giống fake provider pattern)
  verify 5-turn tool use conversation.

### Action 2: Enable TUI live streaming (2-3 ngày)

**Vì sao trước tiên:** Đây là **UX baseline** cho mọi TUI competitor. Claude
Code, Aider, Crush, gemini-cli, codex, opencode — TẤT CẢ đều stream live. Forge
TUI hiện tại cảm giác "đơ" trong multi-step agent turn, khiến user tưởng agent
bị treo.

- Bỏ early-return `if (self.agent_busy) return;` trong `onStreamChunk`
  (`app.zig:4639`).
- Track `stream_line_index` per-turn (reset on `onStepBegin`/`turnBridge`).
- Tách "thinking text" khỏi "tool step" trong `self.lines` — thêm
  `LineKind.streaming` hoặc track `turn_boundaries` array.
- Add ringbuffer 4KB cho stream chunk, throttle render 60fps.
- Test 30-min continuous session không leak memory, render frame time < 16ms.

### Action 3: Implement background agent control plane (2-3 ngày)

**Vì sao trước tiên:** Background runs hiện dangerous (no cleanup khi crash).
RFC-0015 đã viết spec đầy đủ nhưng 4 functions (wait/cancel/approve/reject) là
stubs. Đây là **Antigravity parity blocker** — không có control plane = không
thể claim "background agents".

- Impl `runWait`: block on run record status poll, exit code mapping
  (0=done, 130=cancelled, 1=failed).
- Impl `runCancel`: send SIGTERM to background PID (persist PID trong run
  record), cleanup lock file.
- Impl `runApprove`/`runReject`: write `approval_granted`/`approval_rejected`
  event vào `events.jsonl`; agent loop polls approval events khi
  `approval_callback` pending.
- Add zombie detection: heartbeat stale 30s → mark run as "failed (zombie)" +
  cleanup.
- Add integration test: 3 concurrent background runs không corrupt workspace
  transaction state.

---

## 10. Tổng kết

Forge có **foundation vững nhất** trong nhóm pre-alpha (transaction safety,
3-surface kernel, eval harness, disposable trial workspace, MCP early adoption).
Nhưng đang bị kẹt ở giai đoạn **"wire-but-not-render"**: nhiều feature khai báo
trong code/docs nhưng chưa hoạt động hoặc chưa có UI.

5 gap P0 (Anthropic provider, TUI streaming, background control plane, OS
sandbox, Linux IDE build) cần fix **TRƯỚC** khi claim "Cursor 2 parity". Sau
P0, lộ trình P1 → P2 → P3 sẽ đưa Forge thành TUI coding tool mạnh nhất thị
trường, tận dụng 12 unique advantages đã có.

**Top 3 actions tuần đầu tiên:**

1. Fix Anthropic provider tool loop (P0, 2 ngày).
2. Enable TUI live streaming (P0, 2-3 ngày).
3. Implement background agent control plane (P0, 2-3 ngày).

---

## Tham chiếu

- [AI Workflow Evaluation](AI_WORKFLOW_EVALUATION.md)
- [AI Feature Audit 2026](AI_FEATURE_AUDIT_2026.md)
- [Cursor 2 Master Plan](../plan/FORGE_CURSOR2_MASTER_PLAN.md)
- [AI Flow Improvements](../plan/FORGE_AI_FLOW_IMPROVEMENTS.md)
- [CLI Cursor Roadmap](../plan/FORGE_CLI_CURSOR_ROADMAP.md)
- [Capability Matrix](../CAPABILITY_MATRIX.md)
- [Project Roadmap](../roadmap/ROADMAP.md)
- [RFC-0014: Spec-driven development](../rfc/RFC-0014-spec-driven-development.md)
- [RFC-0015: Agent timeline & background runs](../rfc/RFC-0015-agent-timeline-background-runs.md)
- [RFC-0016: Provider capability & smart router](../rfc/RFC-0016-provider-capability-smart-router.md)
- PDF đầy đủ: `Forge_TUI_AI_Flow_Analysis_2026-07-27.pdf`

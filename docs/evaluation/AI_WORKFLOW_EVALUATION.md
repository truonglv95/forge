# Forge AI Workflow Evaluation — Cursor / Kiro / Antigravity Gap Analysis

> Đánh giá toàn diện AI workflow hiện tại của Forge và lộ trình đưa Forge trở
> thành một IDE/CLI AI-first ngang tầm Cursor, Kiro và Antigravity.
>
> **Cập nhật:** 2026-07-24
> **Tác giả:** truonglv95
> **Tham chiếu:** [Capability Matrix](../CAPABILITY_MATRIX.md) ·
> [AI Flow Improvements](../plan/FORGE_AI_FLOW_IMPROVEMENTS.md) ·
> [Cursor 2 Master Plan](../plan/FORGE_CURSOR2_MASTER_PLAN.md)

---

## 1. Tóm tắt điều hành

Forge đã sở hữu "xương sống" của một AI IDE thật: transaction an toàn, agent
loop với tool registry có phân quyền, context engine có manifest, NDJSON event
stream, session persistence, và ba surfaces (CLI / TUI / IDE) dùng chung một
kernel. Đây là nền tảng vững hơn nhiều so với các IDE Electron ở cùng giai đoạn
pre-alpha.

Tuy nhiên, để ngang tầm Cursor / Kiro / Antigravity, Forge cần vượt **5 gap
chính**:

1. **Inline tab completion** chưa được wire vào IDE (code đã có ở
   `packages/ai/src/inline_completion.zig` nhưng Capability Matrix ghi "No").
2. **Spec-driven development** kiểu Kiro (specs → implementation → trace) mới
   dừng ở `forge spec` CLI, chưa có IDE UX và hooks vào agent.
3. **Agent timeline & background runs** kiểu Antigravity chưa có — agent chỉ
   chạy foreground, không có timeline visualization hay resume dài hạn.
4. **Multi-agent orchestration** (planner + reviewer + implementer) đã có
   subagent nhưng chưa có UI trực quan và contract rõ.
5. **Composer / multi-file inline edit** kiểu Cursor chưa có UX "edit files in
   place từ chat" — hiện mọi edit phải qua proposal review panel.

Phần còn lại của tài liệu này phân tích chi tiết từng gap, đối chiếu code hiện
tại, và đề xuất RFCs cùng implementation slices.

---

## 2. Phương pháp đánh giá

### 2.1. Tiêu chí so sánh

Đánh giá dựa trên 5 trục:

| Trục | Định nghĩa |
|---|---|
| **Safety** | Mọi thay đổi có thể undo, có audit trail, không bao giờ mất dữ liệu |
| **Observability** | User thấy được agent đang làm gì, context gì được gửi, token phí bao nhiêu |
| **Latency** | p50/p95 từ intent → kết quả; từ keystroke → suggestion |
| **Workflow coverage** | Tỷ lệ task class có thể hoàn thành end-to-end chỉ với Forge |
| **Surface parity** | CLI / TUI / IDE cho cùng outcome trên cùng task |

### 2.2. Benchmark reference

| Sản phẩm | Điểm mạnh | Điểm yếu |
|---|---|---|
| **Cursor** | Inline tab completion nhanh, Composer multi-file, @ mentions, .cursorrules | Electron; agent ghi file trực tiếp; không có inspectable context; CLI tách biệt IDE |
| **Kiro** | Spec-driven (specs → impl → hooks); agentic IDE với audit; multi-agent | Mới, community nhỏ; perf chưa tối ưu; ít provider |
| **Antigravity** | Agent timeline trực quan; background runs; multi-agent UI | Closed ecosystem; chỉ Android-focused; không có CLI parity |
| **Forge (target)** | Native Zig; transaction safety; CLI/IDE parity; inspectable context | Cần inline completion, Kiro-style specs, Antigravity-style timeline |

---

## 3. Đánh giá chi tiết theo khu vực

### 3.1. Agent Loop & Tool Registry — ĐÁNH GIÁ: TỐT (8/10)

**Code hiện tại:**
- `packages/ai/src/agent/loop.zig` — 1191 dòng, provider-agnostic tool loop
- `packages/ai/src/tools/registry.zig` — 22 native tools + MCP adapter
- `packages/ai/src/agent_event.zig` — 15 event types, schema_version=1
- Loop guard chống duplicate tool call (window=32, hash-based)
- Task ledger với AgentState, compaction khi quá budget
- Cancellation token propagate qua model stream + child processes

**Điểm mạnh:**
- Tool policy có 3 cấp: `automatic`, `review`, `every_time` — đúng hướng
  Cursor/Kiro.
- Capability profiles (`read_only` / `propose` / `propose_and_task`) tách biệt
  mode và quyền — an toàn hơn Cursor.
- 22 native tools bao gồm: `read_file`, `search`, `codebase_search`,
  `replace_file_content`, `multi_edit`, `lsp_*`, `git_*`,
  `spawn_subagent`, `get_editor_context` — coverage tốt.
- Subagent support (`spawn_subagent`) với 4 role: `repair_log_reader`,
  `repair_test_writer`, `planner`, `reviewer` — đúng hướng multi-agent.

**Điểm yếu cần khắc phục:**
1. **Loop guard chỉ hash trên (tool_name, args_json)** — không phát hiện
   "semantic duplicate" (cùng query khác whitespace, cùng path khác format).
2. **Không có tool call reason field** — doc AI Flow Improvements đã nêu
   (AI-FLOW-007) nhưng chưa thấy implement.
3. **`max_tool_steps` default = 6** trong loop.zig nhưng agent.zig default =
   128 — không nhất quán, dễ gây confusion.
4. **Không có step-level scoring** — không đo "tool sequence hợp lý" tự động.
5. **Subagent output không stream** — chỉ trả text cuối, không có event
   per-step cho subagent (chỉ `subagent_started` + `subagent_result`).

**Khuyến nghị:**
- Thêm `reason` field vào ToolCall event (RFC-0013).
- Semantic duplicate detection: normalize args trước khi hash (RFC-0014).
- Stream subagent events: `subagent_tool_call`, `subagent_tool_result`,
  `subagent_llm_turn`.
- Step scoring eval: fixture tasks với rubric "tool sequence hợp lý".

### 3.2. Context Engine — ĐÁNH GIÁ: KHÁ (7/10)

**Code hiện tại:**
- `packages/ai/src/context.zig` — ContextBuilder với blocks
- `packages/ai/src/context_manifest.zig` — manifest có items, budget, sources
- `packages/ai/src/context_budget.zig` — BudgetTier (full / compact / minimal)
- `packages/ai/src/codebase_search.zig` — semantic search với embeddings
- `packages/ai/src/context_retrieval.zig` + `context_rerank.zig` — retrieval
  pipeline với reranking
- `packages/ai/src/context_expander.zig` — adaptive context expansion
- `packages/ai/src/secret_scanner.zig` — redaction trước khi gửi model
- Adaptive budget theo tier, HoF (HyDE) support

**Điểm mạnh:**
- Manifest inspectable qua `forge context` command — đây là điểm Forge hơn
  Cursor (Cursor không cho user thấy context chi tiết).
- Hybrid retrieval: semantic + lexical + tree + AST chunker.
- Secret scanner có patterns cho `.env`, API keys, tokens.
- Adaptive budget: tự giảm tier khi gần full.
- HoF (Hypothesis of Fact) enable qua config.

**Điểm yếu:**
1. **Context manifest chưa expose qua IDE panel** — doc nói có Context
   Inspector UI nhưng chưa rõ wire vào agent run.
2. **Không có `@file` mention parsing trong chat** — Cursor có `@file`,
   `@symbol`, `@web`, `@docs`; Forge chỉ có `--file` flag CLI.
3. **Không có `@web` hoặc `@docs` retrieval** — chỉ có `fetch_url` tool, không
   có RAG over external docs.
4. **AST chunker chỉ support Python, TypeScript, TSX** — thiếu Zig, Rust, Go,
   Java, C/C++ parsers (đã có third_party nhưng chưa wire).
5. **Không có context "memory" persistent qua session** — `agent_memory.zig`
   có nhưng chưa rõ integration vào context engine.

**Khuyến nghị:**
- Wire Context Inspector UI vào agent panel (RFC-0015).
- Implement `@mention` parser trong chat input: `@file:path`,
  `@symbol:name`, `@web:query`, `@docs:query`.
- Thêm Zig/Rust/Go tree-sitter parsers vào parser catalog.
- Persistent agent memory qua `forge.toml` `[ai.memory]` section.

### 3.3. Proposal & Transaction — ĐÁNH GIÁ: XUẤT SẮC (9/10)

**Code hiện tại:**
- `packages/workspace/src/transaction.zig` — atomic apply/undo
- `packages/workspace/src/proposal.zig` — proposal schema + validation
- `packages/workspace/src/atomic.zig` — atomic file operations
- `packages/workspace/src/checkpoint.zig` — recovery journal
- `packages/workspace/src/history.zig` — `.forge/history.jsonl`
- `packages/workspace/src/recovery.zig` — crash recovery
- Content precondition (hash) cho mọi mutation
- `forge apply --dry-run`, `forge undo <id>`, `forge history`

**Điểm mạnh:**
- Đây là **lợi thế cạnh tranh lớn nhất** của Forge vs Cursor. Cursor agent ghi
  file trực tiếp, không có hash precondition, không có undo toàn vẹn.
- Multi-file atomic: tất cả edits apply cùng lúc hoặc không edit nào.
- Stale hash rejection: nếu file thay đổi giữa read và apply, reject.
- Crash recovery: `.forge/` journal có thể replay.
- CLI parity: `forge apply` CLI = IDE apply button về semantics.

**Điểm yếu:**
1. **Không có partial apply (per-hunk approve)** — RFC-0009 đề cập nhưng chưa
   thấy implement. Cursor cho accept/reject per-hunk.
2. **Conflict UI trong IDE chưa hoàn thiện** — Capability Matrix ghi "IDE
   conflict UI" là gap.
3. **Không có "diff snapshot" để compare nhiều proposals** — user phải apply
   từng cái một.

**Khuyến nghị:**
- Implement partial apply qua RFC-0009 (per-hunk accept/reject).
- Conflict resolver UI trong IDE (đã có `conflict_resolver.zig` workbench).
- Proposal diff cache: `.forge/proposals/<id>.diff` để compare nhanh.

### 3.4. Provider Layer — ĐÁNH GIÁ: KHÁ (7/10)

**Code hiện tại:**
- `packages/ai/src/providers/gemini/` — Gemini với SSE, tool transport, embedder
- `packages/ai/src/providers/ollama/` — local models với NDJSON
- `packages/ai/src/providers/openrouter/` — multi-model gateway
- `packages/ai/src/providers/openai/` — OpenAI compat
- `packages/ai/src/providers/nvidia/` — NIM endpoints
- `packages/ai/src/providers/fake/` — deterministic test provider
- `packages/ai/src/provider_failover.zig` — failover chain
- `packages/ai/src/credentials.zig` — keychain integration
- Error taxonomy: `AuthenticationFailed`, `RateLimitExceeded`,
  `ContextLengthExceeded`, `NetworkError`, `MalformedResponse`

**Điểm mạnh:**
- 6 providers + fake cho test — đa dạng hơn Cursor (chỉ OpenAI/Anthropic).
- Failover chain: nếu Gemini rate limit, tự switch sang OpenRouter.
- Error taxonomy chuẩn hóa, có `retryable` flag.
- Credentials qua keychain (macOS) — không bao giờ log.

**Điểm yếu:**
1. **Không có Anthropic Claude provider** — Cursor có, Kiro có. Đây là gap
   lớn vì Claude 3.5/4 Sonnet là model mạnh cho coding.
2. **Không có provider capability metadata** — doc AI-FLOW-014 đề cập nhưng
   chưa implement. Agent không biết provider nào support native tool calls,
   streaming, structured output.
3. **Không có model router thông minh** — hiện `route_resolver.zig` chỉ route
   theo task intent, không route theo model capability.
4. **Retry/backoff chưa có jitter** — chỉ exponential, dễ thundering herd.

**Khuyến nghị:**
- Thêm Anthropic Claude provider (RFC-0016).
- Provider capability struct: `max_context`, `supports_tools`,
  `supports_streaming`, `supports_structured_output`, `returns_usage`.
- Smart model router: task → required capabilities → eligible models →
  cheapest/fastest.
- Retry với jitter: `delay = base * 2^attempt + random(0, base)`.

### 3.5. CLI Workflow — ĐÁNH GIÁ: TỐT (8/10)

**Code hiện tại:**
- 24 subcommands: `version`, `doctor`, `inspect`, `search`, `watch`, `diff`,
  `apply`, `undo`, `history`, `task`, `check`, `index`, `context`, `ask`,
  `run`, `agent`, `plan`, `parsers`, `eval`, `ecosystem`, `ext`, `spec`,
  `help`
- `forge agent run --events ndjson` cho headless streaming
- `forge agent resume` cho session resume
- `forge spec create|list|show|edit|approve|reject|implement|trace` —
  spec-driven workflow
- `--json` cho mọi command, `--non-interactive` cho CI

**Điểm mạnh:**
- CLI parity với IDE về semantics — đây là điểm Forge hơn Cursor (Cursor CLI
  là "agent only", không có inspect/diff/apply/undo workflow).
- `forge spec` đã có workflow đủ cho Kiro-style spec-driven.
- `forge eval ai-flow` cho benchmark.
- `forge ecosystem` manage tools/context/packs/providers.

**Điểm yếu:**
1. **Không có `forge chat` interactive REPL** — phải dùng TUI app. Cursor CLI
   có `cursor chat`.
2. **`forge agent run` không support `--resume <session_id>` flag** — phải
   dùng `forge agent resume` subcommand riêng.
3. **Không có `forge complete` cho inline completion** — user không thể test
   inline completion từ CLI.
4. **TUI chưa hoàn thiện** — doc nói "cần hoàn thiện review/expand/session".

**Khuyến nghị:**
- Thêm `forge chat` interactive REPL (RFC-0017).
- Unify `agent run` + `agent resume` thành `agent run --resume <id>`.
- Thêm `forge complete --file <path> --line <n> --char <n>` cho inline.
- Hoàn thiện TUI: expand/collapse tool result, diff snippet, resume.

### 3.6. IDE Surface — ĐÁNH GIÁ: KHÁ (7/10)

**Code hiện tại:**
- `apps/forge-ide/` — native Zig IDE với:
  - Activity bar, sidebar (explorer, search, git, debug, extensions, AI)
  - Editor với tabs, breadcrumbs, syntax, inlay hints, bracket match
  - Agent panel (chat_viewport, chat_bubble, tool_step_card, metrics)
  - Context inspector, diff review panel, proposal review
  - Terminal panel, problems panel, output channel
  - LSP controller, debug controller (LLDB/DAP)
  - Git controller, command palette, settings modal
  - Extensions (WASM), keybindings, theme loader
- `apps/forge-ide/src/workbench/` — 60+ controllers cho mọi feature
- Inline edit, ghost completion (file exists nhưng chưa wire)

**Điểm mạnh:**
- Native Zig, không Electron — perf tốt hơn theo design.
- Layout chuẩn IDE (activity bar + sidebar + editor + panel + status bar).
- Agent panel đã có chat bubble + tool step card + metrics.
- Context inspector đã có UI.
- Diff review panel đã có.

**Điểm yếu:**
1. **Inline tab completion chưa wire** — `ghost_completion.zig` workbench
   exists nhưng không thấy gọi `inline_completion.complete()`.
2. **Agent timeline UI chưa có** — Antigravity có timeline view của agent
   steps, Forge chỉ có tool_step_card list.
3. **Composer / multi-file edit từ chat chưa có** — Cursor có "Cmd+K" inline
   edit + Composer multi-file; Forge phải qua proposal review.
4. **Background runs chưa có** — agent chỉ chạy foreground, không có
   "continue in background" như Antigravity.
5. **Multi-agent UI chưa có** — subagent chạy ẩn, không có visualization.
6. **`@mention` picker chưa wire** — `mention_picker.zig` exists nhưng chưa
   rõ integration với chat input.

**Khuyến nghị:**
- Wire inline completion: keystroke → debounce → `inline_completion.complete()`
  → ghost text → Tab to accept (RFC-0013).
- Agent timeline: horizontal timeline với step nodes, click để expand.
- Composer mode: Cmd+K mở inline edit, multi-file selection → propose.
- Background runs: `forge agent run --background` + IDE notification.
- Multi-agent panel: planner/reviewer/implementer cards song song.

### 3.7. Session & Persistence — ĐÁNH GIÁ: TỐT (8/10)

**Code hiện tại:**
- `packages/workspace/src/sessions.zig` — session store
- `packages/ai/src/agent/session_docs.zig` — session docs
- Append-only event log trong `.forge/sessions/<id>/events.jsonl`
- Resume khôi phục conversation, task ledger, pending tool
- `forge agent sessions` list, `forge agent resume <id>`

**Điểm mạnh:**
- Append-only event log — correct by construction.
- Resume khôi phục đủ state: conversation + task_ledger + pending_tool.
- Session docs đi kèm (proposal, validation, final answer).

**Điểm yếu:**
1. **Không có session branching** — không thể fork một session để thử path
   khác (Cursor có feature này).
2. **Không có session export/import** — không share session giữa developer.
3. **Không có session search** — không tìm "session nào đã fix bug X".

**Khuyến nghị:**
- Session branching: `forge agent branch <id>` tạo session mới từ checkpoint.
- Session export: `forge agent export <id> > session.json`.
- Session search: `forge agent search "fix bug X"` full-text search qua
  final answers + proposals.

### 3.8. Evaluation & Metrics — ĐÁNH GIÁ: KHÁ (7/10)

**Code hiện tại:**
- `fixtures/eval/` — 7 eval suites (agent_reliability, long_tasks,
  multi_file_edits, validation_repair, retrieval_context, zig_real_agent,
  agent_reliability_extended)
- `scripts/eval_*.sh` — eval runners
- `apps/forge-cli/src/eval_ai_flow.zig` — `forge eval ai-flow`
- `apps/forge-cli/src/eval_summary.zig` — summary report
- `docs/evaluation/AI_RELIABILITY.md` + `SEMANTIC_SEARCH.md`

**Điểm mạnh:**
- 7 eval suites với fixtures — coverage tốt.
- `forge eval ai-flow` có `--baseline` compare, `--min-success-rate` gate.
- AI reliability doc có rubric.

**Điểm yếu:**
1. **Không có inline completion eval** — không benchmark suggestion quality.
2. **Không có latency p50/p95 report** — chỉ success rate.
3. **Không có provider comparison** — không benchmark Gemini vs Ollama vs
   OpenRouter trên cùng task.
4. **Không có token cost tracking** — không biết task tốn bao nhiêu token.

**Khuyến nghị:**
- Inline completion eval: fixture files với cursor positions, benchmark
  exact-match + semantic-match.
- Latency histogram trong eval summary.
- Provider comparison mode: `forge eval ai-flow --providers gemini,ollama`.
- Token cost tracking: `usage.input_tokens * price + output_tokens * price`.

---

## 4. Gap Analysis vs Cursor / Kiro / Antigravity

### 4.1. vs Cursor

| Capability | Cursor | Forge hiện tại | Gap |
|---|:---:|:---:|---|
| Inline tab completion | ✅ Fast | ❌ Code có, chưa wire | **P0** — wire `inline_completion.zig` vào IDE |
| Composer multi-file edit | ✅ Cmd+K | ⚠️ Có proposal, chưa có UX | P1 — Composer mode trong IDE |
| @ mentions (@file, @symbol, @web) | ✅ | ⚠️ Chỉ `--file` CLI | P1 — Mention picker + parser |
| .cursorrules | ✅ | ✅ FORGE.md + forge.toml | parity đạt |
| Chat panel | ✅ | ✅ Agent panel | parity đạt |
| Agent multi-step | ✅ | ✅ Agent loop | parity đạt |
| Diff review | ✅ Inline | ✅ Proposal review | parity đạt (UX khác) |
| Apply / Undo | ⚠️ Partial | ✅ Transaction atomic | **Forge hơn Cursor** |
| Inspectable context | ❌ | ✅ `forge context` | **Forge hơn Cursor** |
| CLI parity với IDE | ❌ CLI khác IDE | ✅ Cùng schema | **Forge hơn Cursor** |
| Native perf | ❌ Electron | ✅ Zig native | **Forge hơn Cursor** |
| Background agents | ✅ Cloud | ❌ Chưa có | P2 — Background runs |
| Extension ecosystem | ✅ VSCode | ⚠️ WASM experimental | P3 — Threat model + marketplace |

**Kết luận vs Cursor:** Forge cần **P0: inline completion**, **P1: Composer +
@mentions**, còn lại đã ngang hoặc hơn.

### 4.2. vs Kiro

| Capability | Kiro | Forge hiện tại | Gap |
|---|:---:|:---:|---|
| Spec-driven (specs → impl → hooks) | ✅ First-class | ⚠️ `forge spec` CLI | P1 — IDE UX + agent hooks |
| Spec templates | ✅ | ❌ Không có | P1 — Spec templates |
| Spec validation hooks | ✅ Pre-commit | ❌ Không có | P1 — Hook vào `forge check` |
| Spec trace (req → code → test) | ✅ | ⚠️ `forge spec trace` | parity đạt (CLI) |
| Multi-agent (planner + reviewer) | ✅ | ⚠️ subagent support | P1 — UI + contract |
| Audit trail | ✅ | ✅ `.forge/` journal | parity đạt |
| Steering files (specs/, .kiro/) | ✅ | ⚠️ FORGE.md only | P1 — Spec directory convention |

**Kết luận vs Kiro:** Forge cần **P1: spec-driven IDE UX + hooks + templates**,
đây là gap lớn nhất về product positioning.

### 4.3. vs Antigravity

| Capability | Antigravity | Forge hiện tại | Gap |
|---|:---:|:---:|---|
| Agent timeline UI | ✅ Visual | ❌ List only | P1 — Timeline component |
| Background runs | ✅ Long-running | ❌ Foreground only | P1 — Background agent runtime |
| Multi-agent visualization | ✅ Parallel cards | ⚠️ subagent events | P1 — Multi-agent panel |
| Resume long tasks | ✅ | ✅ `forge agent resume` | parity đạt |
| Session history sidebar | ✅ | ✅ Session sidebar | parity đạt |
| Android-focused | ✅ | ❌ Desktop only | Out of scope |
| Cloud sync | ✅ | ❌ Local only | P3 — Optional cloud sync |

**Kết luận vs Antigravity:** Forge cần **P1: agent timeline + background runs +
multi-agent UI**, đây là gap về visual orchestration.

---

## 5. RFCs đề xuất

Dựa trên gap analysis, đề xuất 4 RFCs mới:

### RFC-0013: Inline Tab Completion v1
**Mục tiêu:** Wire `inline_completion.zig` vào IDE, thêm `forge complete` CLI.
**Scope:**
- Debounce 150ms sau keystroke
- Ghost text rendering trong editor
- Tab to accept, Esc to dismiss
- Multi-line completion support
- Config: `forge.toml [ai.inline] enabled, debounce_ms, max_tokens, min_prefix_chars`
**Exit gate:** p50 suggestion < 500ms, p95 < 1500ms, acceptance rate > 20%.

### RFC-0014: Kiro-style Spec-Driven Development
**Mục tiêu:** Đưa `forge spec` thành first-class workflow trong IDE.
**Scope:**
- `specs/` directory convention (như Kiro `.kiro/specs/`)
- Spec templates: feature, bugfix, refactor, spike
- Spec validation hooks: `forge check` chạy spec validation
- Agent hooks: agent đọc specs trước khi propose
- IDE: spec editor, spec list panel, spec trace view
- `forge spec implement <id>` → agent propose từ spec
**Exit gate:** 5 specs được implement end-to-end bằng Forge.

### RFC-0015: Agent Timeline & Background Runs
**Mục tiêu:** Antigravity-style agent orchestration.
**Scope:**
- Timeline UI component: horizontal, step nodes, click expand
- Background agent runtime: `forge agent run --background`
- Notification system: toast khi agent done/failed/needs approval
- Multi-agent panel: planner/reviewer/implementer cards song song
- Session branching: fork session tại step
**Exit gate:** 3 background runs song song không corrupt workspace.

### RFC-0016: Provider Capability Metadata & Smart Router
**Mục tiêu:** Agent biết provider/model capability, auto-route theo task.
**Scope:**
- Provider capability struct: `max_context`, `supports_tools`,
  `supports_streaming`, `supports_structured_output`, `returns_usage`,
  `price_per_mtok_input`, `price_per_mtok_output`
- `forge providers list --json` trả capability
- Smart router: task → required capabilities → eligible models → cheapest
- Anthropic Claude provider (RFC-0016 appendix)
- Retry với jitter
**Exit gate:** `forge providers list --json` đúng capability cho 6 providers.

### RFC-0017: CLI Chat REPL & Mentions (bonus)
**Mục tiêu:** `forge chat` interactive REPL với @mentions.
**Scope:**
- `forge chat` — interactive REPL với history
- `@file:path`, `@symbol:name`, `@web:query`, `@docs:query` parsing
- `/context`, `/resume <id>`, `/mode ask|plan|agent`, `/capability` commands
- Streaming output với token counter
**Exit gate:** 30 phút continuous chat session không crash.

---

## 6. Lộ trình triển khai đề xuất

### Phase 7 (M7) — Cursor Parity (4-6 tuần)

| Tuần | Work item | RFC |
|---|---|---|
| 1-2 | Wire inline completion vào IDE | RFC-0013 |
| 1-2 | `forge complete` CLI | RFC-0013 |
| 3 | Composer mode (Cmd+K inline edit) | — |
| 3 | @mention parser + picker | RFC-0017 |
| 4 | `forge chat` REPL | RFC-0017 |
| 5-6 | Polish + eval + dogfood | — |

**Exit gate:** Cursor parity đạt cho inline completion, Composer, @mentions,
chat REPL. Forge hơn Cursor ở safety + observability + CLI parity.

### Phase 8 (M8) — Kiro Parity (4-5 tuần)

| Tuần | Work item | RFC |
|---|---|---|
| 1 | `specs/` directory convention + templates | RFC-0014 |
| 1-2 | Spec validation hooks vào `forge check` | RFC-0014 |
| 2-3 | Agent hooks: agent đọc specs trước propose | RFC-0014 |
| 3-4 | IDE: spec editor, list panel, trace view | RFC-0014 |
| 4-5 | `forge spec implement <id>` end-to-end | RFC-0014 |

**Exit gate:** Kiro parity đạt cho spec-driven workflow. Forge hơn Kiro ở
native perf + CLI parity + transaction safety.

### Phase 9 (M9) — Antigravity Parity (5-7 tuần)

| Tuần | Work item | RFC |
|---|---|---|
| 1-2 | Agent timeline UI component | RFC-0015 |
| 2-3 | Background agent runtime | RFC-0015 |
| 3 | Notification system | RFC-0015 |
| 4-5 | Multi-agent panel | RFC-0015 |
| 5-6 | Session branching | RFC-0015 |
| 6-7 | Polish + eval + dogfood | — |

**Exit gate:** Antigravity parity đạt cho timeline + background + multi-agent.
Forge hơn Antigravity ở desktop focus + CLI parity + transaction safety.

### Phase 10 (M10) — Provider Hardening (3-4 tuần, song song)

| Tuần | Work item | RFC |
|---|---|---|
| 1 | Provider capability metadata | RFC-0016 |
| 1-2 | Smart model router | RFC-0016 |
| 2-3 | Anthropic Claude provider | RFC-0016 |
| 3-4 | Retry với jitter + failover polish | RFC-0016 |

---

## 7. Định nghĩa "Forge = Cursor + Kiro + Antigravity"

Forge đạt parity ngang tầm ba đối thủ khi:

1. **Cursor parity:** Inline tab completion < 500ms p50, Composer multi-file,
   @mentions, chat REPL.
2. **Kiro parity:** Spec-driven workflow end-to-end trong IDE, agent hooks vào
   specs, spec validation trong `forge check`.
3. **Antigravity parity:** Agent timeline UI, background runs, multi-agent
   visualization, session branching.
4. **Forge advantage (giữ):** Transaction safety, inspectable context, CLI/IDE
   parity, native Zig perf.
5. **Dogfood:** Team ship code Forge bằng Forge ≥80% thời gian, bao gồm cả
   spec-driven tasks và background agent tasks.

---

## 8. Rủi ro và cách giảm

| Rủi ro | Khả năng | Tác động | Giảm |
|---|:---:|:---:|---|
| Inline completion latency quá cao | Cao | Cao | Debounce + cache + provider có streaming + fallback local model |
| Spec directory convention xung đột `.kiro/` | Thấp | Thấp | Support cả `specs/` và `.kiro/specs/` |
| Background run crash workspace | Trung bình | Cao | Transaction isolation + snapshot + crash recovery (đã có) |
| Multi-agent coordination deadloop | Trung bình | Trung bình | Step limit per agent + global step limit + loop guard |
| Provider capability metadata sai | Thấp | Trung bình | Manual verify + community update + override qua `forge.toml` |
| Scope creep | Cao | Cao | Phases có exit gate, không sang phase sau nếu chưa pass |

---

## 9. Metrics tracking

Mỗi phase cần track:

| Metric | Baseline | Target M7 | Target M8 | Target M9 |
|---|---|---|---|---|
| Inline completion p50 latency | N/A | < 500ms | < 400ms | < 300ms |
| Inline completion acceptance rate | N/A | > 20% | > 30% | > 40% |
| Spec-driven task success rate | N/A | N/A | > 80% | > 90% |
| Background run success rate | N/A | N/A | N/A | > 95% |
| Multi-agent task success rate | N/A | N/A | N/A | > 75% |
| CLI/IDE parity discrepancy | partial | 0 | 0 | 0 |
| Dogfood task success rate | partial | > 60% | > 70% | > 80% |

---

## 10. Bước tiếp theo (action items ngay)

| Ưu tiên | Action | Owner | RFC |
|---|---|---|---|
| P0 | Wire `inline_completion.zig` vào IDE ghost text | IDE team | RFC-0013 |
| P0 | Thêm `forge complete` CLI | CLI team | RFC-0013 |
| P0 | Viết RFC-0013 (inline completion) | Architect | RFC-0013 |
| P1 | Viết RFC-0014 (Kiro-style specs) | Architect | RFC-0014 |
| P1 | Implement `specs/` convention + templates | Workspace team | RFC-0014 |
| P1 | Viết RFC-0015 (timeline + background) | Architect | RFC-0015 |
| P1 | Agent timeline UI prototype | IDE team | RFC-0015 |
| P2 | Viết RFC-0016 (provider capability) | AI team | RFC-0016 |
| P2 | Provider capability struct + `forge providers list` | AI team | RFC-0016 |
| P2 | Viết RFC-0017 (CLI chat REPL) | CLI team | RFC-0017 |

---

## 11. Phụ lục: Code audit summary

### 11.1. Files audit

| File | LOC | Đánh giá |
|---|---|---|
| `packages/ai/src/agent.zig` | 1580 | Tốt, cần doc improvement |
| `packages/ai/src/agent/loop.zig` | 1191 | Tốt, cần semantic dup detection |
| `packages/ai/src/agent_event.zig` | 167 | Tốt, schema ổn định |
| `packages/ai/src/tools/registry.zig` | 186 | Tốt, cần `reason` field |
| `packages/ai/src/inline_completion.zig` | 197 | Tốt, cần wire vào IDE |
| `packages/ai/src/context.zig` | — | Tốt, cần IDE panel |
| `packages/workspace/src/transaction.zig` | — | Xuất sắc |
| `packages/workspace/src/proposal.zig` | — | Tốt, cần partial apply |
| `apps/forge-cli/src/main.zig` | 425 | Tốt, cần `chat` + `complete` |
| `apps/forge-ide/src/workbench/ghost_completion.zig` | — | Stub, cần wire |

### 11.2. Test coverage audit

| Khu vực | Test status | Gap |
|---|---|---|
| Transaction apply/undo | ✅ Verified | Power-loss soak |
| Agent loop | ✅ Verified | Step scoring eval |
| Tool registry | ✅ Verified | MCP tool policy |
| Provider fake | ✅ Verified | Live provider suite |
| Inline completion | ✅ Unit test | Integration test thiếu |
| Context manifest | ✅ Partial | Adversarial corpus |
| Spec workflow | ✅ Partial | End-to-end IDE test |
| Session resume | ✅ Verified | Branch test |

---

## 12. Kết luận

Forge là một codebase trưởng thành với nền tảng vững chắc. Để đạt parity với
Cursor / Kiro / Antigravity, Forge cần **4 phases** (M7-M10) với **5 RFCs mới**,
tập trung vào:

1. **Inline completion** (Cursor parity) — P0, code đã có, chỉ cần wire.
2. **Spec-driven IDE UX** (Kiro parity) — P1, CLI đã có, cần IDE + hooks.
3. **Agent timeline + background** (Antigravity parity) — P1, cần mới.
4. **Provider capability** (cross-cutting) — P2, cần metadata + router.
5. **CLI chat REPL** (Cursor parity) — P2, cần mới.

Với lợi thế **transaction safety + inspectable context + CLI/IDE parity + native
perf**, Forge có tiềm năng vượt cả ba đối thủ nếu thực hiện đúng roadmap. Tài
liệu này là foundation cho các RFCs tiếp theo.

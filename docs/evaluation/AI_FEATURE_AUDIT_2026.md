# Forge AI Feature Audit — Comprehensive Inventory

> **Ngày:** 2026-07-26
> **Tác giả:** truonglv95 (audited via automated codebase scan)
> **Mục tiêu:** Đánh giá toàn diện tất cả AI features của Forge, đối chiếu
> với Cursor / Kiro / Antigravity, xác định gaps cần ưu tiên.

## 1. Tóm tắt điều hành

Forge là một **AI codebase CLI-first trưởng thành** với nền tảng
safety/observability mạnh hơn Cursor/Kiro/Antigravity ở cùng giai đoạn.
Lớp transactional apply/undo (`packages/workspace/src/transaction.zig`),
inspectable context manifest, append-only event log, và 3-surface kernel
sharing (CLI / TUI / IDE) là lợi thế cạnh tranh thực sự.

**Overall readiness score: 7.0 / 10**

Phân tích:
- Foundation (agent loop, tool registry, transaction, providers, MCP,
  context engine): **9/10** — production-grade.
- Cursor parity (inline completion, Composer, @mentions, chat REPL):
  **8/10** — inline completion ĐÃ wire (eval doc cũ đã stale); IDE
  multi-file Composer UX còn thiếu.
- Kiro parity (spec-driven dev): **5/10** — CLI complete, IDE UX gần
  như thiếu hoàn toàn.
- Antigravity parity (timeline, background runs, multi-agent): **5/10**
  — CLI complete, IDE mostly missing; timeline chỉ là 3-dot static card.
- Code review & test generation: **3/10** — heuristic stubs only, chưa
  LLM-wire.

**Key discovery (vs eval doc cũ):** `docs/evaluation/AI_WORKFLOW_EVALUATION.md`
cho rằng inline completion "chưa wire" và Anthropic Claude "Không có".
Cả hai đều **stale**: `ghost_completion.zig:309` gọi
`ai.inline_completion.complete(...)` và
`providers/anthropic/provider.zig:14` ships `claude-sonnet-4-5`.

## 2. Feature Inventory

| # | Feature | Category | Status | Key file(s) | Cursor/Kiro/Antigravity equiv | Gap |
|---|---|---|---|---|---|---|
| 1 | Agent loop + tool registry | Agent | COMPLETE | `packages/ai/src/agent/loop.zig` (1191 LOC), `tools/registry.zig` (22 native tools + MCP adapter) | Cursor agent loop | **Forge stronger** (transactional + per-tool approval policy) |
| 2 | Inline tab completion (ghost text) | Inline | COMPLETE (wired) | `packages/ai/src/inline_completion.zig` (474 LOC), `apps/forge-ide/src/workbench/ghost_completion.zig` (532 LOC, calls `ai.inline_completion.complete()` at line 309) | Cursor Tab | Eval doc stale; latency benchmarks missing |
| 3 | Multi-file Composer / inline edit | Inline | PARTIAL | `packages/ai/src/multi_file_edit.zig` (211 LOC, `ComposerBatch`), `apps/forge-cli/src/edit_cmd.zig` (141 LOC), `apps/forge-ide/src/workbench/inline_edit.zig` (200 LOC) | Cursor Cmd+K + Composer | CLI ✓; IDE inline_edit single-file only; no IDE multi-file picker |
| 4 | Spec-driven development | Spec | PARTIAL | `packages/ai/src/spec_writer.zig` (494 LOC), `apps/forge-cli/src/spec_cmd.zig` (759 LOC: init/template/create/list/show/edit/approve/reject/implement/trace/validate) | Kiro `.kiro/specs/` | CLI ✓; IDE only `agent_approve_spec` command; no spec panel/editor/list |
| 5 | Agent timeline & background runs | Agent | PARTIAL | CLI: `apps/forge-cli/src/agent_cmd.zig` (1003 LOC, `runBackground` at 801); IDE: only 3-dot static card at `ui/render/sidebar/ai.zig` | Antigravity timeline + background | CLI mostly done; IDE NO background run UI; timeline decorative |
| 6 | RAG / semantic search / codebase index | RAG | COMPLETE | `packages/ai/src/codebase_search.zig` (884 LOC), `rag/index.zig` (324 LOC), `context_rerank.zig` (441 LOC, RRF + signals), Tree-sitter pinned | Cursor codebase index | **Forge stronger** (inspectable manifest, RRF fusion, AST chunker) |
| 7 | Code review | Review | STUB | `packages/ai/src/code_review.zig` (215 LOC, heuristic regex only — secret leaks, TODOs) | Cursor review / Copilot review | No `forge review` CLI; no IDE review panel; not LLM-wired |
| 8 | Test generation | Test | STUB | `packages/ai/src/test_gen.zig` (124 LOC, generates TODO scaffolds); LLM test writing only via `subagent.zig:69` `repair_test_writer` | Cursor test gen / Copilot | No standalone `forge test gen`; no IDE integration |
| 9 | Intent classification | Agent | COMPLETE | `packages/ai/src/intent_classifier.zig` (232 LOC, heuristic + LLM with confidence ≥ 0.7), `routing.zig` (667 LOC, multilingual EN+VN) | Cursor smart mode | Works well; TaskIntent enum covers 6 intents |
| 10 | Context engine (manifest, budget, rerank) | RAG | COMPLETE | `context_manifest.zig` (134 LOC), `context_budget.zig` (329 LOC, 3-tier), `context_rerank.zig` (441 LOC), `secret_scanner.zig`, `adaptive_budget.zig`, `usage_tracker.zig` | Cursor "Codebase context" | **Forge stronger** (inspectable via `forge context`) |
| 11 | MCP (Model Context Protocol) | Agent | COMPLETE | `packages/ai/src/mcp_client.zig` (490 LOC, stdio + HTTP), `mcp_registry.zig` (364 LOC), `mcp_capability.zig` | Cursor MCP support | Tools + resources + prompts; annotation-based policy |
| 12 | Multi-agent orchestration | Agent | PARTIAL | `packages/ai/src/subagent.zig` (148 LOC, Roles: `repair_log_reader`/`repair_test_writer`/`planner`/`reviewer`/`custom`), `planner.zig` (132 LOC), `multi_model.zig` (192 LOC) | Kiro multi-agent / Antigravity parallel cards | Subagents run hidden; NO IDE parallel-cards UI |
| 13 | Session persistence & recovery | Agent | COMPLETE | `agent/session_docs.zig` (233 LOC, schema v3), append-only `.forge/sessions/<id>/events.jsonl`; `workbench/recovery.zig` (180 LOC), `session_restore.zig` (259 LOC) | Cursor resume / Antigravity long-task resume | **Forge stronger** (atomic + undo + crash journal) |
| 14 | Provider routing & failover | Provider | COMPLETE | 7 providers: Gemini/Ollama/OpenAI/OpenRouter/NVIDIA/**Anthropic** (`claude-sonnet-4-5`)/Fake; `provider_failover.zig` (114 LOC, `FailoverChain` + `CircuitBreaker`); `provider_capability.zig` (509 LOC, 8+ `builtin_models` with price/Mtok); `retry.zig` (with jitter) | Cursor multi-provider | Eval doc gap "Không có Anthropic" is STALE |
| 15 | 3-surface parity (CLI / TUI / IDE) | Cross | PARTIAL | CLI: 24+ subcommands; TUI: `agent_tui/app.zig` (2485 LOC); IDE: 60+ controllers | Cursor (IDE+CLI) / Antigravity (IDE) | `forge spec` CLI ✓/IDE ✗/TUI ✗; `forge agent run --background` CLI ✓/IDE ✗/TUI ✗ |
| 16 | @mention parsing (chat context) | Inline | COMPLETE | `packages/ai/src/mention_parser.zig` (`@file`/`@symbol`/`@web`/`@docs`/`@spec`/`@recent`/`@git:diff`/`@git:status`) | Cursor @mentions | CLI ✓; IDE picker exists but wiring into chat input partial |
| 17 | Chat REPL | Agent | COMPLETE | `apps/forge-cli/src/chat_cmd.zig` (454 LOC, slash commands `/help`/`/mode`/`/capability`/`/provider`/`/model`/`/context`/`/tools`/`/cost`/`/save`/`/resume`/`/sessions`) | Cursor chat | CLI ✓; IDE agent panel ✓; TUI ✓ |
| 18 | Eval harness | Test | PARTIAL | `fixtures/eval/` (7 suites), `apps/forge-cli/src/eval_ai_flow.zig` + `eval_summary.zig`, `scripts/eval_reliability.sh` | Cursor eval | Missing: inline completion eval, latency p50/p95, provider comparison |

## 3. Top 5 Gaps Cần Ưu Tiên

### Gap 1 — IDE Spec-Driven UX thiếu (Kiro parity blocker)
CLI `forge spec` đầy đủ (759 LOC + 494 LOC) nhưng IDE chỉ có nút
`agent_approve_spec`. Không có spec panel, spec editor, spec list view,
hay spec trace view. Đây là **gap lớn nhất** vs Kiro.

### Gap 2 — IDE background runs + interactive timeline thiếu (Antigravity
parity blocker)
CLI background runtime solid: `forge agent run --background` spawn
detached, với `runs`/`wait`/`cancel`/`approve`/`reject`/`branch`.
IDE không có background run UI. "AI RUN TIMELINE" card chỉ là 3-dot
static indicator, không phải interactive per-step timeline.

### Gap 3 — IDE multi-file Composer UX thiếu (Cursor parity blocker)
`multi_file_edit.zig` defines `ComposerBatch` with per-file
accept/toggle. CLI `forge edit --file a --file b` works. Nhưng IDE
inline_edit flow operates on single `active_file` — không có UI cho
multi-file Composer edit.

### Gap 4 — Code review và test generation là stubs, chưa LLM-wire
`code_review.zig` (215 LOC) và `test_gen.zig` (124 LOC) là
heuristic-only. Code review header nói rõ: "For AI-powered review,
the agent can use this as a pre-filter and then send relevant chunks
to the LLM" — nhưng LLM wiring không tồn tại. Không có `forge review`
CLI hay IDE review panel.

### Gap 5 — 3-surface parity bị CLI-skewed
TUI và IDE thiếu parity với CLI trên các workflow mới:
- `forge complete` — TUI không có completion surface
- `forge spec` — cả TUI và IDE đều thiếu
- `forge agent run --background` — cả TUI và IDE đều thiếu
- `forge agent timeline` — IDE chỉ có static 3-dot card

## 4. Recommended Next Steps

### P0 — Unblocks Cursor parity claim
1. **Update `AI_WORKFLOW_EVALUATION.md`** — inline completion ĐÃ wire,
   Anthropic Claude ĐÃ implement. Doc hiện tại misleading.
2. **Add inline completion latency benchmark** — target p50 < 500ms,
   p95 < 1500ms, acceptance > 20%.
3. **Add `forge complete` integration test** against fake provider.

### P1 — Unblocks Kiro + Antigravity parity
4. **Build IDE spec panel** — list specs, edit
   `requirements.md`/`design.md`/`tasks.md`, show trace, surface in
   command palette. Reuse `ai.spec_writer` API.
5. **Wire agent hooks auto-include specs in context** — khi spec tồn
   tại cho current intent, inject `requirements`+`design`+`tasks` vào
   context builder trước khi propose.
6. **Build IDE background runs panel** — reuse `agent_cmd.zig:runBackground`
   runtime; add "Runs" sidebar với wait/cancel/approve actions.
7. **Replace static 3-dot timeline card** với interactive step timeline
   component. Source data đã có trong NDJSON event stream.
8. **Add IDE multi-file Composer** — extend `inline_edit.zig` để accept
   multiple file selections, hoặc build Composer panel gọi
   `ai.multi_file_edit.ComposerBatch`.

### P2 — Polish và competitive moats
9. **LLM-wire `code_review.zig`** — change `analyzeDiff` để optionally
   take a provider, send regex-pre-filtered hunks to LLM. Add `forge
   review` CLI + IDE "Review" panel.
10. **LLM-wire `test_gen.zig`** — extend `generateTestStubs` để call
    agent với "write tests for this function" prompt. Add `forge test
    gen` CLI.
11. **Promote multi-agent orchestration** — expose `planner` +
    `reviewer` + `implementer` as named concurrent subagents với visible
    IDE panel (parallel cards like Antigravity).
12. **Add inline completion eval + provider comparison mode** to
    `forge eval ai-flow`.
13. **Extend 3-surface parity** — bring `forge spec`, `forge complete`,
    và background runs to TUI; bring `forge spec` và background runs
    to IDE.

## 5. Notes on Doc vs Code Drift

`AI_WORKFLOW_EVALUATION.md` (2026-07-24) đã drift trên 3 claims:
- **Inline completion wiring**: claims "chưa wire" — code at
  `ghost_completion.zig:309` proves it IS wired.
- **Anthropic Claude provider**: claims "Không có" —
  `providers/anthropic/provider.zig:14` ships `claude-sonnet-4-5`.
- **Provider capability metadata**: claims "chưa implement" —
  `provider_capability.zig` (509 LOC, 8+ builtin_models) IS implemented.

Capability Matrix correctly notes all three as DONE under M10. Recommend
reconciling eval doc với capability matrix trước khi dùng cho RFC planning.

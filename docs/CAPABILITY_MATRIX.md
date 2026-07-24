# Forge Capability Matrix

> Audited against the repository on 2026-07-24 (after Phase 3-4 merge).

"Implemented" means production code exists; "verified" requires deterministic
tests; "dogfood-ready" requires reliable routine use. These states must not be
treated as synonyms.

| Capability | Implemented | Integrated | Verified | Dogfood-ready | Primary gap |
|---|:---:|:---:|:---:|:---:|---|
| Workspace tree/search/watch | Yes | CLI + IDE | Partial | Partial | scale corpus |
| Atomic transaction/apply | Yes | CLI + IDE | Yes | Partial | power-loss/IO fault soak |
| Conflict-safe undo | Yes | CLI | Yes | Partial | IDE conflict UI |
| CLI workspace/change commands | Yes | CLI | Partial | Partial | JSON black-box contract |
| Context manifest/redaction | Yes | CLI + IDE | Partial | Partial | adversarial corpus |
| Gemini/Ollama/OpenAI/OpenRouter/NVIDIA/Anthropic providers | Yes | CLI + IDE | Partial | No | deterministic provider suite |
| Provider capability metadata + smart router | Yes | CLI | Yes | Partial | live provider baselines |
| Ask/Plan proposal workflow | Yes | CLI + IDE | Partial | No | product evaluation |
| Composer multi-file inline edit | Yes | CLI | Partial | No | IDE Composer UI |
| Multi-step agent and tools | Yes | CLI + IDE | Yes | Partial | container boundary + provider/model baselines |
| Background agent runs | Yes | CLI | Partial | No | wait/cancel polling, approval gates |
| Session branching | Yes | CLI | Partial | No | step-filtered branch |
| Agent timeline + events --follow | Yes | CLI | Partial | No | IDE timeline component |
| MCP client/registry | Yes | Agent | Partial | No | capability audit |
| Native editor/tabs/splits | Yes | IDE | Partial | Partial | workbench decomposition |
| Inline AI completion (ghost text) | Yes | IDE | Partial | Partial | latency benchmark, cache |
| `forge complete` CLI | Yes | CLI | Yes | Partial | streaming + FIM |
| Terminal/tasks | Yes | IDE | Partial | Partial | cancellation cleanup |
| LSP/rename/code actions | Yes | IDE | Partial | Partial | restart/stale suites |
| Debugger/LLDB | Yes | IDE | Minimal | No | lifecycle recovery |
| WASM extensions/catalog | Yes | CLI + IDE | Partial | No | threat model |
| Session/recovery/settings | Yes | IDE | Partial | Partial | crash injection |
| `forge chat` REPL | Yes | CLI | Partial | No | streaming + autocomplete |
| @mention parsing (@file @symbol @web @docs @spec @recent @git) | Yes | CLI | Yes | Partial | LSP @symbol, web search API |
| Spec-driven development (init/template/validate/implement/trace) | Yes | CLI | Partial | No | IDE spec panel, agent hooks |
| FORGE.md / AGENTS.md project instructions | Yes | CLI + IDE | Partial | Partial | doc freshness |
| Signed updater | Partial | Packaging | No | No | channel and rollback |

## Current release blockers

1. Add an OS/container sandbox backend before running validation for untrusted
   repositories; snapshot isolation currently protects workspace contents only.
2. Record repeatable Gemini/Ollama/Anthropic baselines with `eval_reliability.sh`;
   live trials never belong in `zig build test`.
3. Add repeated power-loss/IO fault soak beyond deterministic crash boundaries.
4. Add session-scoped approval grants without weakening `every_time` tools.
5. Large IDE orchestration/render files need feature-controller boundaries.
6. IDE build fails on Linux due to missing IME callbacks
   (`forge_backend_set_ime_composition_callback` / `forge_backend_set_ime_cursor_rect`
   not implemented in `packages/renderer/src/platform/linux/x11_window.c`). CLI is
   unaffected; macOS and Windows builds are expected to work.

## Cursor / Kiro / Antigravity parity status (2026-07-24)

See [AI Workflow Evaluation](evaluation/AI_WORKFLOW_EVALUATION.md) for full gap
analysis. Phased rollout:

- **M7 (Cursor parity): DONE for CLI** — inline completion (`forge complete`),
  Composer (`forge edit`), @mentions, chat REPL (`forge chat`). IDE ghost text
  already wired. Remaining: IDE Composer UI, inline completion latency benchmark.
- **M8 (Kiro parity): CLI DONE** — spec-driven workflow (`forge spec
  init/template/create/list/show/edit/approve/reject/implement/trace/validate`).
  Remaining: IDE spec panel, agent hooks to auto-include specs in context.
- **M9 (Antigravity parity): CLI PARTIAL** — background runs (`forge agent run
  --background`), session branching (`forge agent branch`), events follow
  (`forge agent events --follow`). Remaining: wait/cancel polling, approval
  gates, IDE timeline component, multi-agent panel.
- **M10 (Provider hardening): DONE** — capability metadata table (8 models),
  smart router (`forge models route`), Anthropic Claude provider, retry with
  jitter. Remaining: live provider eval baselines.

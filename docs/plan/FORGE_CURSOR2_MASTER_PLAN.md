# Forge → Cursor 2: Master Implementation Plan

> **Mục tiêu:** Biến Forge thành IDE AI-first native (Zig), với ba bề mặt sản phẩm
> dùng chung một engine: **CLI terminal**, **IDE editor**, và **Agents window**.
>
> **Nguyên tắc:** Không clone Cursor bằng Electron. Forge thắng ở **an toàn thay đổi**,
> **CLI/IDE đồng nghĩa**, và **native performance**.
>
> **Liên kết:** [PROJECT_VISION](../PROJECT_VISION.md) · [ROADMAP](../roadmap/ROADMAP.md)
> · RFC-0001–0004

**Cập nhật:** 2026-07-03 · **Trạng thái baseline:** M0–M2 đang triển khai (transaction
engine + CLI workflow cơ bản đã có)

---

## 1. North Star — "Cursor 2" nghĩa là gì với Forge?

Cursor hôm nay = editor + chat + agent + terminal + context (@files, rules) + diff apply.
Forge **Cursor 2** giữ workflow đó nhưng **thiết kế từ đầu** quanh transaction an toàn:

```text
Intent → Context (inspectable) → Plan/Proposal → Diff review → Approve → Apply
      → Verify (fmt/build/test) → Keep or Undo → Audit trail
```

| Cursor hôm nay | Forge Cursor 2 (định vị) |
|---|---|
| Chat/agent ghi file trực tiếp | AI chỉ propose `WorkspaceEdit`; apply qua transaction service |
| CLI (`cursor` agent) vs IDE khác semantics | `forge` CLI và Forge IDE **cùng schema** run/proposal/history |
| Electron + extension ecosystem | Native Zig, kernel nhỏ, package có ranh giới |
| Agent autonomy mặc định cao | Agent có **capability budget**, approval gates, undo cả transaction |
| Context opaque | `forge context` / Context Inspector — thấy chính xác gì gửi model |

**Ba chế độ sản phẩm** (cùng engine, khác UX):

```text
                    ┌─────────────────────────────────────┐
                    │         Shared Forge Core           │
                    │  kernel · workspace · ai · tasks    │
                    └─────────────────────────────────────┘
                           │           │           │
              ┌────────────┘           │           └────────────┐
              ▼                        ▼                        ▼
     ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
     │  CLI Mode       │    │  IDE Mode       │    │  Agents Window  │
     │  (terminal)     │    │  (editor)       │    │  (agent panel)  │
     │                 │    │                 │    │                 │
     │ forge ask       │    │ tabs, buffer    │    │ multi-step run  │
     │ forge plan      │    │ file tree       │    │ tool use stream │
     │ forge apply     │    │ diff review UI  │    │ session history │
     │ forge check     │    │ problems panel  │    │ approve/reject  │
     └─────────────────┘    └─────────────────┘    └─────────────────┘
```

---

## 2. Kiến trúc hệ thống (target)

```text
apps/
  forge-cli/          # Terminal AI-first (automation, CI, power users)
  forge-ide/          # Native app: editor + agents window + panels

packages/
  util/               # Pure helpers
  core/               # IDs, errors, shared types
  kernel/             # lifecycle, commands, events, tasks, cancellation, process
  workspace/          # paths, I/O, search, watch, transaction, history, recovery
  editor/             # buffer, cursor, local undo (không ghi disk)
  renderer/           # window, GPU, text layout, input
  lsp/                # language servers → proposals (không mutate trực tiếp)
  ai/                 # context, providers, planner, agent runtime, tools
  plugin/             # sau MVP — WASM/capability model
```

**Luật bất biến** (không phá khi scale):

1. Chỉ `workspace/transaction` được mutate filesystem.
2. AI/LSP/plugin **propose**; không `writeFile` trực tiếp.
3. Command = mutation intent; Event = fact đã xảy ra.
4. Mọi surface dùng cùng: `RunId`, `Proposal`, `TransactionId`, `.forge/` journal.
5. Không block render thread bằng I/O, LSP, model, hay subprocess.

---

## 3. Data model dùng chung (implement sớm)

Định nghĩa schema trước khi build UI — tránh CLI và IDE lệch nhau.

### 3.1 Run (một lần tương tác AI)

```json
{
  "schema_version": 1,
  "run_id": "run_20260703_001",
  "surface": "cli|ide|agent_window",
  "intent": "fix failing test in workspace package",
  "context_manifest_hash": "...",
  "provider": { "id": "gemini", "model": "..." },
  "state": "planning|proposed|reviewing|applying|verifying|done|cancelled|failed",
  "proposal_path": ".forge/proposals/3.json",
  "transaction_id": 3,
  "timings_ms": { "context": 12, "model": 4200, "review": 8000, "verify": 3100 },
  "usage": { "input_tokens": 12000, "output_tokens": 900 }
}
```

Lưu tại: `.forge/runs/<run_id>.json` + index JSONL.

### 3.2 Agent Session (Agents window — multi-step)

```json
{
  "session_id": "sess_abc",
  "run_ids": ["run_001", "run_002"],
  "mode": "ask|agent|plan",
  "capability_profile": "read_only|propose|propose_and_task",
  "max_steps": 8,
  "approval_policy": "each_apply|batch|never_auto"
}
```

Agent **không** bypass transaction: mỗi bước sửa file = một proposal → review → apply.

### 3.3 Proposal (đã có — mở rộng dần)

Hiện tại: `{ files: [{ path, operation, expected_hash, edits }] }`

Mở rộng Phase 1:

```json
{
  "schema_version": 1,
  "summary": "Create notes.txt with greeting",
  "assumptions": ["sample.txt unchanged"],
  "validation_tasks": ["zig build test"],
  "workspace_edit": { "files": [...] }
}
```

### 3.4 Context Manifest

```json
{
  "items": [
    { "kind": "file", "path": "src/main.zig", "reason": "explicit", "bytes": 4200, "included": true },
    { "kind": "file", "path": ".env", "reason": "secret_pattern", "included": false }
  ],
  "budget_bytes": 1048576,
  "used_bytes": 512000
}
```

---

## 4. Ba bề mặt — spec chi tiết

### 4.1 CLI Mode — AI-first terminal thực sự

**Persona:** Developer ở terminal, CI, SSH, scripting — cần `--json`, exit code ổn định,
không prompt khi `--non-interactive`.

**Workflow mục tiêu:**

```bash
# Hiểu workspace
forge inspect --workspace .
forge search "TransactionService" --workspace .

# AI: plan → review → apply → verify → undo
forge context --intent "add history integration test" --file packages/workspace/src/history.zig
forge ask "add integration test for persistApplied" --file packages/workspace/src/history.zig
forge diff .forge/proposals/latest.json
forge apply .forge/proposals/latest.json --dry-run
forge apply .forge/proposals/latest.json --yes
forge check
forge history
forge undo 3

# Agent one-shot (headless)
forge agent run --intent "..." --max-steps 5 --yes-apply --json

# Automation
forge run show run_20260703_001 --json
```

**Commands cần có (theo phase):**

| Command | Phase | Mô tả |
|---|---|---|
| `inspect`, `search`, `diff`, `apply`, `undo`, `history`, `check`, `task` | ✅ P0 (M2) | Engine workflow cơ bản |
| `context` | P1 (M3) | Preview context trước khi gửi model |
| `ask` | P1 (M3) | Intent → proposal, không auto-apply |
| `plan` | P1 (M3) | Structured plan + proposal file |
| `run list/show` | P1 (M3) | Audit run records |
| `agent run` | P2 (M3.5) | Multi-step với tool loop |
| `agent resume` | P2 | Tiếp session bị interrupt |
| `watch` | P2 (M1.5) | File events → trigger re-index |
| `doctor` | P1 | Toolchain, keychain, writable paths |

**UX terminal:**

- Streaming progress trên stderr; kết quả trên stdout.
- TUI optional (`forge tui`) — **sau** khi `--json` contract ổn định.
- Màu diff trong terminal (human mode); schema versioned (json mode).

---

### 4.2 IDE Mode — Editor native

**Persona:** Viết code hàng ngày — buffer, tabs, tree, diagnostics, diff review trực quan.

**Layout (đã mock trong `apps/forge-ide`):**

```text
┌──────────────────────────────────────────────────────────────┐
│ Title / Command palette                                      │
├──┬──────────┬──────────┬─────────────────────────────────────┤
│A │ Agents   │ Explorer │ Editor (tabs)                       │
│c │ Window   │          │                                     │
│t │          │          │                                     │
│  │          │          ├─────────────────────────────────────┤
│  │          │          │ Panel: Terminal / Problems / Output   │
├──┴──────────┴──────────┴─────────────────────────────────────┤
│ Status bar                                                   │
└──────────────────────────────────────────────────────────────┘
```

**IDE capabilities theo phase:**

| Capability | Phase | Ghi chú |
|---|---|---|
| Open/save file, buffer, cursor, scroll | P1 (M4) | Piece table vs rope — benchmark trước |
| File tree từ `workspace/tree` | P1 | Real data, không mock |
| Tabs, dirty state, external change | P1 | Conflict UI bắt buộc |
| Command palette | P1 | Gọi kernel commands |
| Diff review panel | P2 (M5) | Multi-file, keyboard nav |
| Problems / task output | P2 (M6) | Stream từ `kernel/process` |
| Inline diagnostics (LSP) | P3 (M6) | Stale discard |
| Keybindings, settings | P3 (M6) | |

**Không làm sớm:** debugger, remote SSH, notebooks, extension marketplace.

---

### 4.3 Agents Window — trái tim "Cursor Agent"

**Persona:** Multi-step coding agent — plan, đọc file, search, propose patch, chạy test,
lặp cho đến done — **luôn có approval gate**.

**Modes:**

| Mode | Hành vi | Tương đương Cursor |
|---|---|---|
| **Ask** | Q&A + context, không propose file | Chat |
| **Plan** | Plan structured + optional proposal | Plan mode |
| **Agent** | Tool loop: read/search/run/propose | Agent/Composer |
| **Review** | Chỉ xem diff đang pending | Diff view |

**Agent tool surface (capability-scoped):**

```text
read_file(path)           → snapshot + hash
search(query)             → workspace search
list_tree(path?)          → tree scan
run_task(name)            → zig build test (no shell)
propose_edit(json)        → validate WorkspaceEdit
apply_proposal(id)        → qua transaction (cần approval)
undo(transaction_id)
show_context_manifest()
```

**Agents window UI states:**

```text
Idle → Streaming (model/tools) → ProposalReady → ReviewingDiff
     → Applying → Verifying → Success | Failed | Cancelled
     → (optional) NextStep
```

**Session persistence:** `.forge/sessions/<id>/` — resume sau crash; sync với recovery journal.

---

## 5. Lộ trình triển khai tuần tự

Mỗi phase có **exit gate** — không sang phase sau nếu chưa pass.

```text
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5 ──► Phase 6
 M0-M2      M3 CLI AI    Agent       M4 IDE      M5 Agents    M6 LSP       M7 Beta
 foundation  proof       runtime     editor      + AI UI      daily use    hardening
```

---

### Phase 0 — Foundation & Safe Engine (M0–M2) `[~80% done]`

**Mục tiêu:** CLI deterministic, transaction an toàn, không cần AI.

| # | Work item | Package | Status |
|---|---|---|---|
| 0.1 | Transaction apply/undo/recovery | `workspace` | ✅ |
| 0.2 | History journal `.forge/` | `workspace` | ✅ |
| 0.3 | Proposal JSON parse/validate | `workspace` | ✅ |
| 0.4 | Search, preview diff | `workspace` | ✅ |
| 0.5 | CLI: inspect/search/diff/apply/undo/history/check | `forge-cli` | ✅ |
| 0.6 | Process runner Zig 0.16 | `kernel` | ✅ |
| 0.7 | Renderer spike + RFC-0004 accepted | `renderer` | ⬜ verify |
| 0.8 | Failure-injection tests (disk full, stale hash) | `workspace` | ✅ partial |
| 0.9 | Black-box CLI integration tests | `forge-cli` | ✅ |
| 0.10 | `forge watch` real implementation | `workspace` + CLI | ✅ |

**Exit gate Phase 0:**

- [ ] `./scripts/check.sh --full` green
- [ ] E2E demo: inspect → search → diff → apply → check → history → undo
- [ ] Ctrl-C không để transaction dở
- [ ] ROADMAP M2 exit gate pass

**Effort ước lượng còn lại:** 1–2 tuần

---

### Phase 1 — AI CLI Proof (M3) `[NEXT]`

**Mục tiêu:** Chứng minh AI-first workflow **ở terminal** trước khi đầu tư IDE sâu.

| # | Work item | Mô tả |
|---|---|---|
| 1.1 | **Context engine v2** | Budget, inclusion reason, secret scan, ignore rules |
| 1.2 | **`forge context`** | Human + `--json` manifest preview |
| 1.3 | **Proposal schema v1** | summary, assumptions, validation_tasks + workspace_edit |
| 1.4 | **Provider hardening** | Streaming, cancel, fake provider fixtures, 1 real provider |
| 1.5 | **Credentials** | Keychain macOS; never log secrets |
| 1.6 | **`forge ask`** | Intent → stream → proposal file + run record |
| 1.7 | **`forge plan`** | Wire planner → proposal (thay stub hiện tại) |
| 1.8 | **Run records** | `.forge/runs/` schema + `forge run show/list` |
| 1.9 | **End-to-end AI demo** | ask → diff → apply → check → undo |
| 1.10 | **Eval harness** | 20–30 tasks + safety traps + metrics |

**CLI UX polish:**

- Progress: `context built → sending → streaming → parsing → proposal ready`
- `--json` cho mọi command AI
- Error messages: stale hash, secret blocked, parse failure

**Exit gate Phase 1:**

- [ ] 100% safety fixtures pass (no stale/unauthorized write)
- [ ] 80%+ eval tasks pass validation on first apply
- [ ] Median prompt-to-verified ≥20% faster than manual baseline (suitable tasks)
- [ ] Zero secrets in trap fixtures leak to provider

**Effort ước lượng:** 4–6 tuần

---

### Phase 2 — Agent Runtime (shared) `[blocks Agents Window + agent CLI]`

**Mục tiêu:** Multi-step agent loop dùng chung bởi CLI và IDE.

| # | Work item | Mô tả |
|---|---|---|
| 2.1 | **AgentRuntime** package API | `packages/ai/src/agent.zig` |
| 2.2 | **Tool registry** | read/search/tree/task/propose — capability profiles |
| 2.3 | **Step loop** | plan → tool calls → aggregate → propose |
| 2.4 | **Approval gates** | per-step / per-apply / never-auto |
| 2.5 | **Session store** | `.forge/sessions/` + resume |
| 2.6 | **`forge agent run`** | Headless agent với `--max-steps`, `--json` |
| 2.7 | **Cancellation** | Token propagate: model stream + child processes |
| 2.8 | **MCP adapter (optional spike)** | External tools behind capability wall |

**Agent safety rules:**

- Max steps, max tokens, max files touched per session
- Mọi `apply` cần explicit approval (IDE button hoặc `--yes`)
- Tool `run_task` không shell — argv array only
- Log mọi tool call vào run record

**Exit gate Phase 2:**

- [ ] Agent hoàn thành 5 fixture tasks end-to-end (CLI)
- [ ] Interrupt/resume không corrupt workspace
- [ ] Mọi file change traceable tới transaction ID

**Effort ước lượng:** 3–4 tuần

---

### Phase 3 — IDE Editor Foundation (M4)

**Mục tiêu:** Editor đủ tin cậy để dogfood — **chưa cần AI UI hoàn chỉnh**.

| # | Work item | Mô tả |
|---|---|---|
| 3.1 | **`apps/forge-ide` production shell** | Lifecycle tách khỏi spike code |
| 3.2 | **Editor buffer** | Rope/piece table decision + tests |
| 3.3 | **Renderer integration** | Text layout thật (CoreText/HarfBuzz path) |
| 3.4 | **File open/save** | Qua workspace atomic primitives |
| 3.5 | **Explorer** | Real tree từ `workspace/tree` |
| 3.6 | **Tabs + dirty** | Buffer version vs snapshot hash |
| 3.7 | **Command palette** | Kernel command dispatch |
| 3.8 | **Panel: task output** | Stream build/test |
| 3.9 | **Crash recovery** | Unsaved buffer journal |

**Refactor IDE hiện tại:**

- Tách mock UI (`forge-ide/src/main.zig`) → `apps/forge-ide/src/ui/`
- Kernel thread → dùng `kernel` + `workspace` thật (không simulate)
- Không gọi AI từ render thread

**Exit gate Phase 3:**

- [ ] Mở/sửa/lưu file Zig + Unicode/Vietnamese không corrupt
- [ ] Undo/redo buffer property tests pass
- [ ] p95 input-to-frame trong ngưỡng RFC-0004
- [ ] External file change → conflict UI

**Effort ước lượng:** 6–10 tuần

---

### Phase 4 — Agents Window + AI IDE Slice (M5)

**Mục tiêu:** Workflow Phase 1–2 **trong UI** — đây là lúc Forge cảm giác như "Cursor 2".

| # | Work item | Mô tả |
|---|---|---|
| 4.1 | **Agents panel v2** | State machine: stream/tools/proposal/review |
| 4.2 | **Context inspector UI** | Included/excluded/redacted items |
| 4.3 | **Diff review UI** | Multi-file tree, keyboard approve/reject |
| 4.4 | **Apply flow UI** | Progress applying → verifying → outcome |
| 4.5 | **Session sidebar** | Past runs, resume, filter |
| 4.6 | **Mode switcher** | Ask / Plan / Agent |
| 4.7 | **@ mention / scope picker** | Files, folders, symbols (symbol sau LSP) |
| 4.8 | **FORGE.md / rules** | Project instructions → context engine |
| 4.9 | **Parity tests** | Cùng fixture → CLI vs IDE → cùng transaction outcome |

**Agents window — wire to real backend:**

```text
UI event → kernel command → AgentRuntime / ask / apply
         ← event bus ← streaming tokens, tool results, proposal ready
```

**Exit gate Phase 4:**

- [ ] Golden workflow: prompt → diff review → apply → test → undo (IDE)
- [ ] 90% evaluators complete workflow without help
- [ ] CLI vs IDE: zero safety outcome discrepancy
- [ ] 5 dogfood tasks liên tiếp thành công

**Effort ước lượng:** 6–8 tuần

---

### Phase 5 — Language Intelligence & Daily Use (M6)

**Mục tiêu:** Dùng Forge hàng ngày cho Zig (và dogfood chính repo Forge).

| # | Work item |
|---|---|
| 5.1 | LSP transport + zls integration |
| 5.2 | Diagnostics, hover, go-to-def, completion |
| 5.3 | Rename → WorkspaceEdit preview |
| 5.4 | Syntax highlighting incremental |
| 5.5 | Splits, recent workspaces, session restore |
| 5.6 | PTY terminal (nếu evidence cần) |
| 5.7 | Settings, keybindings, a11y baseline |
| 5.8 | Package macOS: sign, notarize, update channel |

**Exit gate Phase 5:**

- [ ] Team dogfood 70%+ in-scope tasks without escape IDE
- [ ] 1 real Forge feature shipped using only Forge

**Effort ước lượng:** 8–12 tuần

---

### Phase 6 — Beta & Cursor-parity gaps (M7+)

Chỉ sau dogfood có evidence:

| Feature | Priority | Condition to start |
|---|---|---|
| Inline edit / Tab completion | P2 | M5 eval shows demand |
| Background cloud agents | P3 | Separate security roadmap |
| Extension / WASM plugins | P3 | M7 spike + threat model |
| Multiplayer / collab | P4 | Off roadmap |
| Windows/Linux ports | P2 | Renderer abstraction proven |
| Custom Forge models | P4 | Off roadmap |

---

## 6. Ma trận so sánh Cursor → Forge (tracking)

Dùng bảng này để ưu tiên backlog; cập nhật cột **Forge** mỗi phase.

| Capability | Cursor | Forge target | Phase |
|---|---|---|---|
| Chat Ask | ✅ | `forge ask` + IDE Ask mode | 1, 4 |
| Agent multi-step | ✅ | AgentRuntime + Agents window | 2, 4 |
| Composer multi-file | ✅ | Proposal + diff review | 1, 4 |
| @ file context | ✅ | Context manifest + picker | 1, 4 |
| .cursorrules | ✅ | FORGE.md + forge.toml `[ai]` | 1, 4 |
| Apply diff | ✅ | Transaction apply | 0 ✅ |
| Undo AI change | partial | Transaction undo | 0 ✅ |
| Terminal agent | ✅ | `forge agent run` | 2 |
| CLI headless | ✅ | `forge` full workflow | 0–2 |
| Inline Tab | ✅ | Deferred | 6+ |
| LSP | ✅ | zls + pipeline | 5 |
| MCP tools | ✅ | Adapter spike | 2 |
| Background agents | ✅ | Cloud — deferred | 6+ |
| Extension ecosystem | ✅ | WASM — deferred | 6+ |
| Native perf | ❌ Electron | ✅ Zig native | 0–3 |
| Inspectable context | ❌ | ✅ `forge context` | 1 |
| Safe stale rejection | partial | ✅ hash preconditions | 0 ✅ |

---

## 7. Thứ tự implement đề xuất (backlog tuần)

**Ngay bây giờ (hoàn Phase 0):**

1. Black-box CLI tests (apply/undo/history)
2. Failure-injection tests transaction
3. `forge watch` MVP
4. Cập nhật ROADMAP M1/M2 checkboxes + gap analysis

**Sprint tiếp theo (bắt Phase 1):**

5. Context engine v2 + secret scanner integration
6. `forge context` command
7. Proposal schema v1 (extend parser)
8. `forge ask` với fake provider fixtures
9. Run record schema + `forge run show`

**Song song (risk reduction):**

10. Editor buffer benchmark (rope vs piece table) — không block Phase 1
11. IDE shell refactor plan (RFC ngắn)

---

## 8. RFCs cần viết trước khi code lớn

| RFC | Khi nào | Nội dung |
|---|---|---|
| RFC-0005 Run & Session schema | Phase 1 start | `.forge/runs`, `.forge/sessions` |
| RFC-0006 Context budget & redaction | Phase 1 | Token/byte budget, secret policy |
| RFC-0007 Agent tool capability model | Phase 2 | Tool registry, approval, limits |
| RFC-0008 IDE shell architecture | Phase 3 | Thread model, UI ↔ kernel bridge |
| RFC-0009 Partial apply semantics | Phase 4+ | Per-hunk approve — nếu cần |

---

## 9. Chất lượng & CI (mọi phase)

- `zig fmt --check`, `zig build test`, `./scripts/check.sh --full`
- Pre-commit fast / pre-push full
- Conventional commits (`feat(forge-cli): ...`)
- Benchmark regression cho renderer + workspace scan
- Eval harness AI tách khỏi unit tests (deterministic vs stochastic)

---

## 10. Rủi ro và cách giảm

| Rủi ro | Giảm |
|---|---|
| IDE scope creep | CLI proof trước (Phase 1); IDE editor trước AI UI (Phase 3→4) |
| Agent unsafe writes | Tool `propose` only; apply qua transaction + approval |
| CLI/IDE semantic drift | Shared JSON schema + parity tests |
| Renderer không đủ nhanh | RFC-0004 baselines; không tối ưu sớm |
| Model quality không đủ | Eval harness; improve context trước khi thêm UI |
| Zig 0.16 API churn | Pin version; abstract Io/process behind kernel |

---

## 11. Definition of Done — "Forge = Cursor 2"

Forge đạt Cursor 2 khi:

1. **CLI:** Developer hoàn thành feature nhỏ từ prompt → verified code → undo, không mở IDE.
2. **IDE:** Cùng workflow trong Agents window với diff review trực quan.
3. **Safety:** Không mất data; stale/conflict rejected; mọi apply undo được.
4. **Trust:** Context manifest inspectable; secrets không leak.
5. **Dogfood:** Team ship code Forge bằng Forge ≥70% thời gian.

---

## 12. Bước tiếp theo (action items)

| Ưu tiên | Action | Owner phase |
|---|---|---|
| P0 | Close M2 exit gate (CLI tests + watch) | Phase 0 |
| P0 | Viết RFC-0005 Run schema | Phase 1 |
| P0 | Implement `forge context` | Phase 1 |
| P0 | Wire `forge ask` end-to-end | Phase 1 |
| P1 | AgentRuntime design doc → RFC-0007 | Phase 2 |
| P1 | IDE buffer benchmark | Phase 3 prep |

---

*Tài liệu này là kế hoạch triển khai tuần tự. Chi tiết checklist từng milestone vẫn theo
[ROADMAP](../roadmap/ROADMAP.md). Khi hoàn thành mỗi phase, cập nhật cột Status trong
mục 5 và ma trận mục 6.*

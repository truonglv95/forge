# Forge CLI → Cursor CLI: Roadmap theo Phase

> **Mục tiêu:** Đưa `forge agent` (terminal) lên mức tương đương Cursor CLI về UX,
> automation, sandbox, extensibility và multi-agent — **không tách binary riêng**
> (`forge-agent`), mà mở rộng harness dùng chung với IDE.
>
> **Nguyên tắc:** Một harness (`packages/ai`), nhiều UI (TUI, IDE, cloud sau này).
> Agent **propose** thay đổi; chỉ transaction service được ghi disk.
>
> **Liên kết:** [FORGE_CURSOR2_MASTER_PLAN](./FORGE_CURSOR2_MASTER_PLAN.md) ·
> [ROADMAP](../roadmap/ROADMAP.md) · [CAPABILITY_MATRIX](../CAPABILITY_MATRIX.md) ·
> [AI_MODE_TOOL_MATRIX](../AI_MODE_TOOL_MATRIX.md)

**Cập nhật:** 2026-07-06 · **Trạng thái:** Phase 1 hoàn tất (implementation); Phase 2 tiếp theo.

---

## 1. North Star — Cursor CLI nghĩa là gì với Forge?

Cursor CLI hôm nay ≈ interactive agent REPL + headless automation + tool approval +
context (@files, rules) + diff apply + (tuỳ chọn) parallel agents qua git worktree.

Forge giữ workflow đó nhưng **không hy sinh** transaction an toàn:

```text
Intent → Context (inspectable) → Agent loop → Proposal → Diff review → Approve → Apply
      → Verify → Keep or Undo → Audit trail (.forge/)
```

| Cursor CLI hôm nay | Forge CLI (định vị) |
|---|---|
| Agent ghi file trực tiếp | Agent chỉ `propose_edit`; apply qua transaction |
| CLI vs IDE semantics khác nhau | `forge agent` và IDE Agents window **cùng harness** |
| Sandbox local/cloud | OS sandbox (Seatbelt/Landlock) + approval policy |
| Parallel agents (worktree) | `forge worktree` + `forge agent spawn` |
| Rules / Skills / MCP | `AGENTS.md` + `.forge/skills/` + `.mcp.json` |

**Không cần `apps/forge-agent`.** CLI agent là module trong `apps/forge-cli`:

```text
forge (một binary)
├── forge agent          → TUI (agent_tui/) hoặc headless (agent_cmd.zig)
├── forge agent run      → one-shot headless
├── forge agent resume   → tiếp session
├── forge agent exec     → (Phase 2) CI one-shot
└── packages/ai          → harness dùng chung CLI + IDE
```

---

## 2. Baseline hiện tại (2026-07-06)

### Đã có

| Thành phần | Trạng thái | File / module chính |
|---|---|---|
| TUI interactive | ✅ Cơ bản | `apps/forge-cli/src/agent_tui/` |
| Chat input + cursor, history ↑↓ | ✅ | `agent_tui/app.zig`, `agent_tui/term.zig` |
| Status bar (model, context, branch, policy) | ✅ | `agent_tui/app.zig` |
| Streaming LLM output | ✅ | `packages/ai/src/agent/loop.zig` |
| Tool approval (y/n) | ✅ | `agent_tui/app.zig` |
| Proposal shortcuts d/a/n | ✅ | `agent_tui/app.zig` |
| `@file` context parsing | ✅ | `agent_tui/app.zig` |
| Unicode-safe wrap/truncate | ✅ | `agent_tui/term.zig` |
| `forge agent run \| resume \| list` | ✅ | `apps/forge-cli/src/agent_cmd.zig` |
| Session persist | ✅ | `packages/workspace/src/sessions` |
| Agent loop dùng chung CLI + IDE | ✅ | `packages/ai/src/agent.zig` |
| Tool registry + risk policy | ✅ | `packages/ai/src/tools/registry.zig` |
| MCP client (partial) | ⚠️ | `packages/ai/src/mcp_registry.zig` |
| `AGENTS.md` trong context | ✅ | `packages/ai/src/context_loader.zig` |
| Isolated repair trial (snapshot) | ✅ | `packages/ai/src/repair_loop.zig` |
| On-save hooks (không phải agent hooks) | ✅ | `packages/workspace/src/hooks.zig` |

### Chưa có / còn thiếu

| Gap so với Cursor CLI | Ghi chú |
|---|---|
| Resume session **trong TUI** | Hiện chỉ hint + `forge agent resume` headless |
| Mode switch Ask/Plan/Agent trong TUI | IDE đã có; CLI TUI chưa |
| NDJSON event stream (`--json`) | Kết quả cuối có; stream events chưa |
| `forge agent exec` headless CI | Tương đương `codex exec` |
| OS-level sandbox cho `run_command` | Blocker release (CAPABILITY_MATRIX #1) |
| Git worktree parallel agents | Cursor parallel agents |
| Skills system | Claude/Cursor Skills |
| Agent hooks (before/after tool) | Claude Hooks model |
| Background agent jobs | Antigravity async model |
| Cross-surface session sync CLI ↔ IDE | Cloud agent lesson từ Cursor |

**Vị trí hiện tại:** Phase 1 xong → **Phase 2** (headless & automation) là bước tiếp theo.

---

## 3. Kiến trúc mục tiêu

```text
                    ┌─────────────────────────────────────┐
                    │         packages/ai (Harness)       │
                    │  loop · tools · routing · MCP       │
                    │  context · approval · streaming     │
                    └─────────────────────────────────────┘
                           │                    │
              ┌────────────┘                    └────────────┐
              ▼                                              ▼
     ┌─────────────────┐                          ┌─────────────────┐
     │  forge-cli TUI  │                          │  forge-ide      │
     │  agent_tui/     │                          │  agent/         │
     └────────┬────────┘                          └────────┬────────┘
              │                                            │
              └──────────────────┬─────────────────────────┘
                                 ▼
                    ┌─────────────────────────────────────┐
                    │      packages/workspace (Runtime)    │
                    │  transaction · sessions · sandbox    │
                    │  worktree · hooks · runs journal     │
                    └─────────────────────────────────────┘
```

---

## 4. Lộ trình phase

```text
Phase 0 (done) ──► Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5 ──► Phase 6
  TUI foundation    TUI parity   Headless    Sandbox    Extensibility  Multi-agent   Cloud
```

| Phase | Mục tiêu | Effort | Cursor parity ước lượng |
|---|---|---|---|
| **0** | TUI foundation | ✅ done | ~50% |
| **1** | TUI parity hàng ngày | 1–2 tuần | ~60% |
| **2** | Headless & CI | 2 tuần | ~70% |
| **3** | OS sandbox | 3–4 tuần | ~80% |
| **4** | Skills, hooks, MCP | 2–3 tuần | ~85% |
| **5** | Parallel agents | 3–4 tuần | ~95% |
| **6** | Cloud & unified session | 4–6 tuần | ~100% |

Mỗi phase có **exit gate** — không sang phase sau nếu chưa pass.

---

## Phase 0 — TUI Foundation `[DONE]`

**Mục tiêu:** `forge agent` (không subcommand) mở TUI interactive cơ bản.

| # | Work item | File | Status |
|---|---|---|---|
| 0.1 | Raw terminal + frame buffer | `agent_tui/term.zig` | ✅ |
| 0.2 | Chat history + input editing | `agent_tui/app.zig` | ✅ |
| 0.3 | Agent worker thread + streaming | `agent_tui/app.zig` | ✅ |
| 0.4 | Tool policy cycle (Run everything / Ask / Default) | `agent_tui/app.zig` | ✅ |
| 0.5 | Status bar: model, context, branch, edits | `agent_tui/app.zig` | ✅ |
| 0.6 | Proposal d/a/n shortcuts | `agent_tui/app.zig` | ✅ |
| 0.7 | `@file` mention parsing | `agent_tui/app.zig` | ✅ |
| 0.8 | Unicode-safe display | `agent_tui/term.zig` | ✅ |
| 0.9 | Integrate vào `agent_cmd.zig` | `agent_cmd.zig` | ✅ |
| 0.10 | Session hint on startup | `agent_tui/app.zig` | ✅ |

**Exit gate (đã pass):**

- [x] `forge agent` mở TUI, chat được với agent
- [x] Streaming + approval hoạt động
- [x] `zig build test` green cho agent_tui

---

## Phase 1 — TUI Parity (Cursor CLI cơ bản) `[DONE]`

**Mục tiêu:** Dùng `forge agent` hàng ngày thay terminal chat thủ công.

### Work items

| # | Work item | Mô tả | File chính |
|---|---|---|---|
| 1.1 | **Resume trong TUI** | `/resume <id>` hoặc picker danh sách session; load conversation history | `agent_tui/app.zig`, `agent_cmd.zig` |
| 1.2 | **Mode switch** | Tab hoặc `/mode ask\|plan\|agent`; đồng bộ `AI_MODE_TOOL_MATRIX` | `agent_tui/app.zig`, `packages/ai/src/routing.zig` |
| 1.3 | **Slash commands** | `/clear`, `/policy`, `/context`, `/diff`, `/help`, `/quit` | `agent_tui/app.zig` |
| 1.4 | **Scroll chat** | PgUp/PgDn, Home/End cho history panel | `agent_tui/term.zig`, `app.zig` |
| 1.5 | **Tool call panel** | Hiển thị tool đang chạy + kết quả rút gọn | `agent_tui/app.zig` |
| 1.6 | **Terminal resize** | `SIGWINCH` → re-detect size, re-wrap | `agent_tui/term.zig` |
| 1.7 | **Focus management** | Chuyển focus chat ↔ action bar (policy) bằng Tab | `agent_tui/app.zig` |

### UX spec (tham chiếu Cursor CLI)

```text
┌──────────────────────────────────────────────────────────────┐
│ [chat history — scrollable]                                  │
│ > user message                                               │
│ agent response streaming...                                  │
│ ⚙ read_file src/main.zig                                     │
├──────────────────────────────────────────────────────────────┤
│ > input with cursor█                                         │
├──────────────────────────────────────────────────────────────┤
│ gemini-2.5 · ctx: 12k · 3 edited · ~/forge · main │ Run all │
└──────────────────────────────────────────────────────────────┘
```

Phím tắt đề xuất:

| Phím | Hành vi |
|---|---|
| Enter | Gửi message |
| ↑/↓ | History (khi input rỗng) hoặc recall history |
| Tab | Chuyển focus / cycle tool policy |
| d/a/n | Diff / Apply / Dismiss proposal (khi input rỗng) |
| Ctrl-C | Cancel agent run |
| Ctrl-D | Quit |

### Exit gate

- [x] Resume session từ TUI; conversation history khớp `.forge/sessions/`
- [x] Chuyển Ask → Plan → Agent; tool policy đúng matrix
- [x] Terminal resize không corrupt Unicode (tiếng Việt)
- [ ] Dogfood 30 phút không panic
- [x] `zig build test` green

**Effort ước lượng:** 1–2 tuần

---

## Phase 2 — Headless & Automation (Codex `exec` style)

**Mục tiêu:** CI và script dùng `forge agent` như Cursor headless / `codex exec`.

### Work items

| # | Work item | Mô tả | File chính |
|---|---|---|---|
| 2.1 | **NDJSON event stream** | `--json` stream: `tool_start`, `tool_end`, `text_delta`, `proposal_ready`, `done` | `agent_cmd.zig`, `packages/ai/src/progress.zig` |
| 2.2 | **`forge agent exec`** | One-shot: intent → exit code + proposal path | `agent_cmd.zig` (mới) |
| 2.3 | **Approval contract** | `--approve-policy run-everything\|ask\|never` + `--yes` | `args.zig`, `agent_cmd.zig` |
| 2.4 | **Session-scoped grants** | Approve `run_command` một lần cho cả session | `tool_registry.zig`, `agent/loop.zig` |
| 2.5 | **Stable exit codes** | 0=done, 1=failed, 2=usage, 3=cancelled, 4=needs-approval | `agent_cmd.zig` |
| 2.6 | **Run records đầy đủ** | Mọi tool call ghi `.forge/runs/<run_id>.json` | `packages/workspace` |

### NDJSON event schema (draft)

```jsonl
{"type":"run_start","run_id":"run_001","session_id":"sess_abc","mode":"agent"}
{"type":"text_delta","text":"Looking at "}
{"type":"tool_start","tool":"read_file","args":{"path":"src/main.zig"}}
{"type":"tool_end","tool":"read_file","ok":true,"summary":"142 lines"}
{"type":"proposal_ready","path":".forge/proposals/3.json"}
{"type":"run_end","status":"done","steps":4}
```

### Exit gate

- [ ] `forge agent exec "fix test" --json` parse được bởi script bash/python
- [ ] CI fixture: 5 tasks headless pass
- [ ] Không leak secret trong JSON output
- [ ] SIGINT → exit 3; workspace không corrupt
- [ ] `--non-interactive` không bao giờ block chờ stdin

**Effort ước lượng:** 2 tuần

---

## Phase 3 — Sandbox & Security (Codex CLI model)

**Mục tiêu:** `run_command` an toàn ở kernel level, không chỉ hỏi y/n.

> **Release blocker** theo [CAPABILITY_MATRIX](../CAPABILITY_MATRIX.md) #1.

### Work items

| # | Work item | Mô tả | File chính |
|---|---|---|---|
| 3.1 | **Sandbox backend trait** | `execute(cmd, policy) → Outcome` | `packages/workspace/src/sandbox.zig` (mới) |
| 3.2 | **macOS Seatbelt** | Read repo, write workspace only, no network mặc định | `sandbox/seatbelt.zig` |
| 3.3 | **Linux Landlock + seccomp** | Tương đương macOS | `sandbox/linux.zig` |
| 3.4 | **Sandbox modes** | `read-only`, `workspace-write`, `full-access` | `forge.toml`, CLI flags |
| 3.5 | **Dangerous command classifier** | Block `rm -rf /`, pipe-to-shell, v.v. | `packages/ai/src/tool_executor.zig` |
| 3.6 | **TUI sandbox indicator** | Status bar: `sandbox: workspace-write` | `agent_tui/app.zig` |
| 3.7 | **Eval safety traps** | 20+ fixtures trong `docs/evaluation/` | fixtures + `eval_reliability.sh` |

### Sandbox mode matrix

| Mode | Read repo | Write workspace | Network | Shell |
|---|---|---|---|---|
| `read-only` | ✅ | ❌ | ❌ | allowlisted argv only |
| `workspace-write` (default) | ✅ | ✅ workspace | ❌ | allowlisted + sandbox |
| `full-access` | ✅ | ✅ | ✅ | unrestricted (cần `--yes`) |

### Exit gate

- [ ] Agent không ghi được ngoài workspace trong mode mặc định
- [ ] 20 safety trap fixtures pass
- [ ] Sandbox overhead < 50ms/command trên repo trung bình
- [ ] TUI và headless dùng cùng sandbox backend

**Effort ước lượng:** 3–4 tuần

---

## Phase 4 — Extensibility (Skills, Hooks, Rules)

**Mục tiêu:** Mở rộng agent như Cursor Rules/Skills và Claude Hooks.

### Work items

| # | Work item | Mô tả | File chính |
|---|---|---|---|
| 4.1 | **Skills loader** | `.forge/skills/<name>/SKILL.md` + frontmatter metadata | `packages/ai/src/skills.zig` (mới) |
| 4.2 | **Agent hooks** | `before_tool`, `after_tool`, `on_approval` trong `.forge/hooks.toml` | mở rộng `workspace/hooks.zig` |
| 4.3 | **Rules stack** | `AGENTS.md` + `FORGE.md` + `.cursorrules` (đọc tương thích) | `context_loader.zig` |
| 4.4 | **`forge skills list`** | CLI quản lý skills | `forge-cli` |
| 4.5 | **MCP hardening** | Capability audit, timeout, secret redaction, startup validation | `mcp_registry.zig` |
| 4.6 | **TUI `/skill`** | Gắn/bỏ skill trong session hiện tại | `agent_tui/app.zig` |

### Hooks schema (draft)

```toml
[[agent.before_tool]]
tool = "run_command"
command = ".forge/hooks/validate-command.sh"

[[agent.after_tool]]
tool = "propose_edit"
command = "zig fmt {changed_files}"
```

### Exit gate

- [ ] Skill "zig-fmt" tự format sau propose_edit
- [ ] Hook block tool nguy hiểm trước approval prompt
- [ ] MCP tool không leak credential trong log/run record
- [ ] `.cursorrules` được load khi có trong workspace root

**Effort ước lượng:** 2–3 tuần

---

## Phase 5 — Multi-Agent & Parallel (Cursor worktree model)

**Mục tiêu:** Nhiều agent song song, không đạp file nhau.

### Work items

| # | Work item | Mô tả | File chính |
|---|---|---|---|
| 5.1 | **Git worktree manager** | `forge worktree create/list/remove` | `packages/workspace/src/worktree.zig` (mới) |
| 5.2 | **Agent per worktree** | Mỗi background agent có branch + directory riêng | `agent_cmd.zig` |
| 5.3 | **`forge agent spawn`** | Chạy nền, trả `agent_job_id` | `agent_cmd.zig` |
| 5.4 | **`forge agent jobs`** | List / status / cancel jobs | `agent_cmd.zig` |
| 5.5 | **TUI job panel** | Tab chuyển giữa agents đang chạy | `agent_tui/app.zig` |
| 5.6 | **Merge proposal** | Agent xong → proposal review → merge worktree về main | `workspace/transaction` |
| 5.7 | **Conflict detection** | Cảnh báo khi 2 agent chạm cùng file | `worktree.zig` |

### Parallel agent flow

```text
forge agent spawn "refactor auth"     → job_001 @ worktree/auth-refactor
forge agent spawn "add logging"       → job_002 @ worktree/add-logging
forge agent jobs                      → list running/done
forge agent jobs job_001 --follow     → stream NDJSON
[review proposal] → forge apply ...   → merge worktree
```

### Exit gate

- [ ] 2 agent sửa 2 package khác nhau song song, không conflict
- [ ] Cancel job không để worktree orphan
- [ ] Merge proposal qua transaction an toàn (all-or-nothing)
- [ ] TUI hiển thị ≥2 jobs đồng thời

**Effort ước lượng:** 3–4 tuần

---

## Phase 6 — Cloud & Unified Session

**Mục tiêu:** Cùng session CLI ↔ IDE; nền tảng cho cloud agent sau này.

### Work items

| # | Work item | Mô tả | File chính |
|---|---|---|---|
| 6.1 | **Append-only session log** | `.forge/sessions/<id>/events.jsonl` | `packages/workspace/src/sessions` |
| 6.2 | **IDE ↔ CLI session sync** | Cùng `session_id`; mở từ TUI hoặc IDE | `forge-ide/agent/`, `agent_tui/` |
| 6.3 | **Streaming rewind** | Retry step không duplicate UI output | harness + TUI |
| 6.4 | **Context Inspector trong TUI** | `/context` → manifest preview (như `forge context`) | `agent_tui/app.zig` |
| 6.5 | **`forge agent cloud`** (optional) | Remote VM + sandbox nếu có infra | TBD |
| 6.6 | **Crash recovery** | Resume sau panic/kill; không mất >1 step | RFC-0010 boundaries |

### Exit gate

- [ ] Bắt đầu ở CLI, resume ở IDE; history khớp
- [ ] Kill -9 mid-run → resume không corrupt workspace
- [ ] Session log đủ để replay tool calls

**Effort ước lượng:** 4–6 tuần (dài hạn; có thể tách 6.5 cloud ra sau)

---

## 5. So sánh với các CLI agent khác

| Khía cạnh | Cursor CLI | Claude Code | Codex CLI | Forge (target) |
|---|---|---|---|---|
| Binary | `cursor` / `agent` | `claude` | `codex` | `forge agent` |
| Harness/UI tách | ✅ | ✅ | ✅ | ✅ (`packages/ai` / `agent_tui`) |
| Interactive TUI | ✅ | ✅ | ✅ | ✅ Phase 0; parity Phase 1 |
| Headless CI | ✅ | ✅ | `codex exec` | Phase 2 |
| OS sandbox | Local + cloud VM | Permission/hooks | Kernel default | Phase 3 |
| Skills / Rules | ✅ | ✅ Skills + Hooks | `AGENTS.md` | Phase 4 |
| Parallel agents | Git worktree | Agent Teams | Subprocess | Phase 5 |
| Proposal safety | Trực tiếp ghi file | Trực tiếp | Sandbox | **Proposal → transaction** (ưu thế Forge) |

---

## 6. Nguyên tắc không đổi

Dù bám Cursor CLI, **không bỏ** các điểm Forge đang mạnh hơn:

1. **Proposal → transaction** — agent không `writeFile` trực tiếp.
2. **Một harness** — `packages/ai` cho CLI + IDE; không fork logic.
3. **Không tách `apps/forge-agent`** — TUI là module trong `forge-cli`.
4. **Native performance** — Zig, frame buffer TUI, không Electron.
5. **Inspectable context** — `forge context` / Context Inspector là first-class.
6. **Defense in depth** — tool filtered ở provider declaration **và** dispatch.

---

## 7. Thứ tự implement đề xuất (Phase 1 chi tiết)

Khi bắt đầu implement, ưu tiên theo impact/effort trong Phase 1:

```text
1.1 Resume trong TUI        ← gap UX lớn nhất
1.2 Mode switch             ← đồng bộ IDE
1.5 Tool call panel         ← “agent đang làm gì”
1.3 Slash commands          ← power user
1.4 Scroll chat             ← usability
1.6 Terminal resize         ← polish
1.7 Focus management        ← polish
```

Mỗi item nên có PR/commit riêng; chạy `./scripts/check.sh` sau mỗi item.

---

## 8. Tracking

Cập nhật cột Status trong bảng work items khi hoàn thành. Đồng bộ với:

- [CAPABILITY_MATRIX](../CAPABILITY_MATRIX.md) — implementation vs dogfood-ready
- [FORGE_CURSOR2_MASTER_PLAN](./FORGE_CURSOR2_MASTER_PLAN.md) — Phase 2 Agent Runtime (shared)
- [AI_MODE_TOOL_MATRIX](../AI_MODE_TOOL_MATRIX.md) — mode contracts

**Changelog:**

| Ngày | Thay đổi |
|---|---|
| 2026-07-06 | Phase 1: resume, slash commands, mode switch, scroll, resize, tool indicator |

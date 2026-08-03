# RFC-0015: Agent Timeline & Background Runs

> **Trạng thái:** Proposed
> **Tác giả:** truonglv95 <anhtruonglavm2@gmail.com>
> **Ngày:** 2026-07-24
> **Liên kết:** [AI Workflow Evaluation](../evaluation/AI_WORKFLOW_EVALUATION.md) ·
> [RFC-0007 Agent Tool Capability Model](RFC-0007-agent-tool-capability-model.md)

## 1. Tóm tắt

Thêm Antigravity-style agent orchestration: timeline UI trực quan, background
runs (long-running agents không block IDE), notification system, multi-agent
visualization, và session branching. Mục tiêu: đạt parity với Antigravity cho
visual agent orchestration.

## 2. Động lực

Antigravity differentiator là agent timeline + background runs. Hiện Forge:

1. Agent chỉ chạy foreground (block IDE).
2. Timeline chỉ là list view, không phải visualization.
3. Không có background runs (developer phải chờ).
4. Multi-agent (subagent) chạy ẩn, không có visualization.
5. Không có session branching (fork session tại step).

**Tại sao P1?** Background runs là baseline expectation cho AI IDE 2026. Không
có nó, Forge không thể dogfood cho long task (refactor lớn, migration).

## 3. Thiết kế

### 3.1. Background agent runtime

```text
forge agent run --background --intent "..." --max-steps 20
  → Spawn background process (or thread)
  → Write .forge/runs/<id>.json với status="running"
  → Stream events vào .forge/sessions/<id>/events.jsonl (existing)
  → Return run_id ngay lập tức
  → IDE/CLI poll hoặc subscribe cho updates
```

#### 3.1.1. Process model

- Background agent chạy trong **separate OS process** (không phải thread) để
  crash isolation.
- Communicate qua `.forge/` files (events.jsonl + run record).
- Lock file `.forge/runs/<id>.lock` để detect zombie.
- Heartbeat: update `last_heartbeat_ms` mỗi 5s vào run record.

#### 3.1.2. CLI

```bash
# Start background run
forge agent run --background --intent "refactor transaction.zig" --max-steps 20
# Output: { "run_id": "run_20260724_001", "session_id": "sess_abc", "status": "running" }

# List background runs
forge agent runs --status running
forge agent runs --status all

# Stream events từ background run
forge agent events <run_id> --follow   # tail -f style
forge agent events <run_id> --since <ts>

# Wait for completion (blocking)
forge agent wait <run_id> [--timeout 300]

# Cancel background run
forge agent cancel <run_id>

# Resume foreground (interactive approval)
forge agent resume <session_id> --foreground
```

#### 3.1.3. Approval gates in background mode

- Background agent **không bao giờ auto-approve** `every_time` tools.
- Khi agent cần approval, write `pending_approval` event + wait.
- IDE show toast notification "Run <id> needs approval for run_command".
- User approve → `forge agent approve <run_id> --yes` → agent continue.
- User reject → `forge agent reject <run_id>` → agent abort hoặc fallback.
- Timeout 5 phút → auto-reject + agent abort.

### 3.2. Agent Timeline UI

#### 3.2.1. Layout

```text
┌─ Agent Timeline ──────────────────────────────────────────────┐
│ Session: sess_abc  Status: running  Steps: 7/20  00:42        │
├──────────────────────────────────────────────────────────────┤
│                                                                │
│  ●━━●━━●━━●━━○━━○━━○━━○━━○━━○━━○━━○━━○━━○━━○━━○━━○━━○         │
│  1   2   3   4   5   6   7   8   9  10  11  12  13  14  ...   │
│  ↓   ↓   ↓   ↓   ↓                                            │
│ LLM TL TL TL LLM TL TL TL TL TL TL TL TL TL TL TL TL TL TL   │
│                                                                │
│  ● = completed    ○ = pending    ╳ = failed    ⏸ = waiting    │
│  LLM = LLM turn   TL = Tool call                                │
├──────────────────────────────────────────────────────────────┤
│ Step 4: tool_call (read_file)                                  │
│   path: packages/workspace/src/transaction.zig                 │
│   Duration: 12ms                                               │
│   Result: 1247 lines read                                      │
│   [Expand] [Replay] [Branch from here]                         │
└──────────────────────────────────────────────────────────────┘
```

#### 3.2.2. Interactions

| Action | Hành động |
|---|---|
| Click step node | Show detail panel |
| Hover step | Tooltip với summary |
| Right-click | Context menu: Branch, Replay, Copy |
| Drag-select | Zoom vào range |
| `←/→` | Navigate steps |
| `Enter` | Expand detail |
| `b` | Branch từ step này |
| `r` | Replay step |

#### 3.2.3. Step node types

```zig
pub const StepNodeKind = enum {
    llm_turn,           // LLM call
    tool_call,          // Native tool
    tool_result,        // Tool result
    subagent_started,   // Subagent spawn
    subagent_result,    // Subagent done
    proposal_created,   // Proposal emitted
    validation_started, // Validation running
    validation_result,  // Validation done
    approval_requested, // Waiting for user
    approval_granted,   // User approved
    approval_rejected,  // User rejected
    error_event,        // Error occurred
    checkpoint,         // Compaction/recovery
};

pub const StepNodeStatus = enum {
    pending,
    running,
    completed,
    failed,
    waiting,    // for approval
    cancelled,
};
```

### 3.3. Multi-agent panel

Khi `FORGE_MULTI_AGENT=1` hoặc config enable, hiển thị multi-agent view:

```text
┌─ Multi-Agent Orchestration ───────────────────────────────────┐
│                                                                │
│  ┌─ Planner ──────┐  ┌─ Reviewer ──────┐  ┌─ Implementer ──┐ │
│  │ Status: done   │  │ Status: running  │  │ Status: queued │ │
│  │ Steps: 3/3     │  │ Steps: 2/5       │  │                │ │
│  │ Tokens: 1.2k   │  │ Tokens: 800      │  │                │ │
│  │ [Timeline]     │  │ [Timeline]       │  │ [Waiting]      │ │
│  └────────────────┘  └──────────────────┘  └────────────────┘ │
│                                                                │
│  Main Agent:                                                   │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ Status: running  Steps: 7/20  Waiting: Reviewer result   │ │
│  └──────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

- Mỗi agent (main + subagents) có card riêng với timeline mini.
- Click card → expand full timeline cho agent đó.
- Main agent hiển thị "Waiting: <agent> result" khi depend.

### 3.4. Session branching

```bash
# Branch từ step 5 của session sess_abc
forge agent branch sess_abc --at-step 5 --intent "try different approach"
# Output: { "session_id": "sess_def", "branched_from": "sess_abc", "at_step": 5 }
```

#### 3.4.1. Branch semantics

- New session copy events 1-5 từ parent.
- New session starts với new intent tại step 6.
- Parent session unchanged (immutable history).
- Branch tree view trong IDE:

```text
sess_abc (main)
├── sess_def (branch at step 5: "try different approach")
│   └── sess_ghi (branch at step 3: "actually, revert")
└── sess_jkl (branch at step 10: "fix bug found")
```

### 3.5. Notification system

#### 3.5.1. Toast notifications

```text
┌─ Notification ─────────────────────────────────────────────┐
│ ✓ Run run_20260724_001 completed                            │
│   3 proposals, 2 applied, 1 rejected                        │
│   [View] [Undo all] [Dismiss]                               │
└──────────────────────────────────────────────────────────────┘

┌─ Notification ─────────────────────────────────────────────┐
│ ⏸ Run run_20260724_002 needs approval                      │
│   Tool: run_command "zig build test"                        │
│   [Approve] [Reject] [View context]                        │
└──────────────────────────────────────────────────────────────┘

┌─ Notification ─────────────────────────────────────────────┐
│ ✗ Run run_20260724_003 failed                              │
│   Error: rate_limit_exceeded (retry in 60s)                │
│   [Retry] [Switch provider] [Dismiss]                      │
└──────────────────────────────────────────────────────────────┘
```

#### 3.5.2. Notification center

- Click notification icon ở status bar → panel với history.
- Unread notifications có badge.
- Dismiss = archive (không delete).

#### 3.5.3. CLI notifications

```bash
# Watch notifications
forge notifications --follow
# Output stream:
# {"ts": "...", "type": "run_completed", "run_id": "run_20260724_001", ...}
# {"ts": "...", "type": "approval_needed", "run_id": "run_20260724_002", ...}
```

### 3.6. Configuration

```toml
# forge.toml
[ai.agent]
background_enabled = true
max_background_runs = 3              # concurrent
approval_timeout_ms = 300000         # 5 min
heartbeat_interval_ms = 5000
auto_cancel_on_ide_quit = false      # keep running

[ai.agent.timeline]
show_tokens = true
show_durations = true
collapse_tool_results = true         # collapse long outputs
max_visible_steps = 50               # virtual scroll beyond this

[ai.agent.multi_agent]
enabled = true                       # opt-in
default_roles = ["planner", "reviewer", "implementer"]
```

## 4. Concurrency & safety

### 4.1. Workspace locking

- Background run acquire `.forge/workspace.lock` (advisory lock).
- Nếu IDE want apply proposal khi background run đang chạy, IDE wait.
- Nếu 2 background runs cùng muốn propose, queue theo `run_id` order.
- Lock release khi run complete/cancel/crash.

### 4.2. Crash recovery

- Heartbeat mỗi 5s. Nếu `now - last_heartbeat > 30s`, mark `zombie`.
- On IDE startup, scan `.forge/runs/` cho `running` runs:
  - If heartbeat fresh: resume tracking.
  - If heartbeat stale: mark `zombie`, prompt user "Resume or Cancel?".
- Background process crash → `zombie` after 30s → user can clean up.

### 4.3. Resource limits

```toml
[ai.agent.background_limits]
max_concurrent_runs = 3
max_total_steps_per_run = 50
max_total_tokens_per_run = 500000
max_wall_time_ms = 1800000          # 30 min
max_files_touched_per_run = 20
```

- Exceed limit → run auto-cancel với reason `budget_exceeded`.
- User can override per-run: `--max-steps 100 --max-tokens 1000000`.

## 5. Testing

### 5.1. Unit tests

```zig
test "background run writes run record" { ... }
test "heartbeat updates last_heartbeat_ms" { ... }
test "zombie detection after 30s" { ... }
test "workspace lock prevents concurrent apply" { ... }
test "branch copies events 1..N" { ... }
test "approval timeout auto-rejects" { ... }
```

### 5.2. Integration tests

```bash
# Background run end-to-end
forge agent run --background --intent "..." --max-steps 5 --json
RUN_ID=...
sleep 2
forge agent runs --status running
forge agent events $RUN_ID --follow > /tmp/events.ndjson &
EVENTS_PID=$!
forge agent wait $RUN_ID --timeout 60
kill $EVENTS_PID
# Verify events.ndjson có session_started, llm_turn, ..., run_completed

# Approval flow
forge agent run --background --intent "..." --capability propose_and_task --max-steps 5 &
RUN_ID=...
sleep 5
forge agent events $RUN_ID | grep "approval_requested"
forge agent approve $RUN_ID --yes
forge agent wait $RUN_ID

# Branch
SESSION_ID=...
forge agent branch $SESSION_ID --at-step 3 --intent "different"
# Verify new session có events 1-3 từ parent

# Crash recovery
forge agent run --background --intent "..." &
RUN_PID=$!
kill -9 $RUN_PID
sleep 35  # wait for zombie detection
forge agent runs --status zombie
```

### 5.3. Eval

```bash
forge eval ai-flow --corpus fixtures/eval/background_runs.json
# Tasks:
# - Long task (20 steps) trong background, IDE still usable
# - Multi-agent task với 3 subagents
# - Branch task: try 2 approaches from step 5
# - Crash recovery: kill agent, resume
```

## 6. Rollout plan

1. **Week 1-2:** Background runtime + `forge agent run --background` + `runs`
   + `events --follow` + `wait` + `cancel`.
2. **Week 2-3:** Approval gates + `approve/reject` CLI + notifications.
3. **Week 3:** Crash recovery + zombie detection + workspace locking.
4. **Week 3-4:** Timeline UI component (render only).
5. **Week 4-5:** Timeline interactions (click, branch, replay).
6. **Week 5:** Multi-agent panel.
7. **Week 5-6:** Session branching CLI + UI.
8. **Week 6-7:** Notification system + polish.

## 7. Risks

| Rủi ro | Giảm |
|---|---|
| Background process crash corrupts workspace | Transaction isolation + snapshot + crash recovery |
| Concurrent runs race condition | Workspace lock + queue |
| Memory leak long-running agent | Heartbeat + max_wall_time + max_total_tokens |
| Approval timeout blocks workflow | Auto-reject sau 5 min + notification |
| Timeline UI performance (many steps) | Virtual scroll + collapse |
| Multi-agent deadlock | Global step limit + timeout + loop guard |

## 8. Alternatives considered

- **In-process threads:** ❌ Crash isolation kém, block render thread risk.
- **Remote agent service:** ❌ Out of scope, local-first.
- **Single background run only:** ❌ Antigravity supports multiple, parity.
- **No branching:** ❌ Loss vs Cursor (Cursor has session branches).

## 9. Open questions

- [ ] Có nên support background runs across IDE restarts?
      → Yes, via heartbeat + zombie detection.
- [ ] Có nên support cloud background runs (like Cursor)?
      → Phase 2, separate security roadmap.
- [ ] Timeline export as image/video for sharing?
      → Phase 2.

## 10. Exit gate

- [ ] `forge agent run --background` returns immediately với run_id
- [ ] `forge agent runs/events/wait/cancel/approve/reject` works
- [ ] Background run survive IDE quit (config `auto_cancel_on_ide_quit=false`)
- [ ] Crash recovery: zombie detection sau 30s
- [ ] Workspace lock prevents concurrent mutation
- [ ] Timeline UI renders all step types
- [ ] Multi-agent panel shows main + subagents
- [ ] Session branching creates new session từ step N
- [ ] Notification system: toast + center + CLI `--follow`
- [ ] 3 background runs concurrent không corrupt workspace
- [ ] Eval `background_runs.json` pass

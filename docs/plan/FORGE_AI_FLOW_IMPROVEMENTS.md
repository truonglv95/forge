# Forge AI Flow Improvements

**Cập nhật:** 2026-07-07  
**Mục tiêu:** đưa Forge tiến gần hơn tới một AI-first IDE/CLI như Cursor/Kiro: agent phải hiểu task, tự lấy context đúng lúc, gọi tool minh bạch, tạo proposal an toàn, verify được, và hiển thị quá trình làm việc rõ ràng trên cả CLI/TUI/IDE.

**Implementation note 2026-07-07:** `packages/ai/src/agent_event.zig` đã định nghĩa schema event chung. `forge agent run --events ndjson` đã được thêm cho headless agent. Stream hiện phát các event `run_started`, `llm_turn`, `tool_call`, `tool_result`, `run_completed`, `error` với `schema_version: 1`. Human transcript mặc định và `--json` final output vẫn tách riêng.

Tài liệu này tập trung vào **AI flow end-to-end**, không chỉ UI:

```text
User intent
  → Mode/capability routing
  → Context bootstrap
  → LLM turn
  → Tool decision
  → Tool execution + observation
  → More context or final answer/proposal
  → Validate/repair
  → Render transcript + persist session
```

## 1. Hiện trạng tổng thể

Forge đã có nền tảng khá đúng hướng:

| Khu vực | Hiện trạng | Đánh giá |
|---|---|---|
| Agent loop | Có loop LLM + tool, dùng chung qua `packages/ai` | Tốt, nhưng cần thêm contract/eval chống tool loop kém |
| Tool registry/capability | Có phân quyền theo mode/capability | Đúng hướng, cần đồng bộ hơn giữa CLI/TUI/IDE |
| Context retrieval | Có semantic/codebase search, file read, tree, ranking | Cần kiểm soát freshness, budget, duplicate context |
| CLI headless | Có `forge agent run` và output human/json | Cần event stream đẹp hơn và lỗi provider rõ hơn |
| TUI | Đã bắt đầu render giống Cursor: tool call, collapsed output, input card | Cần hoàn thiện review/expand/session/mode parity |
| Proposal/transaction | Agent propose, apply qua transaction | Rất tốt cho an toàn; cần render diff/proposal tốt hơn |
| Evaluation | Có `AI_RELIABILITY.md`, fake/live provider trial | Cần mở rộng thành benchmark AI flow thật |
| Provider | Gemini/Ollama/fake có transport riêng | Cần retry/backoff/quota diagnostics và model capability metadata |

Kết luận: Forge đã có “xương sống” của AI IDE. Điểm thiếu lớn không phải là thêm một tool riêng lẻ, mà là làm cho **toàn bộ vòng lặp agent có thể quan sát, kiểm chứng, phục hồi và đồng bộ giữa các surface**.

## 2. Các điểm cần cải thiện chính

### 2.1. Tách rõ human transcript, JSON machine output và event stream

Vấn đề hiện tại:

- Người dùng mong CLI render giống Cursor: dòng tool call, output rút gọn, diff màu, answer rõ.
- `--json` hiện phù hợp cho machine, nhưng nếu dùng trong terminal thường sẽ tạo cảm giác “dump raw JSON”.
- Chưa có NDJSON stream chuẩn để IDE/CI consume từng event.

Cần làm:

- Human mode: mặc định đẹp, không dump object lớn.
- `--json`: chỉ dùng cho kết quả cuối hoặc machine-compatible object.
- `--events ndjson`: stream từng event ổn định: `session_started`, `llm_turn`, `tool_call`, `tool_result`, `proposal_created`, `validation_started`, `final_answer`, `error`.

Exit gate:

- Chạy cùng một task ở 3 mode và snapshot output:
  - Human readable trong terminal.
  - Final JSON parse được bằng `jq`.
  - NDJSON mỗi dòng parse được và có schema version.

### 2.2. Tool loop contract cần trở thành invariant được test

Vấn đề hiện tại:

- Prompt đã hướng dẫn LLM gọi tool khi thiếu context, nhưng chưa đủ kiểm chứng tự động.
- Agent có thể gọi tool trùng ý nghĩa, lấy quá nhiều context, hoặc trả lời khi evidence chưa đủ.
- Chưa có step-level scoring: task cần bao nhiêu tool, tool nào hợp lý, có loop thừa không.

Cần làm:

- Chuẩn hóa contract:
  - Nếu thiếu context, gọi đúng một tool tập trung.
  - Sau mỗi tool result phải quyết định: đủ evidence hay cần tool tiếp.
  - Không lặp lại tool với cùng query/path khi không có thông tin mới.
  - Final answer phải cite/path tới context đã đọc khi nói về code.
- Thêm `loop_guard`:
  - detect duplicate tool call;
  - budget theo tool count/token/time;
  - stop reason rõ: `completed`, `max_steps`, `duplicate_loop`, `provider_error`, `needs_approval`.
- Thêm eval fixture cho các case:
  - task chỉ cần search;
  - task cần search rồi read file;
  - task cần list tree trước;
  - task không đủ context và phải nói rõ giới hạn;
  - task không được sửa file ở read-only mode.

Exit gate:

- `fake` provider test được event order.
- Live Gemini/Ollama task nhỏ đạt tỉ lệ “tool sequence hợp lý” theo rubric.

### 2.3. Context bootstrap cần thông minh hơn theo mode

Vấn đề hiện tại:

- Context hiện có nhiều nguồn: AGENTS.md, recent files, semantic search, tree, session, memory.
- Chưa thấy một “context manifest” đủ dễ debug cho mỗi run: đã đưa gì vào prompt, vì sao, token bao nhiêu, bị loại gì.
- Với project lớn, chỉ semantic search chưa đủ; cần kết hợp structural/AST/tree-sitter/fallback textual.

Cần làm:

- Mỗi run tạo `ContextManifest` inspectable:
  - workspace root, branch, dirty summary;
  - explicit `@file`;
  - files/chunks selected;
  - source: `semantic`, `recent`, `agent_memory`, `AGENTS.md`, `tool_result`;
  - token estimate;
  - redaction/ignore reason.
- Routing theo mode:
  - Ask: ưu tiên context nhỏ, read-only, trả lời nhanh.
  - Plan: ưu tiên map module/file ownership, không tạo edit.
  - Agent: context theo task + proposal/validation history.
- Hybrid retrieval:
  - semantic vector;
  - lexical search;
  - tree/file structure;
  - language chunker/tree-sitter nếu có parser;
  - fallback structural chunker nếu ngôn ngữ chưa có AST.

Exit gate:

- Với cùng task, có thể in `forge context explain <session>` hoặc `/context`.
- Manifest cho biết vì sao file A được chọn và file B bị bỏ.
- `.env`, vendor, generated files không lọt vào index/context mặc định.

### 2.4. Error taxonomy từ provider tới UI cần nhất quán

Vấn đề hiện tại:

- Khi Gemini quota/rate limit, người dùng thấy `agent provider failed`, không đủ actionable.
- Provider errors cần đi xuyên qua transport → agent loop → CLI/TUI/IDE.

Cần làm:

- Chuẩn hóa lỗi:
  - `authentication_failed`;
  - `rate_limit_exceeded`;
  - `context_length_exceeded`;
  - `network_error`;
  - `provider_bad_request`;
  - `tool_schema_rejected`;
  - `unknown_provider_error`.
- Human UI phải đưa gợi ý ngắn:
  - retry later;
  - switch model/provider;
  - reduce context;
  - check credentials.
- JSON/event stream phải có `error.code`, `error.provider`, `error.retryable`, `error.retry_after_ms?`.

Exit gate:

- Mock transport trả từng lỗi và CLI/TUI render đúng message.
- Live Gemini rate limit không còn hiện “provider failed” chung chung.

### 2.5. Session/resume phải lưu đủ trạng thái agent, không chỉ chat

Vấn đề hiện tại:

- Session đã tồn tại, nhưng để giống AI IDE thật, resume cần khôi phục context run: task, mode, capability, tool calls, proposal, validation, final answer.
- TUI/CLI/IDE cần cùng đọc một session model.

Cần làm:

- Session event log append-only:
  - user input;
  - mode/capability/provider/model;
  - context manifest ref;
  - LLM request summary;
  - tool call/result;
  - proposal path;
  - validation result;
  - final answer;
  - error.
- `/resume` trong TUI phải hiển thị transcript đã collapse đúng trạng thái.
- `forge agent sessions` cần cho biết:
  - last task;
  - status;
  - provider/model;
  - edits/proposal;
  - tokens/latency/tool count.

Exit gate:

- Run task → quit → resume → vẫn thấy tool history/proposal/final answer.
- IDE mở cùng session và render giống CLI ở mức semantic.

### 2.6. Proposal/diff flow cần gần Cursor hơn nhưng vẫn giữ transaction safety

Vấn đề hiện tại:

- Forge có lợi thế: agent không ghi trực tiếp disk mà propose edit.
- Nhưng UX cần giúp người dùng thấy edit như Cursor: file edited, `+/-`, truncated output, review/expand.

Cần làm:

- Transcript-level diff summary:
  - `Edited path +N -M`;
  - snippet có màu;
  - collapse nếu dài;
  - phím/command expand review.
- Proposal-level actions:
  - review;
  - accept all;
  - accept file;
  - reject hunk/file;
  - apply;
  - undo.
- Validation attached to proposal:
  - command run;
  - success/failure;
  - repair attempts;
  - final status.

Exit gate:

- Một task sửa file hiển thị đúng:
  - file summary;
  - diff snippet;
  - command verify;
  - apply/undo path.

### 2.7. Tool approval/policy phải dễ hiểu theo mode

Vấn đề hiện tại:

- Có matrix Ask/Plan/Agent nhưng UX chưa đủ rõ cho user.
- Tool risk/approval chưa luôn được giải thích ở thời điểm tool sắp chạy.

Cần làm:

- Một policy model duy nhất cho CLI/TUI/IDE:
  - `auto`;
  - `ask`;
  - `never`;
  - `dangerous_blocked`.
- Render trước tool call:
  - tool name;
  - reason;
  - args compact;
  - risk;
  - why approval needed.
- Mode-specific default:
  - Ask: read-only tools auto, write/run blocked.
  - Plan: read-only + spec, no mutation.
  - Agent: propose edit allowed, run command needs approval unless allowlisted.

Exit gate:

- Same mode/capability produces same allowed tool list in CLI and IDE.
- Unknown MCP tool mặc định high risk và cần approval.

### 2.8. Metrics cần thành first-class citizen

Vấn đề hiện tại:

- Token/latency/tool count có chỗ ghi, nhưng chưa đủ để đo “Forge làm việc hiệu quả hơn chưa”.
- Không có bảng so sánh trước/sau theo task class.

Cần làm:

- Mỗi run ghi:
  - wall latency;
  - LLM turns;
  - tool calls;
  - duplicate tool calls;
  - prompt/completion/total tokens;
  - context token budget used;
  - proposal size;
  - validation pass/fail;
  - repair attempts;
  - final status.
- `forge eval ai-flow`:
  - chạy fixture;
  - xuất JSONL + summary;
  - so sánh baseline.

Exit gate:

- Có dashboard/summary text:
  - success rate;
  - p50/p95 latency;
  - avg tool calls;
  - duplicate loop rate;
  - repair success rate.

### 2.9. Provider/model capability metadata

Vấn đề hiện tại:

- Gemini/Ollama/fake dùng chung agent flow, nhưng mỗi provider khác nhau về tool calling, token usage, rate limit, context length.
- Agent chưa luôn biết provider nào support native tool call/schema tốt đến đâu.

Cần làm:

- Provider capability:
  - max context;
  - supports native tool calls;
  - supports streaming;
  - supports structured output;
  - returns token usage;
  - retry policy;
  - safety/blocked response mapping.
- Model selection:
  - default model theo provider;
  - override qua CLI;
  - warning nếu task vượt context/model capability.

Exit gate:

- `forge providers list --json` trả capability.
- Agent loop điều chỉnh prompt/schema theo provider.

### 2.10. IDE parity: cùng một harness, cùng một event model

Vấn đề hiện tại:

- CLI/TUI đang tiến nhanh, nhưng nếu IDE dùng model khác thì sẽ lệch behavior.
- AI-first IDE thật cần mọi thứ phát ra event: chat panel, diff panel, tool panel, terminal panel.

Cần làm:

- Định nghĩa `AgentEvent` chung trong `packages/ai`.
- CLI human renderer, TUI renderer, IDE renderer đều consume event.
- Không để logic “agent state” nằm riêng trong UI.

Exit gate:

- Một headless run có thể replay lại thành TUI transcript.
- IDE có thể subscribe event stream và render cùng sequence.

## 3. Thứ tự ưu tiên triển khai

### P0 — Làm cho AI loop tin cậy và quan sát được

1. Chuẩn hóa `AgentEvent` chung.
2. Thêm event stream NDJSON.
3. Lưu session append-only theo event.
4. Chuẩn hóa provider error taxonomy.
5. Thêm loop guard chống duplicate tool call.

Lý do: nếu chưa quan sát được vòng lặp, mọi cải thiện sau đều khó đo.

### P1 — Làm cho context và tool use thông minh hơn

1. Context manifest per run.
2. `/context` hoặc `forge context explain <session>`.
3. Hybrid retrieval policy theo mode.
4. Tool call reason + compact args.
5. Eval fixture cho tool sequence.

Lý do: AI IDE khác biệt ở khả năng tự lấy đúng context, không phải chỉ chat với LLM.

### P2 — Làm UX giống AI IDE thật

1. Human CLI transcript hoàn chỉnh.
2. TUI expand/collapse tool result và diff.
3. Input composer/palette hoàn thiện.
4. Resume trong TUI.
5. Diff/proposal review giống Cursor nhưng apply qua transaction.

Lý do: user phải thấy agent “đang nghĩ và làm gì” một cách tường minh.

### P3 — Hoàn thiện proposal/validation/repair loop

1. Validation attached vào proposal.
2. Repair loop hiển thị từng attempt.
3. Apply/undo UX đồng bộ CLI/TUI/IDE.
4. Run allowlist + approval policy rõ.

Lý do: AI-first IDE phải không chỉ sửa code, mà còn chứng minh sửa đúng.

### P4 — Benchmark và regression gate

1. `forge eval ai-flow`.
2. Baseline fake provider.
3. Live provider smoke test có retry/backoff.
4. Summary metrics trước/sau.
5. CI optional gate cho fake eval.

Lý do: cần kiểm chứng hiệu quả công việc bằng số liệu, không chỉ cảm giác.

## 4. Backlog chi tiết

| ID | Việc cần làm | Priority | Area | Acceptance test |
|---|---:|---|---|---|
| AI-FLOW-001 | Định nghĩa `AgentEvent` schema chung | P0 | `packages/ai` | ✅ CLI dùng schema chung; TUI/IDE consume sau |
| AI-FLOW-002 | Thêm `--events ndjson` cho `forge agent run` | P0 | CLI | ✅ Mỗi dòng parse được bằng JSON parser |
| AI-FLOW-003 | Session append-only event log | P0 | workspace | Resume thấy lại tool/proposal/final |
| AI-FLOW-004 | Provider error taxonomy end-to-end | P0 | provider/agent/CLI | Gemini rate limit render actionable |
| AI-FLOW-005 | Loop guard duplicate tool call | P0 | agent loop | Duplicate query bị cảnh báo/stop có reason |
| AI-FLOW-006 | Context manifest per run | P1 | context | `/context` hiển thị source/token/reason |
| AI-FLOW-007 | Tool call reason + args preview | P1 | agent loop/UI | Transcript có reason và args compact |
| AI-FLOW-008 | Hybrid retrieval policy theo mode | P1 | context/search | Ask/Plan/Agent context khác nhau có chủ đích |
| AI-FLOW-009 | AI flow eval fixtures | P1 | eval | fake provider kiểm được tool sequence |
| AI-FLOW-010 | TUI resume session | P2 | CLI TUI | `/resume <id>` restore transcript |
| AI-FLOW-011 | TUI/CLI diff snippet renderer | P2 | CLI TUI | `Edited file +N -M` + expand review |
| AI-FLOW-012 | Proposal action model: accept file/hunk | P2 | proposal/UI | Review granular không phá transaction |
| AI-FLOW-013 | Validation result attached proposal | P3 | repair/validation | Final answer nêu verify pass/fail |
| AI-FLOW-014 | Provider capability metadata | P3 | provider | `forge providers list --json` có capability |
| AI-FLOW-015 | `forge eval ai-flow` summary | P4 | eval | success/latency/tool/tokens report |

## 5. Command kiểm chứng đề xuất

### Build/test cơ bản

```bash
zig build
zig build test
zig build test-ai
```

### Smoke test human CLI

```bash
zig build run -- agent run \
  "kiểm tra nhanh agent loop dùng tool nào để đọc context, trả lời ngắn gọn" \
  --provider fake \
  --mode agent \
  --capability read_only \
  --max-steps 4
```

### Smoke test JSON output

```bash
zig build run -- agent run \
  "kiểm tra nhanh agent loop dùng tool nào" \
  --provider fake \
  --mode agent \
  --capability read_only \
  --max-steps 4 \
  --json
```

### Smoke test NDJSON event stream

```bash
zig build run -- agent run \
  "kiểm tra nhanh agent loop dùng tool nào" \
  --provider fake \
  --mode ask \
  --max-steps 4 \
  --events ndjson \
  | python3 -c 'import json,sys; [json.loads(line) for line in sys.stdin if line.strip()]'
```

### Smoke test live Gemini

Chạy khi quota/API key ổn:

```bash
zig build run -- agent run \
  "kiểm tra nhanh agent loop dùng tool nào để đọc context, trả lời ngắn gọn" \
  --provider gemini \
  --mode agent \
  --capability read_only \
  --max-steps 4
```

Kỳ vọng nếu provider lỗi:

- rate limit → báo retry/switch provider/model;
- auth lỗi → báo kiểm tra credentials;
- context quá dài → báo giảm context hoặc đổi model;
- network lỗi → báo retry/network.

## 6. Định nghĩa “AI-first IDE thật” cho Forge

Forge chỉ nên coi một flow là đạt chuẩn khi thỏa đủ:

1. User đưa intent tự nhiên.
2. Agent biết mode và quyền hiện tại.
3. Agent lấy context đúng, giải thích được context đó.
4. Mỗi tool call được render rõ: tool gì, args gì, vì sao gọi.
5. Agent không lặp tool vô ích.
6. Nếu sửa code, chỉ tạo proposal có review/transaction.
7. Validation/repair có bằng chứng.
8. Final answer tóm tắt đúng việc đã làm, file đã động vào, verify gì đã chạy.
9. Session resume/replay được.
10. Cùng flow render nhất quán trên CLI/TUI/IDE.

## 7. Next implementation slice đề xuất

Slice tiếp theo nên nhỏ nhưng có tác động lớn:

```text
AgentEvent schema
  → CLI human renderer consume event
  → NDJSON event stream
  → session event log
  → provider errors as typed events
  → eval fixture assert event sequence
```

Đây là lớp “xương sống quan sát được”. Sau khi có nó, việc làm đẹp TUI, IDE panel, context explain, diff review hay eval đều bám vào cùng một event model, tránh mỗi UI tự chế logic riêng.

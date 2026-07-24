# RFC-0013: Inline Tab Completion v1

> **Trạng thái:** Proposed
> **Tác giả:** truonglv95 <anhtruonglavm2@gmail.com>
> **Ngày:** 2026-07-24
> **Liên kết:** [AI Workflow Evaluation](../evaluation/AI_WORKFLOW_EVALUATION.md) ·
> [Capability Matrix](../CAPABILITY_MATRIX.md)

## 1. Tóm tắt

Wire module `packages/ai/src/inline_completion.zig` đã có vào Forge IDE, thêm
ghost text rendering, và expose `forge complete` CLI. Mục tiêu: đạt parity với
Cursor Copilot cho inline tab completion, với p50 latency < 500ms và p95 <
1500ms.

## 2. Động lực

Capability Matrix ghi rõ "Inline AI completion: No" mặc dù code đã tồn tại.
Đây là gap lớn nhất vs Cursor (người dùng kỳ vọng tab completion như baseline).
Without this, Forge không thể dogfood cho editing workflow hàng ngày.

**Tại sao không deferred nữa?**
- Code đã có 80% (`inline_completion.zig` 197 LOC với prompt builder + provider
  call + fence stripping).
- Chỉ cần wire ghost text rendering + debounce + accept/dismiss.
- ROI cao: là feature user-facing rõ ràng nhất.

## 3. Thiết kế

### 3.1. Architecture

```text
Keystroke in editor
  → EditorBuffer mutation
  → Debounce timer (150ms default)
  → InlineCompletionRequest{prefix, suffix, file_path, language}
  → inline_completion.complete()
  → Provider call (streaming nếu support)
  → Ghost text overlay trong editor
  → Tab to accept | Esc to dismiss | Continue typing to dismiss
```

### 3.2. Configuration

```toml
# forge.toml
[ai.inline]
enabled = true
debounce_ms = 150
max_tokens = 64
min_prefix_chars = 3          # không trigger nếu prefix < 3 chars
timeout_ms = 3000
multiline = true              # cho phép multi-line completion
accept_partial = false        # Tab accept toàn bộ hay line-by-line
provider = "auto"             # override provider cho inline
model = ""                    # override model (ví dụ "gemini-2.0-flash")
excluded_filetypes = ["text", "log"]
excluded_paths = [".forge/", "vendor/", "third_party/"]
```

### 3.3. Editor integration

```zig
// apps/forge-ide/src/workbench/ghost_completion.zig (extend)

pub const CompletionState = struct {
    pending_request: ?*InlineCompletionRequest = null,
    debounce_timer: ?Timer = null,
    ghost_text: ?[]const u8 = null,
    ghost_range: ?BufferRange = null,
    last_keystroke_ms: i64 = 0,

    pub fn shouldTrigger(self: *CompletionState, buffer: *EditorBuffer, cursor: BufferPos) bool {
        if (!config.enabled) return false;
        if (cursor.column < config.min_prefix_chars) return false;
        const now = timestamp_ms();
        if (now - self.last_keystroke_ms < config.debounce_ms) return false;
        // Skip excluded filetypes/paths
        const lang = inline_completion.detectLanguage(buffer.path);
        if (contains(config.excluded_filetypes, lang)) return false;
        for (config.excluded_paths) |p| {
            if (std.mem.startsWith(u8, buffer.path, p)) return false;
        }
        return true;
    }
};
```

### 3.4. Ghost text rendering

- Render ghost text với alpha 40% (or theme-defined `editorGhostText` color).
- Không thay đổi buffer content cho đến khi Tab pressed.
- Multi-line ghost text: render full block, Tab accept toàn bộ.
- Single-line ghost text: render cùng line, Tab accept line đó.

### 3.5. CLI: `forge complete`

```bash
forge complete --file src/main.zig --line 42 --char 15 [--provider auto] [--json]
```

Output (human):
```text
Completion for src/main.zig:42:15:
  fn calculateTotal(items: []const Item) i64 {
```

Output (JSON):
```json
{
  "type": "inline_completion",
  "file": "src/main.zig",
  "line": 42,
  "character": 15,
  "text": "fn calculateTotal(items: []const Item) i64 {",
  "is_multiline": false,
  "latency_ms": 420,
  "provider": "gemini",
  "model": "gemini-2.0-flash",
  "tokens": { "input": 120, "output": 15 }
}
```

### 3.6. Provider optimizations

- **Streaming:** Nếu provider support streaming (Gemini, OpenAI, OpenRouter),
  stream first chunk để giảm TTFB.
- **Caching:** Cache completion theo `(file_hash, line, char)` — reuse nếu user
  quay lại cùng position trong 30s.
- **Cancellation:** Nếu user tiếp tục typing, cancel pending request.
- **Fallback:** Nếu provider timeout/error, silent fail (không show error).
- **Local model:** Khuyến nghị Ollama cho offline / privacy-sensitive workflow.

### 3.7. Acceptance UX

| Key | Hành động |
|---|---|
| `Tab` | Accept toàn bộ ghost text |
| `Cmd+→` | Accept word-by-word (Cursor style) |
| `Cmd+Enter` | Accept line-by-line |
| `Esc` | Dismiss |
| Any keystroke | Dismiss + re-trigger debounce |

## 4. Cancellation & threading

- Inline completion chạy trên **worker thread**, không bao giờ block render.
- Cancellation token propagate vào `provider.completeTurn()`.
- Nếu user typing mới trong khi request đang chạy, cancel ngay (không đợi).
- Ghost text chỉ render khi response trả về trước keystroke tiếp theo.

## 5. Testing

### 5.1. Unit tests

```zig
test "detectLanguage maps common extensions" { ... }  // đã có
test "buildPrompt includes language and cursor marker" { ... }  // đã có
test "stripFences removes markdown wrappers" { ... }  // đã có

// Thêm:
test "debounce does not trigger within window" { ... }
test "cancellation aborts pending request" { ... }
test "excluded_filetypes skip completion" { ... }
test "min_prefix_chars gate" { ... }
test "cache reuse for same position" { ... }
```

### 5.2. Integration tests

```bash
# CLI integration
forge complete --file fixtures/sample.txt --line 1 --char 0 --provider fake --json
# Expect: text non-empty, latency_ms > 0

# Eval
forge eval inline --corpus fixtures/eval/inline_completion.json
# Expect: success_rate > 0.8, p50 < 500ms
```

### 5.3. Eval corpus

`fixtures/eval/inline_completion.json`:
```json
{
  "tasks": [
    {
      "id": "zig-fn-sig",
      "file": "test.zig",
      "content_before": "pub fn calculate",
      "content_after": "",
      "expected_contains": ["fn", "(", ")"]
    },
    {
      "id": "python-import",
      "file": "test.py",
      "content_before": "from typing import ",
      "content_after": "",
      "expected_contains": ["List", "Dict", "Optional"]
    }
  ]
}
```

## 6. Metrics

| Metric | Target | Tool |
|---|---|---|
| p50 latency | < 500ms | `forge eval inline` |
| p95 latency | < 1500ms | `forge eval inline` |
| Acceptance rate | > 20% | IDE telemetry |
| Cancellation rate | < 30% | IDE telemetry |
| Cache hit rate | > 15% | IDE telemetry |

## 7. Rollout plan

1. **Week 1:** Wire `ghost_completion.zig` → `inline_completion.complete()`.
   Ghost text rendering. Manual test với fake provider.
2. **Week 2:** Debounce + cancellation + config. `forge complete` CLI.
3. **Week 3:** Streaming + caching. Eval corpus + `forge eval inline`.
4. **Week 4:** Polish + dogfood + provider optimization (Ollama local).

## 8. Risks

| Rủi ro | Giảm |
|---|---|
| Provider latency quá cao | Default Ollama cho local, fallback cloud |
| Ghost text render conflict với syntax highlight | Render layer riêng, alpha blending |
| Cache stale | Invalidate trên file save, TTL 30s |
| Streaming parser bug | Fallback non-streaming nếu parse fail |
| User annoyance (too many suggestions) | `min_prefix_chars`, `debounce_ms` tunable |

## 9. Alternatives considered

- **Defer tiếp:** ❌ Gap vs Cursor quá lớn, không thể dogfood.
- **Use external copilot (Copilot.vim):** ❌ Phá native Zig story.
- **Local-only (Ollama bắt buộc):** ❌ User có thể prefer cloud model.
- **Single-line only:** ❌ Multi-line là baseline expectation.

## 10. Open questions

- [ ] Có nên support "completion with context" (gửi recent edits + open files)?
      → Phase 2, sau khi v1 ổn định.
- [ ] Có nên support "accept + auto-format"?
      → Phase 2, integrate với LSP formatter.
- [ ] Có nên support FIM (Fill-in-the-Middle) format cho model support?
      → Phase 2, nếu có model native FIM (CodeLlama, DeepSeek).

## 11. Exit gate

- [ ] `forge complete --json` works với 3 providers (fake, gemini, ollama)
- [ ] IDE ghost text renders + Tab accept + Esc dismiss
- [ ] p50 < 500ms, p95 < 1500ms trên eval corpus
- [ ] Cancellation không leak memory
- [ ] Config trong `forge.toml [ai.inline]` hoạt động
- [ ] `forge eval inline` exit code 0 khi success_rate > threshold

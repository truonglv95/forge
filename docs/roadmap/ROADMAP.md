# Forge Delivery Roadmap

> Canonical implementation and validation plan — last updated: 2026-07-02

This document is the source of truth for scope, order, evidence, and release
gates. The [Project Vision](../PROJECT_VISION.md) defines why Forge exists; this
roadmap defines what must be built, in which order, and how we decide whether it
is working.

## 1. Product thesis and delivery strategy

Forge is one AI-first development system with two first-party surfaces:

- `forge` CLI: the earliest test surface, automation interface, and headless
  workflow;
- Forge IDE: the native visual surface for editing, context, diff review, and
  task feedback.

Both surfaces must compose the same kernel, workspace, transaction, task, and
AI services. Neither application may contain a private implementation of the
core change workflow.

The product thesis to prove is:

> A developer can turn an intent into a correct, reviewable, verified, and
> undoable code change faster than with their current workflow, without giving
> up control or risking workspace data.

The previous milestone order placed the first AI workflow after a complete
native editor and LSP stack. That delayed validation of the defining product
hypothesis. The new order proves the shared safe-change engine and a narrow AI
CLI slice first, then puts the proven workflow into the native IDE.

```text
Foundation
    -> safe workspace/change engine
    -> deterministic CLI workflow
    -> AI-assisted CLI experiment
    -> native IDE shell and editor
    -> AI workflow inside IDE
    -> language intelligence and dogfood alpha
```

Renderer work remains an early, time-boxed risk spike, but it does not block
headless product validation.

## 2. Non-negotiable product requirements

### 2.1 Shared workflow

The canonical change lifecycle is:

```text
Open workspace -> understand context -> define intent -> propose change
-> inspect diff -> approve/reject -> apply transaction -> run checks
-> inspect result -> keep or undo
```

- Every step is representable without a GUI.
- The IDE adds interaction and visualization, not different semantics.
- A run has a stable ID and records inputs, decisions, tool results, and final
  state locally.

### 2.2 Safety and control

- AI and LSP code can propose `WorkspaceEdit` values but cannot write files.
- Only the workspace transaction service can mutate the filesystem.
- Every modification and deletion has a content precondition.
- Multi-file apply and undo are all-or-nothing.
- Stale, excluded, out-of-root, or structurally invalid edits are rejected.
- No destructive change is approved implicitly in the initial product.
- Provider, cancellation, process, or validation failure never loses user data.

### 2.3 AI-first behavior

AI-first does not mean chat-first or autonomous-by-default. It means the system
is designed around intent, context, proposed actions, evidence, and developer
decisions:

- context is explicit, inspectable, budgeted, and redactable;
- plans and edits are structured outputs, not prose that secretly mutates state;
- tool execution is capability-scoped and observable;
- diffs, diagnostics, and validation results are primary UI objects;
- the user can interrupt, reject, partially reconsider, or undo a run;
- equivalent headless operations have stable machine-readable output.

### 2.4 CLI requirements

- Human-readable output by default and versioned `--json` output for automation.
- Stable exit codes and no prompts when `--non-interactive` is used.
- `--dry-run` or equivalent preview before mutation.
- stdout carries results; stderr carries diagnostics/progress.
- cancellation propagates to child tasks and provider streams.
- commands work from the workspace root or an explicit `--workspace` path.
- credentials never appear in logs, run records, or error output.

### 2.5 Native IDE requirements

- Native macOS MVP; the exact window/GPU/text stack requires a measured RFC.
- Responsive editing is independent of filesystem, task, LSP, and model latency.
- The IDE supports the complete safe-change loop, not merely an embedded chat.
- Keyboard-first navigation, command palette, readable diff review, and basic
  accessibility are release requirements.
- Unsaved buffers and external file changes participate in conflict detection.

## 3. Prioritization model

Work is ordered by four factors:

1. **Safety dependency:** could later work corrupt or overwrite data without it?
2. **Hypothesis value:** does it test whether AI-first workflow is useful?
3. **Shared leverage:** is it reused by both CLI and IDE?
4. **Risk reduction:** does it cheaply answer a hard-to-reverse technical
   question?

Priority classes:

| Class | Meaning | Scheduling rule |
|---|---|---|
| P0 | Required for safe vertical slice | Blocks the next product experiment |
| P1 | Required for useful MVP | Build after its P0 dependency is proven |
| P2 | Required for daily dogfood | Add from observed friction, not speculation |
| P3 | Expansion | Keep off the MVP critical path |

No feature is complete because code exists. It is complete only when its tests,
demo, instrumentation, and exit evidence exist.

## 4. Milestone overview

| Milestone | Outcome | Priority | Status |
|---|---|---:|---|
| M0 | Reproducible foundation + renderer decision | P0 | **In progress** |
| M1 | Safe shared workspace and execution engine | P0 | Not started |
| M2 | Deterministic headless CLI vertical slice | P0 | Not started |
| M3 | AI-assisted CLI proof | P0 | Not started |
| M4 | Native IDE editing foundation | P1 | Not started |
| M5 | AI-first IDE vertical slice | P1 | Not started |
| M6 | Language intelligence + dogfood alpha | P2 | Not started |
| M7 | Beta hardening + extensibility decision | P2/P3 | Not started |

Only one delivery milestone is in progress at a time. Explicitly named spikes
may run ahead when they reduce critical risk and do not create production
architecture by accident.

## 5. Current baseline and gap analysis

### Verified on 2026-07-02

- [x] Zig 0.16.0 monorepo builds and all current tests pass.
- [x] Package graph exists for `util`, `core`, `kernel`, `workspace`, `editor`,
  `renderer`, `lsp`, `ai`, and `plugin`.
- [x] CLI exposes only `version`, `doctor`, and `help`.
- [x] Minimal lifecycle, synchronous command dispatcher, and typed event bus
  contracts have unit tests.
- [x] `WorkspaceEdit` structural validation covers basic path, precondition,
  duplicate, range, and overlap rules.
- [x] RFC-0001 through RFC-0003 establish package direction, ownership, and
  transaction authority.
- [x] Local full check passes: format/AST check, build, and tests.

### Material gaps

- There is no filesystem transaction implementation, rollback, history, or
  recovery journal.
- There is no real workspace open/index/search/watch service.
- There is no task runtime, cancellation primitive, structured logging, or run
  record.
- The CLI cannot yet perform useful project work.
- There is no model provider, context builder, secret policy, proposal parser,
  diff review, or AI evaluation harness.
- There is no native application target or renderer prototype.
- Editor, LSP, AI, renderer, and plugin packages currently expose placeholders
  or small domain contracts rather than usable subsystems.
- Current metrics describe what might be measured but have no reference corpus,
  collection schema, or pass/fail thresholds.

## 6. M0 — Foundation and hard decisions

**Outcome:** development can proceed without unresolved repository or renderer
assumptions, while headless work is unblocked.

### M0.1 Repository baseline — completed

- [x] Connect all packages and `apps/forge-cli` to `build.zig`.
- [x] Run package and CLI tests through `zig build test`.
- [x] Add format, build, test, and CLI smoke checks to CI.
- [x] Pin Zig, document bootstrap, and enforce commit conventions.
- [x] Accept RFCs for package boundaries, ownership, and workspace edits.

### M0.2 Renderer spike — P0 technical risk

- [ ] Create a disposable `tools/renderer-spike` target, not production UI code.
- [ ] Open/close a native macOS window and handle resize, scale, and focus.
- [ ] Create a GPU surface, clear/present frames, and recover from surface loss.
- [ ] Discover a system monospace font; shape ASCII, Vietnamese, emoji, ligature,
  combining-mark, RTL, and fallback samples.
- [ ] Render 10k visible glyphs and collect frame CPU/GPU time.
- [ ] Measure cold/warm startup, idle RSS, resize behavior, and input-to-frame
  latency on a named reference machine.
- [ ] Compare at least two viable stack compositions or document why a candidate
  is disqualified before implementation.
- [ ] Write the platform/renderer RFC, including dependencies, binary-size cost,
  IME/accessibility path, licensing, failure modes, and fallback strategy.
- [ ] Remove or clearly isolate abandoned spike code.

### M0 exit gate

- [x] Clean local build and test pass.
- [ ] CI run on the target branch is green.
- [ ] Renderer RFC is accepted with measurements attached.
- [ ] `apps/forge-ide` can be added without changing package ownership rules.

## 7. M1 — Safe shared workspace and execution engine

**Outcome:** one headless engine can inspect a workspace, execute cancellable
tools, and apply/undo file transactions safely. This is the foundation for both
applications and every future AI operation.

### M1.1 Workspace identity and path security — P0

- [ ] `WorkspaceRoot` opens an explicit canonical directory.
- [ ] Normalized relative path type rejects absolute paths, `..` escape, NUL,
  invalid encodings, and platform-specific aliases.
- [ ] Define symlink policy for read, search, watch, and write separately.
- [ ] Define case-sensitivity and Unicode-normalization behavior.
- [ ] Load ignore rules from built-ins, VCS ignores, and Forge configuration with
  deterministic precedence.
- [ ] Bound file size, traversal depth, and entry count with explicit diagnostics.

**Evidence:** temporary-directory tests for traversal, symlink escape, permission
failure, case collision, deleted paths, and ignored files.

### M1.2 File snapshots and atomic primitives — P0

- [ ] Read files into versioned snapshots containing bytes, metadata, and a
  collision-resistant content digest suitable for stale-write checks.
- [ ] Implement create/replace/delete primitives using same-directory temporary
  files, flush/close/rename semantics, and explicit metadata policy.
- [ ] Preserve configured newline/BOM behavior; never silently normalize bytes.
- [ ] Detect changes between preview and apply.
- [ ] Report structured errors with path, operation, and recoverability.

**Evidence:** failure injection at open, write, flush, rename, and cleanup stages;
no test may leave a partially written destination.

### M1.3 Transaction service and history — P0

- [ ] Extend `WorkspaceEdit` validation to path containment and bounds against
  the exact snapshot.
- [ ] Materialize before/after images and a deterministic diff before approval.
- [ ] Define transaction states: proposed, validated, approved, applying,
  applied, validation_failed, undone, and recovery_required.
- [ ] Apply multi-file create/modify/delete atomically or restore all originals.
- [ ] Persist a write-ahead recovery record before the first mutation.
- [ ] Record transaction ID, source, hashes, timestamps, and result without
  storing secrets.
- [ ] Undo the whole transaction only when current post-apply preconditions hold;
  otherwise surface a conflict instead of overwriting later work.
- [ ] Recover or roll back an interrupted transaction on next workspace open.

**Evidence:** stale-write, process-interruption, disk-full, permission-change,
partial-rename, rollback-failure, and undo-conflict tests.

### M1.4 Runtime, tasks, and observability — P0

- [ ] Service registry with deterministic initialization and reverse teardown.
- [ ] Cancellation token/source with parent-child propagation and idempotence.
- [ ] Bounded worker/task runtime with explicit ownership and completion result.
- [ ] Child-process runner with argv (no implicit shell), cwd, environment allow
  list, stdout/stderr streaming, timeout, cancellation, and process-group cleanup.
- [ ] Structured diagnostics and logs with automatic secret redaction.
- [ ] Stable `RunId`, `TaskId`, `TransactionId`, and correlation fields.
- [ ] Local JSONL run records with schema version and configurable retention.

### M1.5 Config, tree, search, and watch — P1

- [ ] Layer defaults, user config, workspace config, environment, and CLI flags
  with documented precedence and provenance.
- [ ] Strict schema validation with actionable errors and a config inspection
  command/API.
- [ ] Incremental file tree and filename search.
- [ ] Bounded literal text search with binary/large-file handling.
- [ ] Watcher abstraction with coalescing, overflow/rescan, rename, ignore, and
  self-write suppression semantics.

### M1 exit gate

- [ ] All ownership, cancellation, transaction, and recovery tests pass without
  leaks under `std.testing.allocator` where applicable.
- [ ] A fixture workspace can be scanned, searched, watched, modified, and fully
  undone using package APIs.
- [ ] No shell, provider, LSP, or UI dependency exists in the transaction core.
- [ ] Failure evidence is stored in CI artifacts for injected failure tests.

## 8. M2 — Deterministic headless CLI vertical slice

**Outcome:** Forge is useful without AI and exposes the stable workflow that AI
and the IDE will later orchestrate.

### M2.1 CLI contract — P0

- [ ] Central argument parser, consistent help, stable exit-code registry, and
  errors that identify the failed operation.
- [ ] Global flags: `--workspace`, `--json`, `--no-color`, `--quiet`,
  `--non-interactive`, and cancellation-friendly signal handling.
- [ ] Version every machine-readable response and keep stdout/stderr separated.
- [ ] Golden tests for human output and JSON schema/exit-code contract tests.

### M2.2 Workspace commands — P0

- [ ] `forge inspect [path]`: root, config provenance, summary, and file tree.
- [ ] `forge search <query>`: deterministic filename/text results.
- [ ] `forge watch`: normalized event stream and overflow diagnostics.
- [ ] `forge doctor`: toolchain, credentials presence (never value), config,
  writable paths, and platform capability checks.

### M2.3 Change and validation commands — P0

- [ ] `forge diff <proposal>`: validate and render a proposal without mutation.
- [ ] `forge apply <proposal> --dry-run`: machine/human preview.
- [ ] `forge apply <proposal>`: require interactive approval unless an explicit,
  narrowly scoped approval flag is passed.
- [ ] `forge undo <transaction-id>` and `forge history`.
- [ ] `forge task <name>` plus first-class `fmt`, `build`, and `test` aliases
  configured as argv arrays.
- [ ] `forge check`: run the configured validation pipeline and summarize
  diagnostics, duration, and exit status.

### M2.4 Reproducible evaluation fixtures — P0

- [ ] Add small fixture repos with known searches, edits, test outcomes, Unicode,
  symlinks, permissions, and conflicts.
- [ ] Add a benchmark command/script that records machine, commit, corpus, and
  configuration.
- [ ] Capture baseline scan/search/apply/undo/task latency and peak memory.

### M2 exit gate

- [ ] Demo: inspect Forge, search a symbol, preview a two-file change, apply it,
  run checks, inspect history, and undo it.
- [ ] The demo succeeds in both human and `--json --non-interactive` modes.
- [ ] Ctrl-C leaves no child process, temporary file, or half-applied transaction.
- [ ] CLI behavior is covered by black-box tests, not only package unit tests.

## 9. M3 — AI-assisted CLI proof

**Outcome:** test the AI-first product hypothesis at minimum UI cost. A developer
can ask for a bounded change, inspect its context and proposal, apply it, verify
it, and undo it from the CLI.

### M3.1 Provider boundary and credentials — P0

- [ ] Provider-neutral streaming interface for model metadata, usage, finish
  reason, cancellation, structured output, and normalized errors.
- [ ] Implement one provider first; a fake deterministic provider is mandatory
  for tests before a second real provider is considered.
- [ ] Store secrets in macOS Keychain or accept process environment injection;
  never store credentials in `forge.toml`.
- [ ] Define retry/backoff only for safe, idempotent requests.
- [ ] Record provider/model identity and token/latency totals without recording
  raw secrets or source content by default.

### M3.2 Context engine — P0

- [ ] Context sources: explicit files/ranges, current intent, workspace summary,
  search results, selected diagnostics, and project instructions.
- [ ] Deterministic token/byte budget with per-item cost and inclusion reason.
- [ ] Respect ignores, binary/size limits, sensitive-file patterns, and explicit
  deny rules before provider serialization.
- [ ] Detect common secret shapes and block or require explicit one-time consent.
- [ ] `forge context ...` previews exactly what would leave the machine, with
  redactions and exclusion reasons.
- [ ] Context packing and truncation are unit tested independently of a provider.

### M3.3 Structured proposal protocol — P0

- [ ] Versioned schema for intent summary, assumptions, affected files,
  `WorkspaceEdit`, and suggested validation tasks.
- [ ] Strict parser with bounded sizes and useful repair feedback; prose is never
  interpreted as an implicit file operation.
- [ ] Re-read and re-check snapshots after model completion.
- [ ] Reject out-of-scope paths and stale proposals; defer automatic rebase until
  evidence shows it is needed.
- [ ] Deterministic fake-provider fixtures for valid, malformed, stale,
  over-budget, and malicious outputs.

### M3.4 AI CLI workflow — P0

- [ ] `forge ask <intent> [--file ...]`: stream progress and produce a run record
  plus proposal, but do not apply by default.
- [ ] Show context manifest before sending when requested and always make it
  available after the run.
- [ ] Show summary, assumptions, complete diff, affected-file count, and proposed
  validation before approval.
- [ ] Apply only through the M1 transaction service.
- [ ] Run the configured validation pipeline and distinguish proposal success,
  apply success, and validation success.
- [ ] `forge run show <id>` reconstructs decisions, timing, usage, transaction,
  and task results; `forge undo` remains the mutation rollback path.

### M3.5 Evaluation harness — P0

- [ ] Define 20–30 representative, bounded tasks: explanation, one-file fix,
  multi-file refactor, test addition, config change, stale conflict, secret trap,
  and impossible/ambiguous request.
- [ ] Store task prompt, fixture commit, allowed scope, expected invariants, and
  validation command; do not require an exact textual patch when behavior is the
  real requirement.
- [ ] Run each task against a no-AI/manual baseline and the Forge-assisted flow.
- [ ] Separate deterministic safety tests from variable model-quality trials.
- [ ] Review failed and later-undone proposals; label context, model, parser,
  validation, UX, or task-definition cause.

### M3 proof gate

Initial thresholds are hypotheses and must be revised only with recorded data:

- [ ] 100% of safety/adversarial fixtures prevent unauthorized or stale writes.
- [ ] 100% of applied transactions are recoverable or explicitly reported as
  requiring recovery; no silent partial state.
- [ ] At least 80% of accepted proposals pass their declared validation on the
  first applied attempt across the reference task set.
- [ ] Median prompt-to-verified time is at least 20% lower than the recorded
  manual baseline for suitable tasks.
- [ ] At least 60% of suitable-task proposals are accepted; rejection reasons are
  classified rather than hidden in a single success rate.
- [ ] Median human review time does not exceed median manual edit time.
- [ ] Zero secrets from trap fixtures appear in captured provider requests.

If safety passes but usefulness fails, improve context/proposal/evaluation before
building more UI. If usefulness succeeds, freeze the first shared workflow
contract and proceed to the native IDE.

## 10. M4 — Native IDE editing foundation

**Outcome:** a native macOS application can reliably open, edit, save, and
recover a real source file using shared workspace services.

### M4.1 Application and renderer — P1

- [ ] Add `apps/forge-ide` as a real build target using the accepted renderer RFC.
- [ ] Application lifecycle, native window, GPU surface, event loop, DPI/scale,
  focus, clipboard, drag/drop, and graceful shutdown.
- [ ] Text stack: font discovery/fallback, shaping, bidi policy, glyph atlas,
  layout, selection geometry, and cache invalidation.
- [ ] View composition primitives, input routing, focus tree, scrolling, and
  accessibility bridge baseline.
- [ ] Never execute filesystem, LSP, task, or provider work on the render thread.

### M4.2 Editor model — P0/P1

- [ ] Benchmark rope and piece-table candidates with the reference corpus and
  record the decision.
- [ ] Buffer snapshots/versioning, line index, newline/BOM preservation, dirty
  state, and large-file mode.
- [ ] Cursor, multi-cursor decision, selection, Unicode grapheme movement,
  indentation, clipboard, and input commands.
- [ ] Local undo/redo with grouping and property-based tests.
- [ ] Viewport, scrolling, hit testing, mouse/keyboard input, and macOS IME.
- [ ] Reconcile editor buffer versions with workspace transaction preconditions.

### M4.3 Minimal workbench — P1

- [ ] Workspace picker, file tree, tabs, active editor, status bar, notifications,
  command palette, and default light/dark theme.
- [ ] Open/save/save-as, atomic save, external-change detection, and explicit
  conflict UI.
- [ ] Task output panel using the shared runner.
- [ ] Crash-safe unsaved-buffer journal and restore prompt.

### M4 exit gate

- [ ] Demo: open Forge, edit a Zig file with Vietnamese/emoji text, undo/redo,
  save, detect an external conflict, restart, and restore unsaved work.
- [ ] Property/corpus tests show no content corruption across Unicode, newline,
  large-file, and randomized edit cases.
- [ ] Reference-machine baselines exist for startup, idle RSS, typing latency,
  scroll frame time, large-file open, and recovery.
- [ ] p95 input-to-frame is within the target established by the renderer RFC and
  no long-running operation blocks frames.

## 11. M5 — AI-first IDE vertical slice

**Outcome:** the exact workflow proven in M3 is available as a coherent visual
experience, and its effectiveness can be compared with the CLI.

### M5.1 Intent and context UI — P1

- [ ] Prompt composer with explicit scope, selected files/ranges, diagnostics,
  and cancel control.
- [ ] Context inspector showing included, excluded, redacted, and truncated items
  plus budget usage before provider transmission.
- [ ] Stream model progress without letting prose mutate editor state.
- [ ] Persist and reopen local run history using the shared run schema.

### M5.2 Review and decision UI — P0/P1

- [ ] Multi-file diff tree with additions/deletions, moved focus, syntax-aware
  display where available, and keyboard navigation.
- [ ] Clear stale/conflict state and ability to refresh by starting a new
  proposal; no silent rebase.
- [ ] Whole-proposal approve/reject in the first release. Per-hunk acceptance is
  deferred until transaction semantics for partial approval are specified.
- [ ] Show assumptions and validation plan beside the diff.
- [ ] Applying, failure, rollback, and recovery states remain visible and cannot
  be mistaken for success.

### M5.3 Validation and outcome UI — P1

- [ ] Stream formatter/build/test results with task status and cancellation.
- [ ] Problems list links failures back to source/diff locations.
- [ ] Keep/undo action operates on the transaction, not ad hoc editor history.
- [ ] Outcome summary shows total time, model time, review time, tool time,
  validation result, and transaction ID.

### M5 validation gate

- [ ] Repeat the M3 task set in IDE and compare completion, acceptance, first-pass
  validation, review time, total time, interruption, and undo rates.
- [ ] At least 90% of evaluators can complete the golden workflow without help.
- [ ] IDE median review time improves over CLI review without reducing defect
  detection in seeded-bad-patch tests.
- [ ] No discrepancy exists between CLI and IDE transaction/safety outcomes for
  identical fixture inputs.
- [ ] Five consecutive real dogfood tasks complete end-to-end with run records;
  failures are classified and fed into the next backlog.

## 12. M6 — Language intelligence and dogfood alpha

**Outcome:** Forge supports the everyday Zig loop well enough for the team to
use it within a published scope.

### M6.1 Parsing and LSP — P2

- [ ] Incremental syntax highlighting with bounded work and fallback behavior.
- [ ] LSP JSON-RPC framing, process lifecycle, initialize/shutdown, cancellation,
  request correlation, and capability negotiation.
- [ ] Version documents and discard stale responses.
- [ ] Diagnostics first; then hover, definition, completion, references, rename,
  and code actions in order of observed dogfood value.
- [ ] Convert rename/code-action edits into the same previewed `WorkspaceEdit`
  pipeline; LSP never mutates buffers/files directly.
- [ ] Restart crashed servers without corrupting document state.

### M6.2 Daily-use workbench — P2

- [ ] Splits, recent workspaces, session restore, search UI, problems navigation,
  settings, and keybindings.
- [ ] Decide from evidence whether task console is sufficient or a PTY terminal
  is required; implement only the selected scope.
- [ ] Accessibility audit for keyboard traversal, focus, contrast, scaling, and
  screen-reader semantics on critical flows.
- [ ] Safe mode, opt-in crash reporting, local log export, and support bundle
  with source/secret exclusion.

### M6.3 Distribution and dogfood — P2

- [ ] Reproducible release build, application identity, signing, notarization,
  packaging, update channel, rollback, and release notes.
- [ ] Define supported macOS/hardware/toolchain matrix.
- [ ] Weekly dogfood review driven by run records and categorized friction.
- [ ] Complete one real Forge repository change using only Forge for edit,
  review, validation, and commit preparation.

### M6 exit gate

- [ ] Install/update/rollback succeeds on the support matrix.
- [ ] Recovery tests lose no acknowledged or journaled user content.
- [ ] Crash-free session rate and performance targets meet published alpha gates.
- [ ] At least 70% of in-scope dogfood tasks complete without returning to
  another IDE; reasons for every escape are classified.
- [ ] Known limitations, privacy behavior, data locations, and support matrix are
  published with the alpha.

## 13. M7 — Beta hardening and extensibility decision

**Outcome:** stabilize only the interfaces proven by usage and decide expansion
based on evidence.

- [ ] Harden corruption, recovery, cancellation, provider, watcher, LSP, and
  renderer fault paths with soak and fuzz/property tests.
- [ ] Establish beta SLOs, compatibility policy, config/run-schema migrations,
  release rollback, and telemetry/privacy review.
- [ ] Stabilize command, event, workspace, task, and proposal APIs that have real
  CLI/IDE consumers.
- [ ] Threat-model extensions and spike a capability-limited WASM runtime only
  if dogfood reveals concrete extension demand.
- [ ] Spike a second platform against renderer/workspace abstractions; do not
  promise support until parity evidence exists.
- [ ] Decide whether autonomous multi-step agent work is justified. It requires
  a separate authority, sandbox, approval, and evaluation roadmap.

## 14. Measurement system

### 14.1 Required event model

Local measurement records use stable IDs and monotonic timestamps:

- run started/completed/canceled;
- context built/approved/sent with item and budget counts;
- provider first-token/completed/failed;
- proposal parsed/rejected/reviewed/approved;
- transaction applied/rolled back/undone/conflicted;
- task started/completed/canceled with exit status;
- final outcome and user-classified failure/rejection reason.

Source contents, prompts, diffs, environment values, and credentials are not
included in metrics by default. Export/transmission is opt-in; local run history
and product telemetry are separate settings.

### 14.2 Scorecard

| Dimension | Metric | Why it matters |
|---|---|---|
| Safety | unauthorized/stale writes, rollback/recovery success | Trust is a release gate |
| Correctness | first-pass and eventual validation pass rate | Measures usable output |
| Utility | task completion and IDE-escape rate | Tests real workflow value |
| Speed | prompt-to-proposal, review, tool, verified total time | Finds actual bottlenecks |
| Control | rejection, cancellation, conflict, and undo rate | Detects poor proposals/UX |
| Context | useful inclusion, truncation, secret-block rate | Diagnoses model inputs |
| Reliability | crash-free runs, orphan tasks, recovery-required rate | Measures operational quality |
| Cost | input/output tokens and provider cost per verified task | Prevents uneconomic wins |
| Performance | startup, RSS, input latency, frame time, scan/search | Protects native advantage |

Rates must always retain their denominator and task class. A high acceptance
rate is not success if validation or later-undo rates are poor.

### 14.3 Experiment protocol

1. Pin fixture commit, machine profile, Forge commit, config, provider/model, and
   task definition.
2. Record a manual/no-AI baseline for tasks where comparison is meaningful.
3. Run deterministic safety suites on every change.
4. Run variable model trials enough times to expose variance; never treat one
   successful demo as evidence.
5. Review diffs blind when comparing defect detection between interfaces.
6. Publish the scorecard and failed-case taxonomy at each milestone gate.
7. Change thresholds only through a dated roadmap/RFC update with rationale.

## 15. Cross-cutting definition of done

Every feature must include, in proportion to risk:

- an owned package/API and no forbidden dependency edge;
- unit tests plus integration or black-box tests for its public behavior;
- cancellation, teardown, error context, and leak behavior;
- documentation and CLI/IDE discoverability where applicable;
- instrumentation needed to judge its outcome;
- security/privacy review for filesystem, process, provider, or credential access;
- benchmark comparison for work on hot paths;
- fixture/demo evidence tied to an exit criterion.

Every milestone keeps format, build, test, and smoke CI green. Difficult-to-
reverse choices require an RFC. Scope changes update this roadmap in the same
change as the implementation decision.

## 16. Deferred scope

The following are P3 and must not enter the MVP critical path:

- extension marketplace and VS Code compatibility;
- cloud sync, team collaboration, enterprise administration, and hosted backend;
- autonomous unattended coding agent;
- remote development, full debugger, notebooks, and multi-root workspaces;
- Windows/Linux product support before the second-platform spike passes;
- custom language, SDK, and public plugin API before internal boundaries stabilize.

## 17. Immediate execution queue

The next work should be pulled in this exact order unless a documented finding
changes the dependency graph:

1. Finish the macOS renderer spike and accept the renderer/platform RFC.
2. Implement secure workspace root and relative path types with adversarial tests.
3. Implement snapshots and atomic file primitives with failure injection.
4. Implement transactional apply, rollback, recovery record, history, and undo.
5. Add cancellation, process tasks, structured diagnostics, and run IDs.
6. Ship `forge inspect/search/watch` and black-box CLI contracts.
7. Ship deterministic `diff/apply/check/history/undo` CLI workflow.
8. Establish fixtures, benchmark harness, and manual baseline measurements.
9. Add fake provider, context preview/redaction, and proposal schema.
10. Integrate one real provider and run the M3 AI proof before expanding IDE UI.

The first product checkpoint is not “the IDE window opens.” It is: **a real
change can be proposed, reviewed, verified, and undone safely, and the evidence
shows the workflow saves meaningful developer effort.**

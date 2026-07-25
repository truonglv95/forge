# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-07-25

First tagged release. Forge is an AI-first native IDE and CLI written in
Zig. The CLI exposes a chat / ask / edit / agent / spec / eval workflow
that talks to 7 providers (Gemini, Anthropic, OpenAI, OpenRouter, NVIDIA,
Ollama, Fake). The IDE is a self-contained native app with CPU software
rendering (FreeType + glyph cache + nanosvg) and an optional GLX GPU
backend that is wired but deferred until SDF text replaces the per-glyph
FreeType path.

### Added — IDE
- Modern dark/light themes with file-type icons (24 stroke-based SVGs).
- Tab bar with active indicator, hover states, dirty dot, save flash,
  and drag-to-reorder.
- Editor with syntax highlighting, bracket match, indent guides, current
  line highlight, code folding, minimap, multi-cursor, ghost completion.
- Find/Replace bar with VSCode-style shortcuts (Enter/Shift+Enter/Cmd+Enter),
  colour-coded match counter, blinking caret, keyboard hint row.
- Command palette with shortcut hint chips, blinking caret, drop shadow.
- Breadcrumbs with hover highlight and clickable file/symbol crumbs.
- Smooth scroll (~80ms exponential settle) for mouse wheel and large
  cursor jumps; typing stays snap.
- Agent panel with chat bubbles, tool step cards, thinking pill that
  shows status text, empty state with example prompts.
- Notifications: slide-in on appearance, fade-out on dismissal, level
  colours (info/success/warning/error).
- Inline edit (Cmd+K), LSP completion popup that flips above cursor
  when near viewport bottom, hover tooltips, inlay hints.
- Multi-platform CI (macOS, Linux, Windows) with format check, build,
  test, and agent reliability eval on each push.

### Added — CLI
- `forge chat`, `forge ask`, `forge edit`, `forge agent`, `forge spec`,
  `forge eval`, `forge context`, `forge doctor`, `forge parsers sync`,
  `forge providers`, `forge inspect`, `forge history`, `forge diff`,
  `forge apply`, `forge undo`.
- 7 provider integrations with credential auto-detection.
- Agent reliability eval (5/5 passes on fake provider, 100% success rate).
- Context secret trap (`.env`, `sk-` patterns excluded from context).
- Proposal/diff/apply/undo pipeline with transaction IDs.

### Fixed
- Eval script secret-trap grep now matches only file-kind entries
  (was false-matching expansion gap-reason entries).
- Git panel "switch branch" button now actually opens the branch
  picker (was showing "not implemented").
- Background errors now surface as warning toasts, not just status
  bar text that disappears on the next status change.
- GLX GPU init no longer steals X11 window context — CPU mode stays
  active until SDF text replaces FreeType.
- macOS undefined symbol `_forge_backend_set_full_clear` resolved
  with stubs in mac and win32 backend shims.
- Windows CI uses bash shell + LF line endings (.gitattributes).
- Linux GL `glext.h` guarded with `GL_GLEXT_PROTOTYPES` + conditional
  include.
- Config persistence: `writeTomlKey` checks `.forge/settings.toml`
  before falling back to workspace root.

### Known Limitations
- GPU rendering is wired but disabled by default — CPU software path
  is the active renderer. SDF text atlas is generated but not yet
  sampled at runtime.
- IME composition is fully implemented on macOS; Linux X11 and Windows
  have IME stubs (composition events are forwarded but no XIM/XIC).
- ZLS (Zig LSP) spawn may fail in containers without `zls` on PATH —
  non-fatal, editor still works without LSP features.

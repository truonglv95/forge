# RFC-0012: Project-Aware Parser Resolution

**Status:** Accepted  
**Date:** 2026-07-07

## Decision

When Forge opens or indexes a workspace, it probes project manifests for language
toolchain versions, resolves a pinned Tree-sitter grammar set from a bundled
catalog, and records the result in `.forge/` before chunking.

1. **Toolchain probe** reads `pyproject.toml`, `.python-version`, `package.json`,
   `build.zig.zon`, `rust-toolchain.toml`, and `Cargo.toml`.
2. **Parser catalog** maps language version ranges to vendored grammar tags.
3. **Parser resolver** selects the newest bundled grammar compatible with the
   detected project version and writes:
   - `.forge/toolchain.json`
   - `.forge/parser_lock.json`
4. **Index manifest** stores `parser_set_id` and `toolchain_fingerprint`. Any
   change forces a rebuild alongside `chunker_version`.

Runtime parser downloads remain forbidden. Future multi-grammar support must
extend the bundled catalog in `packages/workspace/src/parser_catalog.zig` or
use a verified `forge parsers sync` cache under `.forge/parsers/` with a
lockfile.

## CLI

- `forge parsers sync` probes the workspace, resolves grammars, and writes
  `.forge/toolchain.json`, `.forge/parser_lock.json`, and `.forge/parsers/sync.json`.
- `forge doctor` reports whether the parser lock matches the current toolchain.

## Fallback

If no project version is detected, Forge uses the default grammar for that
language. If Tree-sitter fails at chunk time, the registry falls back to
structural profiles and line windows.

## Initial catalog

| Language | Default grammar | Minimum project version |
|---|---|---|
| Python | `v0.23.6` | 3.8.0 |
| TypeScript | `v0.20.5` | 5.0.0 |
| TSX | `v0.20.5` | 5.0.0 |

Tree-sitter core is pinned at `0.20.8`.

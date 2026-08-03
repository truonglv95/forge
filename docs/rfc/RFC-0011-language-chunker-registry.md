# RFC-0011: Language Chunker Registry

**Status:** Accepted  
**Date:** 2026-07-06

## Decision

Semantic indexing selects a chunk backend through a language registry rather
than assuming one universal parser.

1. Native compiler AST backends are preferred when bundled and version-aligned.
2. Bundled Tree-sitter grammars may provide full AST support per language.
3. Structural declaration profiles provide immediate multi-language coverage.
4. Bounded line windows are the universal fallback.

Every backend emits the same chunk schema: path, range, file hash, language,
kind, symbol, and text. Backend changes increment `chunker_version` and force an
index rebuild.

## Initial coverage

- Native AST: Zig.
- Tree-sitter AST: Python, TypeScript, TSX.
- Structural: JavaScript/JSX, Rust, Go, C/C++, Java, C#, Kotlin, Swift, Ruby,
  PHP.
- Line-window fallback: all remaining UTF-8 text files.

Runtime parser downloads and unsigned dynamic libraries are forbidden.
Tree-sitter core and grammars must be pinned, built, and shipped as Forge
dependencies under `third_party/`. Project toolchain versions are probed on
index and mapped to a bundled grammar set per RFC-0012.

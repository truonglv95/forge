# Semantic Search Architecture and Evaluation

## Index pipeline

`language_chunker.zig` is the stable backend registry. Zig source uses
`std.zig.Ast`, bundled with the compiler used to build Forge. Python,
TypeScript, and TSX use pinned Tree-sitter grammars built with Forge. JavaScript,
Rust, Go, C/C++, Java, C#, Kotlin, Swift, Ruby, and PHP currently use a
structural declaration backend. Unknown languages use bounded line windows.

All backends preserve header/import context, split oversized declarations, and
emit the same `language`, `kind`, and `symbol` schema. Tree-sitter grammars can
therefore replace additional structural profiles later without changing index or
retrieval contracts. The Tree-sitter core runtime and grammar sources are pinned
under `third_party/` and compiled with Forge. Indexing never downloads or
dynamically executes parser binaries.

Structural parsing is deliberately a better boundary heuristic, not advertised
as a full AST. Grammar-specific correctness requires a parser bundled and pinned
with Forge.

The manifest records schema, chunker, embedding-input, dimension, chunk count,
and file count. Changing chunk or tokenization behavior forces a deterministic
rebuild. JSONL is emitted through the standard JSON serializer so source control
bytes cannot corrupt the index.

## Retrieval

- With Gemini credentials, Forge uses the configured embedding backend.
- Offline retrieval uses a 128-dimensional hashed lexical vector with
  snake_case and camelCase symbol subtokens. It is useful for symbol/concept
  overlap but must not be represented as a neural semantic model.
- Semantic and keyword candidates are fused using reciprocal-rank fusion and a
  per-file diversity cap.

## Deterministic quality gates

`zig build test-ai` includes a five-query multilingual symbol corpus and
requires Recall@1 of 5/5 across Zig, Python, and TypeScript concepts.
`zig build test-workspace` verifies:

- AST chunks preserve headers, function symbols, and declaration content;
- every chunk remains bounded;
- control bytes produce valid JSONL;
- ignored proposal/binary files do not make a fresh index immediately stale.

## Forge repository measurement

After the v3 rebuild on 2026-07-06:

- 4,559 chunks across 342 indexed files;
- 3,976 native Zig AST chunks;
- 412 structural declaration chunks from non-Zig languages in this repository;
- shared `language`, `kind`, and `symbol` metadata across all backends;
- median chunk length reduced from 45 lines to roughly 5 lines;
- zero malformed JSONL rows;
- a second identical context query does not rebuild the index.

Warm end-to-end `forge context ... @codebase` remains around three seconds on
the current repository because it also performs workspace scanning, keyword
retrieval, git diff/context assembly, and freshness checks. Session-level
index/query caches and pre-retrieval manifest hints reduce duplicate work inside
agent tool loops.

Python and TypeScript Tree-sitter support landed after this measurement and
increments `chunker_version` to force a deterministic index rebuild.

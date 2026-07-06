# Forge Capability Matrix

> Audited against the repository on 2026-07-06.

“Implemented” means production code exists; “verified” requires deterministic
tests; “dogfood-ready” requires reliable routine use. These states must not be
treated as synonyms.

| Capability | Implemented | Integrated | Verified | Dogfood-ready | Primary gap |
|---|:---:|:---:|:---:|:---:|---|
| Workspace tree/search/watch | Yes | CLI + IDE | Partial | Partial | scale corpus |
| Atomic transaction/apply | Yes | CLI + IDE | Yes | Partial | power-loss/IO fault soak |
| Conflict-safe undo | Yes | CLI | Yes | Partial | IDE conflict UI |
| CLI workspace/change commands | Yes | CLI | Partial | Partial | JSON black-box contract |
| Context manifest/redaction | Yes | CLI + IDE | Partial | Partial | adversarial corpus |
| Gemini/Ollama providers | Yes | CLI + IDE | Partial | No | deterministic provider suite |
| Ask/Plan proposal workflow | Yes | CLI + IDE | Partial | No | product evaluation |
| Multi-step agent and tools | Yes | CLI + IDE | Yes | Partial | container boundary + provider/model baselines |
| MCP client/registry | Yes | Agent | Partial | No | capability audit |
| Native editor/tabs/splits | Yes | IDE | Partial | Partial | workbench decomposition |
| Terminal/tasks | Yes | IDE | Partial | Partial | cancellation cleanup |
| LSP/rename/code actions | Yes | IDE | Partial | Partial | restart/stale suites |
| Debugger/LLDB | Yes | IDE | Minimal | No | lifecycle recovery |
| WASM extensions/catalog | Yes | CLI + IDE | Partial | No | threat model |
| Session/recovery/settings | Yes | IDE | Partial | Partial | crash injection |
| Inline AI completion | No | No | No | No | deferred until workflow proof |
| Signed updater | Partial | Packaging | No | No | channel and rollback |

## Current release blockers

1. Add an OS/container sandbox backend before running validation for untrusted
   repositories; snapshot isolation currently protects workspace contents only.
2. Record repeatable Gemini/Ollama baselines with `eval_reliability.sh`; live
   trials never belong in `zig build test`.
3. Add repeated power-loss/IO fault soak beyond deterministic crash boundaries.
4. Add session-scoped approval grants without weakening `every_time` tools.
5. Large IDE orchestration/render files need feature-controller boundaries.

# Forge AI Mode and Tool Matrix

| Capability | Ask | Plan | Agent |
|---|:---:|:---:|:---:|
| Search / semantic search | Auto | Auto | Auto |
| List tree / read file | Auto | Auto | Auto |
| Fetch documentation | Approval | Approval | Approval |
| Write project memory | No | No | Approval |
| Propose/apply file edits | No | No | Review by default; auto-apply when trusted |
| Run allowlisted command/task | No | No | Approval each call |
| MCP tools | No | No | Approval each call |
| Apply proposal | No | No | Human review/apply by default; direct transaction apply when trusted |

## Mode contracts

- **Ask** uses the read-only agent loop and returns model text. It persists a
  completed session but cannot create a proposal or mutate workspace state.
- **Plan** builds read-only workspace context and produces an inspectable spec.
  Generating edits is a separate explicit “Approve spec” transition into the
  proposal phase.
- **Agent** explores, edits, validates in an isolated trial workspace, and can
  use task/MCP tools. By default edits remain review-gated proposals. When the
  user explicitly trusts tools (`/tools trust-all`, `--trust-all`, or
  `--auto-approve`), edit tools apply immediately through Forge transactions,
  preserving checkpoints, history, stale-write checks, and undo.

Providers receive declarations already filtered for the selected profile. A
disallowed tool is therefore both hidden from the model and rejected again at
dispatch (defense in depth).

Unknown MCP tools default to high risk and `every_time` approval. CLI Agent mode
does not execute such tools unless the caller supplies an explicit trust flag
such as `--trust-all`/`--auto-approve`, or approves the tool interactively.

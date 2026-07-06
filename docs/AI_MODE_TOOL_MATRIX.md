# Forge AI Mode and Tool Matrix

| Capability | Ask | Plan | Agent |
|---|:---:|:---:|:---:|
| Search / semantic search | Auto | Auto | Auto |
| List tree / read file | Auto | Auto | Auto |
| Fetch documentation | Approval | Approval | Approval |
| Write project memory | No | No | Approval |
| Propose file edits | No | No | Review |
| Run allowlisted command/task | No | No | Approval each call |
| MCP tools | No | No | Approval each call |
| Apply proposal | No | No | Human review/apply only |

## Mode contracts

- **Ask** uses the read-only agent loop and returns model text. It persists a
  completed session but cannot create a proposal or mutate workspace state.
- **Plan** builds read-only workspace context and produces an inspectable spec.
  Generating edits is a separate explicit “Approve spec” transition into the
  proposal phase.
- **Agent** explores, proposes edits, validates in an isolated trial workspace,
  and can use task/MCP tools. Edits remain proposals and `every_time` tools
  pause for explicit approval.

Providers receive declarations already filtered for the selected profile. A
disallowed tool is therefore both hidden from the model and rejected again at
dispatch (defense in depth).

Unknown MCP tools default to high risk and `every_time` approval. CLI Agent mode
does not execute such tools unless the caller supplies the existing explicit
approval flag (`--yes`/non-interactive approval contract).

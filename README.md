# Forge

> AI-first native IDE, built in Zig.

Forge is a native development environment where AI is not a chatbot bolted onto
an editor. AI participates in understanding the codebase, proposing changes,
reviewing diffs, and running validation—but the developer always makes the final
decision.

> [!IMPORTANT]
> Forge is an active pre-alpha with a native IDE, headless CLI, workspace
> transactions, AI proposal workflows, LSP, terminal/debug tooling, MCP, and an
> experimental extension runtime. Feature breadth is ahead of verification; see
> the [Capability Matrix](docs/CAPABILITY_MATRIX.md) before treating a subsystem
> as dogfood-ready.

## North star

Forge aims to deliver one complete vertical slice:

```text
Open project -> Edit -> Ask AI -> Review diff -> Apply
             -> Format/build/test -> Undo when needed
```

Every AI-proposed change must have a clear scope, be reviewable and verifiable,
apply atomically, and support undo. The model must never write directly to the
editor buffer or filesystem.

## Project status

| Milestone | Goal | Status |
|---|---|---|
| M0 | Foundation and renderer decision | Implemented; audit pending |
| M1 | Safe shared workspace and execution engine | Implemented; hardening |
| M2 | Deterministic headless CLI vertical slice | Implemented; verification |
| M3 | AI-assisted CLI proof | Implemented; evaluation pending |
| M4 | Native IDE editing foundation | Implemented; hardening |
| M5 | AI-first IDE vertical slice | Implemented; parity pending |
| M6 | Language intelligence and dogfood alpha | In progress |
| M7 | Cursor parity (inline completion, Composer, @mentions, chat REPL) | Planned (RFC-0013, RFC-0017) |
| M8 | Kiro parity (spec-driven IDE UX, validation hooks, agent hooks) | Planned (RFC-0014) |
| M9 | Antigravity parity (agent timeline, background runs, multi-agent) | Planned (RFC-0015) |
| M10 | Provider hardening (capability metadata, smart router, Anthropic) | Planned (RFC-0016) |

See the [Project Roadmap](docs/roadmap/ROADMAP.md) for detailed checklists and
exit criteria. See the [Project Vision](docs/PROJECT_VISION.md) for the product
vision and architectural principles. See the
[AI Workflow Evaluation](docs/evaluation/AI_WORKFLOW_EVALUATION.md) for the
gap analysis vs Cursor / Kiro / Antigravity and the phased parity plan.

## Repository layout

```text
forge/
├── apps/
│   ├── forge-cli/       # CLI and headless workflows
│   ├── forge-ide/       # Native desktop application
│   └── forge-agent/     # Reserved for post-MVP agent workflows
├── packages/
│   ├── core/            # Shared domain types
│   ├── kernel/          # Lifecycle, commands, events, tasks, config
│   ├── workspace/       # Files, watcher, search, transactions
│   ├── editor/          # Buffer, cursor, selection, history
│   ├── renderer/        # Window, GPU, text, and input
│   ├── lsp/             # Language Server Protocol client
│   ├── ai/              # Context, providers, and edit proposals
│   ├── plugin/          # Post-MVP extension boundary
│   └── util/            # Domain-independent helpers
├── docs/
│   ├── architecture/
│   ├── roadmap/
│   └── rfc/
└── build.zig
```

This layout is enforced by the Zig build graph. Package responsibilities and
dependency rules are documented in
[RFC-0001](docs/rfc/RFC-0001-project-structure.md).

## Getting started

Current requirements:

- Zig `0.16.0`;
- macOS is the proposed MVP platform, pending confirmation through a renderer
  spike and RFC. (Linux CLI works; IDE build needs IME callbacks.)

```bash
zig build
zig build test
zig build run
```

The CLI exposes workspace, transaction, AI, agent, and extension commands:

```bash
zig build run -- help
```

To verify the complete local foundation in one command, run:

```bash
./scripts/bootstrap.sh
```

## AI-first CLI workflow

Forge CLI now ships a complete AI-first workflow comparable to Cursor, Kiro,
and Antigravity — all from the terminal.

### Inline completion (Cursor parity)

```bash
# Complete code at a file position
forge complete --file src/main.zig --line 42 --char 15 --provider fake
forge complete --file src/main.zig --line 1 --char 0 --provider gemini --json
```

### Chat REPL with @mentions (Cursor parity)

```bash
# Interactive REPL with slash commands and @mentions
forge chat --provider gemini

# One-shot via pipe
echo "explain @file:src/main.zig" | forge chat --pipe --provider fake --json

# Mentions supported in chat input:
#   @file:path[:10-20]   Include file content (optional line range)
#   @symbol:name         Grep workspace for symbol (LSP integration pending)
#   @web:https://...     Fetch URL content
#   @docs:library        Read docs/<library>.md
#   @spec:feature-id     Read specs/features/<id>.md
#   @recent              Include recent files (stub)
#   @git:diff            Include git diff --stat
#   @git:status          Include git status --porcelain
```

### Composer multi-file edit (Cursor parity)

```bash
# Edit multiple files with natural language
forge edit "add error handling to main function" --file src/main.zig --yes
forge edit "rename foo to bar" --file src/main.zig --file src/caller.zig --dry-run
```

### Spec-driven development (Kiro parity)

```bash
# Initialize specs/ directory with templates
forge spec init

# Print a spec template
forge spec template feature > specs/features/my-feature.md

# Full spec lifecycle
forge spec create my-feature
forge spec edit my-feature --section requirements --body "..."
forge spec validate my-feature
forge spec approve my-feature
forge spec implement my-feature --provider gemini --max-steps 10
forge spec trace my-feature
```

### Background agents (Antigravity parity)

```bash
# Start a background agent run
forge agent run "refactor transaction.zig" --background --max-steps 20

# List background runs
forge agent runs

# Stream events from a session (tail -f style)
forge agent events <session_id> --follow

# Branch a session at a step
forge agent branch <session_id>

# Resume a session
forge agent resume <session_id>
```

### Provider capability and smart routing

```bash
# List providers
forge providers

# List models with capability (context, tools, streaming, price)
forge models list
forge models list --provider gemini

# Query a single model's capability
forge models capability gemini/gemini-2.5-pro

# Smart-route based on task requirements
forge models route --context-bytes 50000 --require-tools
forge models route --prefer-local
forge models route --max-price-per-mtok 10
```

### Safe change workflow (always available)

```bash
# The core safe-change pipeline — every AI edit goes through this
forge ask "add a helper function" --file src/utils.zig
forge diff .forge/proposals/latest.json
forge apply .forge/proposals/latest.json --yes
forge check
forge history
forge undo 3
```

## Configuration

Configure providers in `~/.forge/settings.toml` or project-level `forge.toml`:

```toml
[ai]
provider = "auto"           # auto | gemini | anthropic | ollama | openrouter | openai | nvidia | fake
model = "gemini-2.5-flash"  # optional override

[ghost_completion]
provider = "ai"             # ai | ollama | gemini
model = "gemini-2.5-flash"
enabled = true
```

Credentials via environment variables or macOS keychain:
- `GEMINI_API_KEY` / `GOOGLE_API_KEY`
- `ANTHROPIC_API_KEY` / `CLAUDE_API_KEY`
- `OPENAI_API_KEY`
- `OPENROUTER_API_KEY`
- `NVIDIA_API_KEY`
- Ollama: run `ollama serve` locally

## Engineering rules

- Use commands for mutations and events to announce facts that have occurred.
- Synchronous queries may use interfaces directly; not everything must go
  through the event bus.
- Feature packages depend on `kernel/core`, which depend on `util`; dependency
  cycles are forbidden.
- Never block the render thread with filesystem, LSP, or model calls.
- Data safety and correctness take priority over feature breadth.
- Decisions that are difficult to reverse require an RFC.

## Documentation

- [Commit convention](docs/COMMIT_CONVENTION.md)
- [Project vision](docs/PROJECT_VISION.md)
- [Delivery roadmap](docs/roadmap/ROADMAP.md)
- [Capability matrix](docs/CAPABILITY_MATRIX.md)
- [AI Workflow Evaluation — Cursor/Kiro/Antigravity gap analysis](docs/evaluation/AI_WORKFLOW_EVALUATION.md)
- [Cursor 2 Master Plan](docs/plan/FORGE_CURSOR2_MASTER_PLAN.md)
- [AI Flow Improvements](docs/plan/FORGE_AI_FLOW_IMPROVEMENTS.md)
- [RFC-0001: project structure](docs/rfc/RFC-0001-project-structure.md)
- [RFC-0002: runtime ownership](docs/rfc/RFC-0002-runtime-ownership.md)
- [RFC-0003: commands, events, and workspace edits](docs/rfc/RFC-0003-commands-events-workspace-edits.md)
- [RFC-0013: inline tab completion (Cursor parity)](docs/rfc/RFC-0013-inline-tab-completion.md)
- [RFC-0014: spec-driven development (Kiro parity)](docs/rfc/RFC-0014-spec-driven-development.md)
- [RFC-0015: agent timeline & background runs (Antigravity parity)](docs/rfc/RFC-0015-agent-timeline-background-runs.md)
- [RFC-0016: provider capability & smart router](docs/rfc/RFC-0016-provider-capability-smart-router.md)
- [RFC-0017: CLI chat REPL & mentions](docs/rfc/RFC-0017-cli-chat-repl-mentions.md)

## Contributing

The project does not yet have a stable contribution workflow. Before
implementing a feature, check the active milestone and avoid introducing
post-MVP work into the critical path.

### Local checks

Run the same checks CI uses:

```bash
./scripts/check.sh          # format, build, and test
./scripts/check.sh --fast     # format and AST check only
```

Format sources in place before committing:

```bash
zig fmt build.zig apps packages
```

### Commit messages

Forge uses [Conventional Commits](https://www.conventionalcommits.org/) with a
monorepo **scope**:

```text
type(scope): imperative subject
```

Examples:

```text
feat(forge-cli): add inspect subcommand
fix(workspace): reject overlapping text edits
docs(docs): update M1 checklist
ci(scripts): add validate-commit-msg hook
```

See [Commit Convention](docs/COMMIT_CONVENTION.md) for types, scopes, and
examples.

### Git hooks

Enable project hooks once per clone:

```bash
chmod +x scripts/check.sh scripts/validate-commit-msg.sh scripts/strip-cursor-coauthor.sh .githooks/*
git config core.hooksPath .githooks
```

- `pre-commit` runs `./scripts/check.sh --fast` (format + AST check).
- `commit-msg` validates the commit header against the convention.
- `pre-push` runs `./scripts/check.sh --full` (format, build, and test).

CI remains the final gate on every push and pull request.

## License

Not yet decided. Do not assume the repository has an open-source license until
a `LICENSE` file is officially added.

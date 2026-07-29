# Forge — AI-First Native IDE & CLI

**Forge** is a Zig-based AI coding assistant with TUI, CLI, HTTP server, and IDE — all sharing the same kernel.

[![CI](https://github.com/truonglv95/forge/actions/workflows/ci.yml/badge.svg)](https://github.com/truonglv95/forge/actions/workflows/ci.yml)

## Quick Start

```bash
# Build
zig build -Dwith-glx=false

# Interactive TUI (like Claude Code / Aider)
./zig-out/bin/forge agent

# Ask a question
./zig-out/bin/forge ask "explain this codebase"

# Start HTTP server for mobile access
./zig-out/bin/forge serve
# → Open http://localhost:7777/app on your phone
```

## Features

### TUI (Terminal UI)
- **74 slash commands** with fuzzy search and descriptions
- **Semantic icons**: ▶ user, │ agent, ⚙ tool, ✕ error
- **Real-time markdown streaming** with syntax highlighting (14+ languages)
- **HelpPanel** component — 9 categories, keyboard navigation
- **StatusBar** component — model, mode, context, tokens, branch
- **Mention picker** — @file, @git:diff, @git:status, @spec
- **Vim mode** — normal/insert with i/a/o/h/l/0/$/x/dd/yy/p/u
- **4 themes** — dark, light, solarized, mono
- **CJK display width** — wcwidth-style for correct CJK rendering

### CLI Commands
| Command | Description |
|---------|-------------|
| `forge agent` | Interactive TUI (like Claude Code) |
| `forge agent run "task"` | Run agent on a task |
| `forge agent run --background "task"` | Background agent run |
| `forge agent run --harness "task"` | Superpower Harness (7-phase workflow) |
| `forge agent run --parallel "task"` | Parallel multi-agent (Antigravity parity) |
| `forge agent run --coordinated "task"` | Coordinated multi-agent (planner→reviewer→implementer) |
| `forge ask "question"` | Ask AI to propose a change |
| `forge serve` | HTTP daemon + PWA for mobile |
| `forge spec create "feature"` | Spec-driven development (Kiro parity) |
| `forge complete --file path --line N` | Inline FIM completion |
| `forge edit --file a --file b "instruction"` | Composer multi-file edit |
| `forge review` | AI code review |
| `forge chat` | Interactive chat REPL |

### forge serve (Mobile PWA)
- HTTP daemon on port 7777
- REST API: `/api/chat`, `/api/sessions`, `/api/runs`, `/api/agent/approve`
- SSE realtime event stream: `/api/events/stream`
- PWA frontend — mobile-optimized, dark theme, 3 tabs (Sessions/Runs/Chat)
- Real agent execution — calls `ai.agent.run()` with configured provider

### AI Providers (7)
- **Gemini** (Google) — 2M context window
- **Anthropic** (Claude) — Sonnet 4.5, Haiku 4
- **OpenAI** (GPT-4o)
- **Ollama** (local) — qwen2.5-coder, llama3.3
- **OpenRouter** (aggregator)
- **NVIDIA** (NIM)
- **Fake** (deterministic testing)

### Agent Features
- **256-step cap** (supports multi-hour tasks)
- **Context compaction** — auto-shrinks conversation when context fills
- **Self-repair loop** — trial workspace + validation
- **Session resume** — checkpoint + restore
- **Persistent chat memory** — `.forge/memory/chat.toml`
- **Superpower Harness** — 7-phase: Brainstorm→Spec→Plan→TDD→Dev→Review→Finalize
- **Parallel multi-agent** — N threads, shared task ledger
- **Subagents** — synchronous execution, role-based capability
- **Web search** — DuckDuckGo fallback, Brave/Tavily stubs
- **Hooks** — 12 lifecycle events (Claude Code parity)
- **MCP support** — stdio + HTTP

### Safety
- **Transactional edits** — atomic apply/undo with content-hash precondition
- **3-level capability profiles** — read_only, propose, propose_and_task
- **Tool approval** — per-tool, per-session, or auto-approve
- **Sandbox** — landlock (Linux), seatbelt (macOS) stubs

## Configuration

### forge.toml
```toml
[ai]
provider = "ollama"
model = "qwen2.5-coder:7b"
ollama_url = "http://localhost:11434"
```

### Environment Variables
```bash
GEMINI_API_KEY=...        # Google Gemini
ANTHROPIC_API_KEY=...     # Claude
OPENAI_API_KEY=...        # OpenAI
OPENROUTER_API_KEY=...    # OpenRouter
BRAVE_API_KEY=...         # Brave Search (web_search tool)
```

## Build

```bash
# Requires Zig 0.16.0
pip install ziglang==0.16.0

# Build (without GPU rendering — for headless/CI)
zig build -Dwith-glx=false

# Build (with GPU rendering — for IDE, requires libGL-dev)
zig build

# Test
zig build test -Dwith-glx=false --summary all
```

## Architecture

```
forge/
├── apps/
│   ├── forge-cli/          # CLI + TUI + serve
│   │   └── src/agent_tui/  # Terminal UI (6 components)
│   └── forge-ide/          # Native IDE (X11/Win32)
├── packages/
│   ├── ai/                 # Agent loop, providers, tools, context
│   ├── workspace/          # File ops, git, transactions, sessions
│   ├── kernel/             # Cancellation, process management
│   ├── editor/             # Text buffer, syntax highlighting
│   ├── renderer/           # GPU rendering (GLX/Win32)
│   └── util/               # Process spawn, serve helper
└── tools/                  # Renderer spike, codegen
```

## License

MIT

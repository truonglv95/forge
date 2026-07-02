# Commit Convention

Forge uses [Conventional Commits](https://www.conventionalcommits.org/) with a
**scope** that identifies the app, package, or repo area being changed. This
keeps history readable in a monorepo with multiple applications and packages.

## Format

```text
type(scope): imperative subject

[optional body]

[optional footer]
```

### Header rules

- One line, at most **72 characters**.
- **type** and **scope** are lowercase.
- **subject** uses imperative mood (`add`, `fix`, `remove`), starts with a
  lowercase letter, and has no trailing period.
- Use **`!`** after the scope for breaking changes:
  `feat(kernel)!: replace service startup order`.

### Types

| Type | When to use |
|---|---|
| `feat` | New behavior or user-facing capability |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Formatting or whitespace without logic changes |
| `refactor` | Internal restructuring without behavior change |
| `test` | Tests only |
| `chore` | Maintenance that does not fit another type |
| `ci` | CI workflow changes |
| `build` | Build system or dependency changes |
| `perf` | Performance improvement |
| `revert` | Revert a previous commit |

### Scopes

Pick the **smallest scope** that owns the change.

#### Applications (`apps/`)

| Scope | Path |
|---|---|
| `forge-cli` | `apps/forge-cli/` |
| `forge-ide` | `apps/forge-ide/` |
| `forge-agent` | `apps/forge-agent/` |

#### Packages (`packages/`)

| Scope | Path |
|---|---|
| `core` | `packages/core/` |
| `kernel` | `packages/kernel/` |
| `workspace` | `packages/workspace/` |
| `editor` | `packages/editor/` |
| `renderer` | `packages/renderer/` |
| `lsp` | `packages/lsp/` |
| `ai` | `packages/ai/` |
| `plugin` | `packages/plugin/` |
| `util` | `packages/util/` |

#### Repository

| Scope | When to use |
|---|---|
| `build` | `build.zig`, `build.zig.zon` |
| `ci` | `.github/workflows/` |
| `docs` | `docs/`, `README.md`, RFCs, roadmap |
| `scripts` | `scripts/`, `.githooks/` |
| `repo` | Changes across multiple apps/packages |

## Examples

```text
feat(forge-cli): add inspect subcommand skeleton
fix(workspace): reject overlapping text edits in validate
docs(docs): mark renderer spike as in progress
test(kernel): cover event bus unsubscribe ordering
refactor(core): extract CommandId next helper
ci(ci): run check.sh in GitHub Actions
build: declare forge-workspace in build graph
chore(scripts): add pre-commit format hook
feat(kernel)!: change Dispatcher error type to tagged union
```

### Multi-area changes

If a change spans several packages, either:

- split it into scoped commits (preferred), or
- use `repo` when the change is inherently cross-cutting:

```text
repo: bootstrap monorepo packages and CI
```

## Body and footer (optional)

Use the body to explain **why**, not **what** (the diff shows what).

```text
fix(workspace): guard against empty path in WorkspaceEdit

Modify and delete operations must carry a workspace-relative path.
An empty path slipped through validation in one test fixture.

Fixes stale-write checks for nested apply paths.
```

Footers follow [git trailer](https://git-scm.com/docs/git-interpret-trailers)
 conventions when needed:

```text
Refs: RFC-0003
BREAKING CHANGE: WorkspaceEdit.validate now returns DuplicatePath for repeats.
```

## Local enforcement

The `commit-msg` hook validates the header when hooks are enabled:

```bash
chmod +x scripts/check.sh scripts/validate-commit-msg.sh .githooks/*
git config core.hooksPath .githooks
```

Bypass only when necessary (not for normal work):

```bash
git commit --no-verify -m "..."
```

## Choosing type and scope quickly

```text
Which directory did you mainly change?
  apps/forge-cli     -> forge-cli
  packages/kernel    -> kernel
  docs/              -> docs
  .github/           -> ci
  build.zig          -> build
  several areas      -> repo

What kind of change is it?
  new capability     -> feat
  bug                -> fix
  tests              -> test
  docs only          -> docs
  refactor           -> refactor
```

# Forge project instructions

Use these rules when proposing workspace edits in this repository.

- Prefer minimal, focused diffs that match existing Zig conventions.
- Never commit secrets, API keys, or credentials.
- AI proposals must go through review before apply (`apply_mode = "review"` in `forge.toml`).
- Run `zig build test` after substantive code changes.
- Keep package boundaries: workspace mutations flow through `workspace/transaction`.

When editing IDE code, preserve the command/event split documented in RFC-0008.

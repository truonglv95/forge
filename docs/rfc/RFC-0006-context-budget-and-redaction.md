# RFC-0006: Context Budget and Redaction

**Status:** Accepted  
**Date:** 2026-07-04

## Summary

The context engine prepares inspectable input for AI providers. Every item is
included or rejected with a reason. Secrets are blocked before any provider call.

## Manifest schema (v1)

```json
{
  "schema_version": 1,
  "items": [
    {
      "kind": "file",
      "name": "src/main.zig",
      "included": true,
      "truncated": false,
      "bytes": 4200
    },
    {
      "kind": "file",
      "name": ".env",
      "included": false,
      "reason": "Secret file extension or name detected",
      "bytes": 0
    }
  ],
  "budget_bytes": 1048576,
  "used_bytes": 512000
}
```

## Budget rules

1. Default budget: **1 MiB** (`LoadOptions.max_bytes`).
2. CLI override: `forge context --budget-bytes <n>`.
3. When an item exceeds remaining budget, content is **truncated** and
   `truncated: true` is set in the manifest.
4. When budget is exhausted before an item, the item is **rejected** with reason
   `Context byte budget exceeded`.

## Redaction policy

### Filename blocklist

`.env`, `.env.local`, `credentials.json`, `id_rsa`, `id_ed25519`, `*.pem`,
`*.key`

### Content patterns

| Pattern | Examples |
|---|---|
| `AIza` | Google API keys |
| `sk-` | OpenAI / Stripe style keys |
| `ghp_` | GitHub PAT |
| `BEGIN PRIVATE KEY` | PEM private keys |

Rejected items appear in the manifest with `included: false` and a `reason`.

## CLI contract

```bash
forge context "intent" --file path --budget-bytes 4096 --json
```

Human mode prints `[INCLUDED]`, `[TRUNCATED]`, `[REJECTED]` lines.

## Provider rules

1. Context builder output is the only file content sent to providers.
2. Run records must not store raw prompts containing rejected secrets.
3. `forge doctor` never prints credential values.

## Implementation

- `packages/ai/src/context.zig` — budget + rejection map
- `packages/ai/src/secret_scanner.zig` — pattern + filename checks
- `packages/ai/src/context_loader.zig` — file loading + manifest render
- `apps/forge-cli/src/context_cmd.zig` — CLI surface

## Exit criteria

- [x] Secret filename and pattern traps pass eval
- [x] Byte budget truncation exposed via `--budget-bytes`
- [x] Manifest JSON matches schema above
- [ ] Token-based budget (future; bytes-only for v1)
- [ ] Project rules / FORGE.md injection (Phase 4)

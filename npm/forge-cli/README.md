# @forge-ai/cli

> AI-first native IDE, built in Zig — distributed as an npm package.

## Install

```bash
npm install -g @forge-ai/cli
npx @forge-ai/cli <command>
```

## Quick start

```bash
forge version
forge doctor
forge --help

# AI-first workflow
forge ask "add a helper function" --file src/utils.zig
forge diff .forge/proposals/latest.json
forge apply .forge/proposals/latest.json --yes
forge undo 3

# Forge Cloud integration
forge cloud status
forge cloud login user@example.com
forge cloud models
forge models list --cloud
```

## Forge Cloud

Forge Cloud is an optional backend that handles user auth, server-side LLM
proxying (API keys never leave the server), and a server-managed model catalog.

```bash
forge cloud status          # check config + login status
forge cloud login <email>   # sign in (prompts for password)
forge cloud models          # list models from backend
forge cloud logout          # sign out
forge models list --cloud   # alias for forge cloud models
```

Configuration — Cloud URL and anon key are resolved from:
1. `FORGE_CLOUD_URL` / `FORGE_CLOUD_ANON_KEY` env vars
2. Compile-time defaults (`-Dforge-cloud-url=... -Dforge-cloud-anon-key=...`)
3. Hardcoded default: `https://forge-cloud.supabase.co`

## How it works

This package is a thin Node.js wrapper. The native binary ships in
platform-specific optional packages:

| Package | Platform |
|---|---|
| `@forge-ai/cli-linux-x64` | Linux x86_64 |
| `@forge-ai/cli-linux-arm64` | Linux aarch64 |
| `@forge-ai/cli-darwin-x64` | macOS Intel |
| `@forge-ai/cli-darwin-arm64` | macOS Apple Silicon |
| `@forge-ai/cli-win32-x64` | Windows x86_64 |

Only the matching package is downloaded — install size stays small.

## Programmatic API

```js
const forge = require('@forge-ai/cli');
console.log(forge.getBinaryPath());
const child = forge.spawn(['chat', '--provider', 'gemini']);
const { stdout } = await forge.exec(['version']);
```

## Issues

https://github.com/truonglv95/forge/issues

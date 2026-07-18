# Workspace Extensions

Drop Forge extensions here. Each extension is a folder with a `forge.toml` manifest.

**Marketplace:** open the Extensions sidebar → **Marketplace** tab, or run:

```bash
forge ext list
forge ext install forge.theme.solarized
```

Catalog entries live in `extensions/catalog.toml`; packages are copied from `extensions/catalog/*/` into `.forge/extensions/`.

```toml
[extension]
id = "your.name.here"
name = "My Extension"
version = "0.1.0"
api_version = 1

[[commands]]
id = "my.command"
title = "My Command"
```

Forge loads extensions from:

1. `extensions/*/` (shared with the repo)
2. `.forge/extensions/*/` (personal, not committed)

After adding an extension, open the **Extensions** sidebar (`Px` icon) and click **Reload**, or run **Reload Extensions** from the command palette.

See `extensions/samples/hello/` for a minimal example.

## Extension SDK

Forge exposes a small public SDK through the `forge-plugin` package:

```zig
const forge = @import("forge-plugin");
```

For native/builtin extensions, use the activation context instead of writing into host internals:

```zig
fn activate(ctx: *forge.ActivationContext) !void {
    try ctx.registerCommand("demo.hello", "Hello");
    try ctx.registerLanguage(.{
        .id = "typescript",
        .server = "typescript-language-server",
        .args = "--stdio",
        .file_pattern = "*.ts",
    });
}
```

For extension tooling, `forge.sdk.ManifestBuilder` can generate a `forge.toml`:

```zig
var manifest = forge.sdk.ManifestBuilder.init(allocator, "demo.extension", "Demo Extension");
defer manifest.deinit();
try manifest.command("demo.hello", "Hello");
try manifest.language(.{
    .id = "zig",
    .server = "zls",
    .file_pattern = "*.zig",
    .server_resolver = "vscode-zig-zls",
});
const toml = try manifest.toTomlAlloc(allocator);
```

For WASM extensions, `forge.sdk.guest` wraps the host imports:

```zig
export fn forge_activate() void {
    forge.sdk.guest.setStatus("Extension activated");
}
```

## LSP Resolution

Forge always keeps Tree-sitter parsers as the local syntax/indexing baseline.
Language servers are optional and are layered on top when configured.

LSP entries are resolved in this order:

1. Bundled language extension pack
2. Installed/catalog extensions such as `forge.lsp.typescript`
3. Global `~/.forge/settings.toml`
4. Workspace `forge.toml`

Later entries win when multiple servers match the same file pattern.

Example workspace override:

```toml
[lsp]
servers = "typescript|typescript-language-server|--stdio|*.ts,typescript|typescript-language-server|--stdio|*.tsx,javascript|typescript-language-server|--stdio|*.js,javascript|typescript-language-server|--stdio|*.jsx"
```

The format is:

```text
language_id|server|args|file_pattern
```

An optional fifth field is a resolver name. Resolvers let an extension find a server bundled by another tool before falling back to the command name:

```text
language_id|server|args|file_pattern|server_resolver
```

Use an empty args field when the server does not need arguments:

```toml
[lsp]
servers = "zig|zls||*.zig|vscode-zig-zls"
```

Extension manifests can express the same thing:

```toml
[[languages]]
id = "zig"
server = "zls"
args = ""
file_pattern = "*.zig"
server_resolver = "vscode-zig-zls"
```

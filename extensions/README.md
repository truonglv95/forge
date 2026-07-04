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

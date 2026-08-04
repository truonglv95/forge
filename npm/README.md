# Forge npm distribution

## Layout

```
npm/
├── forge-cli/                       # Main wrapper package (@forge-ai/cli)
│   ├── package.json
│   ├── bin/forge.js
│   ├── lib/index.js
│   └── README.md
├── forge-cli-linux-x64/             # Platform-specific binary packages
├── forge-cli-linux-arm64/
├── forge-cli-darwin-x64/
├── forge-cli-darwin-arm64/
├── forge-cli-win32-x64/
└── scripts/
    ├── build-npm.sh
    └── publish-npm.sh
```

## Pattern

Uses optionalDependencies platform-specific packages (same as esbuild, biome,
turbo, lightningcss). The main `@forge-ai/cli` package declares all 5 platform
packages as optionalDependencies; npm installs only the one matching the host
platform/arch. The JS shim in `bin/forge.js` resolves the right binary at runtime.

## Local development

```bash
./npm/scripts/build-npm.sh
node npm/forge-cli/bin/forge.js version
```

## Publishing

Requires NPM_TOKEN and binaries built for all 5 platforms. The GitHub Actions
workflow `.github/workflows/release-npm.yml` handles cross-platform builds and
publishing on tag push.

# Forge AI Ecosystem

Forge treats AI features as an ecosystem around the IDE, not as a single chat
panel. The local ecosystem manifest is the first stable contract for tools,
context sources, skill packs, eval packs, providers, marketplace metadata, and
permissions.

Default manifest paths:

- `.forge/ai/ecosystem.json`
- `forge.ai.json`
- `extensions/ai/ecosystem.json`

Create a starter manifest:

```sh
forge ecosystem init
```

Preview without writing:

```sh
forge ecosystem init --dry-run
```

Inspect a manifest:

```sh
forge ecosystem inspect
forge ecosystem list
```

## Foundation Contracts

1. Tool SDK
   Tools declare an `id`, title, transport, optional entry point, input/output
   schema, and required permission ids. Native tools, MCP tools, and future WASM
   tools can share the same contract.

2. Context Source SDK
   Context sources declare where relevant context comes from: semantic index,
   docs, external systems, memory, logs, databases, or project metadata.

3. Agent Workflow / Skill Pack
   Skill packs group workflows by language, framework, or task type. Workflows
   name the tools, context sources, prompt, and eval pack they need.

4. Local Marketplace / Registry
   The manifest acts as a local marketplace record first. Remote catalogs can
   later sync into the same shape without changing agent runtime contracts.

5. Eval Harness
   Eval packs bind workflows to corpora and success thresholds. A workflow should
   become installable only when it can be evaluated.

6. Provider / Model Options
   Provider hints describe preferred models by role, context window, and backend.
   They are advisory metadata; runtime provider selection remains configurable.

7. Permission / Security Model
   Permissions define risk and approval mode. Tools and context sources refer to
   permission ids instead of hardcoding UI approval policy.

## Minimal Manifest

```json
{
  "schema_version": 1,
  "package_id": "local.forge-ai",
  "name": "Local Forge AI Ecosystem",
  "permissions": [
    {"id": "workspace.read", "risk": "low", "approval": "automatic"}
  ],
  "tools": [
    {"id": "forge.read_file", "transport": "native", "permissions": ["workspace.read"]}
  ],
  "context_sources": [
    {"id": "forge.semantic", "kind": "index", "permissions": ["workspace.read"]}
  ],
  "skill_packs": [
    {
      "id": "forge.default-coding",
      "workflows": [
        {
          "id": "forge.explore",
          "tools": ["forge.read_file"],
          "context_sources": ["forge.semantic"]
        }
      ]
    }
  ]
}
```


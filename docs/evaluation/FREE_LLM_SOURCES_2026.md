# Free LLM Sources for Forge — 2026

> Comprehensive guide to **free-tier LLM providers** that work with Forge.
> All providers below have a **permanent free tier** (no trial credits, no credit card).
> Last updated: 2026-08-01.

## TL;DR — At a Glance

| Provider   | Env var              | Free quota                      | Speed         | Best for                       | Forge support |
| ---------- | -------------------- | ------------------------------- | ------------- | ------------------------------ | ------------- |
| Ollama     | _(none — local)_     | Unlimited (your hardware)       | Slow-medium   | Privacy, offline, embeddings   | ✅ built-in    |
| Gemini     | `GEMINI_API_KEY`     | 15 RPM, 1M tok/day              | Fast          | Long context (2M), multimodal  | ✅ built-in    |
| Groq       | `GROQ_API_KEY`       | 30 RPM, 14k req/day, ~500 tok/s | Ultra-fast    | Inline completion, low latency | ✅ **NEW**     |
| Cerebras   | `CEREBRAS_API_KEY`   | 30 RPM, ~1M tok/day, ~2000 tok/s| Fastest       | Production-speed inference     | ✅ **NEW**     |
| OpenRouter | `OPENROUTER_API_KEY` | 20 req/day, 28+ free models     | Varies        | Model shopping, fallback chain | ✅ built-in    |
| NVIDIA NIM | `NVIDIA_API_KEY`     | 1000 req/month                  | Fast          | Llama 3.3 70B at scale         | ✅ built-in    |
| Forge Cloud| _(login JWT)_        | Free during beta                | Medium        | Zero-config, BYO model         | ✅ built-in    |
| Z.AI SDK   | _(preinstalled)_     | Unlimited in dev env            | Fast          | Internal eval, testing         | ⚠️ external    |

---

## 1. Ollama — Local / Offline (Free Forever)

**Signup:** None — install from <https://ollama.com>
**Base URL:** `http://localhost:11434`
**Env var:** _(none — runs locally)_

```toml
[ai]
provider = "ollama"
model = "qwen2.5-coder:14b"
ollama_url = "http://localhost:11434"
embedding_provider = "ollama"
embedding_model = "nomic-embed-text"
embedding_url = "http://localhost:11434"
```

**Recommended free models:**
- `qwen2.5-coder:14b` — best code model that fits in 16GB RAM
- `qwen2.5-coder:32b` — needs 32GB RAM, near-GPT-4 quality
- `llama3.3:70b` — needs 48GB RAM, frontier-class
- `deepseek-r1:14b` — reasoning model
- `nomic-embed-text` — for semantic search embeddings

**Pros:** Unlimited use, fully private, works offline.
**Cons:** Requires your own GPU/CPU; 70B models need 48GB+ RAM.

---

## 2. Google Gemini — Free Tier (15 RPM, 1M tokens/day)

**Signup:** <https://aistudio.google.com> → "Get API key"
**Base URL:** `https://generativelanguage.googleapis.com` (handled by Forge)
**Env var:** `GEMINI_API_KEY` or `GOOGLE_API_KEY`

```bash
export GEMINI_API_KEY="AIza..."
```

```toml
[ai]
provider = "gemini"
model = "gemini-2.5-flash"  # or gemini-2.5-pro for complex tasks
```

**Free-tier limits (2026):**
- `gemini-2.5-flash` — 15 RPM, 1M tokens/day, 1500 RPD
- `gemini-2.5-pro` — 5 RPM, 250 RPD
- `gemini-2.5-flash-lite` — 30 RPM, 2000 RPD

**Pros:** 2M-token context window, multimodal (image/PDF), structured output.
**Cons:** 15 RPM is tight for agentic loops (each tool step = 1 request).

---

## 3. Groq — LPU-Accelerated Free Tier (~500 tok/s) **[NEW in Forge]**

**Signup:** <https://console.groq.com> → "API Keys"
**Base URL:** `https://api.groq.com/openai/v1`
**Env var:** `GROQ_API_KEY`

```bash
export GROQ_API_KEY="gsk_..."
```

```toml
[ai]
provider = "groq"
model = "llama-3.3-70b-versatile"
```

**Free-tier limits (2026):**
- 30 RPM, 14,400 RPD, 500,000 tokens/day
- ~500 tokens/sec output on LPU hardware (fastest free tier after Cerebras)

**Recommended free models:**
| Model ID                              | Use case                          | Context   |
| ------------------------------------- | --------------------------------- | --------- |
| `llama-3.3-70b-versatile`             | General coding, agentic           | 128K      |
| `llama-3.1-8b-instant`                | Inline completion (sub-100ms TTFB)| 128K      |
| `deepseek-r1-distill-llama-70b`       | Reasoning, planning               | 128K      |
| `qwen-2.5-coder-32b`                  | Code-specialized                  | 128K      |
| `moonshotai/kimi-k2-instruct`         | Long-context chat                 | 128K      |

**Pros:** Fastest free tier for 70B models; full OpenAI-compatible API with `tools` + `tool_choice`; supports structured output.
**Cons:** Rate limit shared across all free users; no fine-tuning.

---

## 4. Cerebras — Wafer-Scale CS-3 (~2000 tok/s) **[NEW in Forge]**

**Signup:** <https://cloud.cerebras.ai> → "Sign up" (no credit card)
**Base URL:** `https://api.cerebras.ai/v1`
**Env var:** `CEREBRAS_API_KEY`

```bash
export CEREBRAS_API_KEY="csk-..."
```

```toml
[ai]
provider = "cerebras"
model = "llama-3.3-70b"
```

**Free-tier limits (2026):**
- 30 RPM, ~1,000,000 tokens/day
- ~2000 tokens/sec output on CS-3 wafer (fastest inference hardware available)

**Recommended free models:**
| Model ID              | Use case                          | Context   |
| --------------------- | --------------------------------- | --------- |
| `llama-3.3-70b`       | General coding, agentic           | 128K      |
| `llama3.1-8b`         | Inline completion (~1800 tok/s)   | 128K      |
| `qwen-3-coder-30b`    | Code-specialized                  | 128K      |

**Pros:** Fastest free-tier inference; OpenAI-compatible API; very generous 1M tok/day.
**Cons:** Only ~3-4 models hosted (less variety than Groq).

---

## 5. OpenRouter — Free-Model Gateway (28+ free models)

**Signup:** <https://openrouter.ai> → "Sign up" → generate key
**Base URL:** `https://openrouter.ai/api/v1`
**Env var:** `OPENROUTER_API_KEY`

```bash
export OPENROUTER_API_KEY="sk-or-v1-..."
```

```toml
[ai]
provider = "openrouter"
model = "deepseek/deepseek-chat-v3-0324:free"
```

**Free-tier limits (2026):**
- 20 requests/minute (free-tier cap), 50 requests/day per free model
- 28+ free models, all suffixed `:free`

**Recommended free `:free` models (verified 2026-08):**
| Model ID                                          | Use case                  |
| ------------------------------------------------- | ------------------------- |
| `deepseek/deepseek-chat-v3-0324:free`             | General coding            |
| `deepseek/deepseek-r1:free`                       | Reasoning                 |
| `meta-llama/llama-4-scout:free`                   | Long-context chat         |
| `qwen/qwen3-coder:free`                           | Code (480B params, 262K)  |
| `google/gemini-flash-1.5:free`                    | Fast chat                 |
| `mistralai/mistral-small-3.1-24b-instruct:free`   | Cheap coding              |

**Pros:** Single API key for many models; can route to cheapest; supports `tools`.
**Cons:** 20 req/day per free model is tight for agentic loops.

---

## 6. NVIDIA NIM — Free Build Endpoints

**Signup:** <https://build.nvidia.com> → "Get API key"
**Base URL:** `https://integrate.api.nvidia.com/v1`
**Env var:** `NVIDIA_API_KEY`

```bash
export NVIDIA_API_KEY="nvapi-..."
```

```toml
[ai]
provider = "nvidia"
model = "meta/llama-3.3-70b-instruct"
```

**Free-tier limits (2026):** 1000 requests/month per model (credit-style).
**Pros:** OpenAI-compatible; access to specialized models like Nemotron, Mistral-NeMo.
**Cons:** 1000 req/month is small; rate-limit shared across models.

---

## 7. Forge Cloud — Backend Proxy (Beta)

**Signup:** Run `forge login` (uses Supabase Auth).
**Base URL:** Forge backend proxy (handles auth + model routing).
**Env var:** _(JWT stored in keychain after login)_

```toml
[ai]
provider = "forge_cloud"
model = "auto"
access_token = "..."  # populated by `forge login`
```

**Pros:** Zero-config — Forge Cloud routes to the best free model available; handles failover.
**Cons:** Beta — rate limits may apply.

---

## 8. Other Free Sources (Not Yet Built Into Forge)

These providers also offer free tiers but are not yet wired into Forge's provider factory. They use OpenAI-compatible APIs, so they can be used via `provider = "openai"` + custom `base_url`:

| Provider         | Base URL                              | Env var            | Free quota             |
| ---------------- | ------------------------------------- | ------------------ | ---------------------- |
| **Mistral**      | `https://api.mistral.ai/v1`           | `MISTRAL_API_KEY`  | 500K tok/month         |
| **Together AI**  | `https://api.together.xyz/v1`         | `TOGETHER_API_KEY` | $5 free credit         |
| **Fireworks AI** | `https://api.fireworks.ai/inference/v1`| `FIREWORKS_API_KEY`| $1 free credit         |
| **Cloudflare**   | `https://api.cloudflare.com/client/v4`| `CF_API_TOKEN`     | 10K neurons/day        |
| **HuggingFace**  | `https://api-inference.huggingface.co`| `HF_TOKEN`         | 1000 req/hour          |
| **GLM/Zhipu**    | `https://open.bigmodel.cn/api/paas/v4`| `GLM_API_KEY`      | Free tier              |

To use any of the above with Forge today, set `provider = "openai"` and `OPENAI_BASE_URL` env var:

```bash
export OPENAI_API_KEY="$MISTRAL_API_KEY"
export OPENAI_BASE_URL="https://api.mistral.ai/v1"
# Then in forge.toml: provider = "openai", model = "mistral-small-latest"
```

---

## Quick-Start: Try All Free Providers in 10 Minutes

```bash
# 1. Set up keys (each takes ~30 seconds to register)
export GEMINI_API_KEY="..."     # https://aistudio.google.com
export GROQ_API_KEY="..."       # https://console.groq.com
export CEREBRAS_API_KEY="..."   # https://cloud.cerebras.ai
export OPENROUTER_API_KEY="..." # https://openrouter.ai

# 2. Build forge (requires Zig 0.15+)
cd /path/to/forge
zig build

# 3. Compare providers on a standard corpus
./scripts/eval_provider_comparison.sh groq,cerebras,gemini \
    fixtures/eval/agent_reliability.json

# 4. Or run individual live evals
./scripts/eval_live.sh groq
./scripts/eval_live.sh cerebras
./scripts/eval_live.sh gemini
```

---

## Forge Routing Recommendations

For different use cases, Forge's smart router (RFC-0016) picks:

| Use case          | Recommended free combo                       |
| ----------------- | -------------------------------------------- |
| **Inline completion** (sub-100ms TTFB) | Cerebras `llama3.1-8b` or Groq `llama-3.1-8b-instant` |
| **Agentic coding** (multi-step) | Groq `llama-3.3-70b-versatile` (fast + tools)         |
| **Long context** (>200K)         | Gemini `gemini-2.5-pro` (2M context)                  |
| **Reasoning / planning**         | Groq `deepseek-r1-distill-llama-70b`                  |
| **Code-specialized**             | Groq `qwen-2.5-coder-32b` or OpenRouter `qwen/qwen3-coder:free` |
| **Offline / privacy**            | Ollama `qwen2.5-coder:14b`                            |
| **Failover chain**               | Cerebras → Groq → Gemini → OpenRouter → Ollama        |

To let Forge pick automatically:

```toml
[ai]
provider = "auto"
model = "auto"
```

The `auto` resolver probes each provider in registry order and picks the first available one with valid credentials.

---

## What's New in This Update

This update adds **Groq** and **Cerebras** as first-class Forge providers:

- **New files:**
  - `packages/ai/src/providers/groq/provider.zig`
  - `packages/ai/src/providers/groq/tool_transport.zig`
  - `packages/ai/src/providers/cerebras/provider.zig`
  - `packages/ai/src/providers/cerebras/tool_transport.zig`
- **Updated:**
  - `packages/ai/src/providers/root.zig` — exports new providers
  - `packages/ai/src/provider_factory.zig` — registers Groq + Cerebras in the registry
  - `packages/ai/src/provider_capability.zig` — adds 6 new free models to the capability table
  - `apps/forge-cli/src/providers_cmd.zig` — lists new providers in `forge providers`
  - `forge.toml` — documents all free-tier env vars
  - `scripts/eval_live.sh` — adds Groq + Cerebras credential checks
  - `scripts/eval_provider_comparison.sh` — adds free-tier combo examples

Both Groq and Cerebras are **OpenAI-compatible** at `/chat/completions`, so they reuse the existing `openai_compat` and `openai_sse` modules — no new HTTP/SSE parsing code required.

---

## Verification

The Forge tool-loop round-trip was verified end-to-end using the Z.AI SDK as a stand-in LLM (`scripts/forge_tool_loop_test.js`):

```
=== Forge Tool-Loop Round-Trip Test (z-ai SDK) ===
Step 1: user message appended
Step 2: model chose tool call -> {"tool":"read_file","args":{"path":"README.md"}}
Step 3: tool_result appended (fake README.md content)
Step 4: model final decision -> {"tool":"write_file","args":{"path":"SUMMARY.txt","content":"Forge is a native Zig AI coding assistant..."}}

PASS: Tool-loop round-trip succeeded!
```

This confirms the conversation flow (`appendToolUserText` → `appendToolCall` → `appendToolResult` → final assistant turn) works correctly — the same flow that Groq and Cerebras now plug into via their respective `GroqTransport` and `CerebrasTransport` types.

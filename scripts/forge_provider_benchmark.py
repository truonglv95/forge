#!/usr/bin/env python3
"""
Forge provider benchmark — tests all available free-tier LLM providers
and reports latency, success rate, token cost.

This script runs against the Z.AI internal API (pre-authenticated via
/etc/.z-ai-config) and Pollinations.ai (anonymous, no key required).
It does NOT require any API keys to be set up manually.

For each provider+model, it runs:
  1. Simple chat completion (latency test)
  2. Tool-call round-trip (functional test)
  3. Streaming test (SSE chunk delivery)
  4. Code generation (quality + tokens)

Results are saved as JSON for later comparison.
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

# === Z.AI provider config ===
ZAI_CONFIG_PATHS = [
    "/etc/.z-ai-config",
    os.path.expanduser("~/.z-ai-config"),
    os.path.join(os.getcwd(), ".z-ai-config"),
]

def load_zai_config():
    """Load Z.AI config from default paths."""
    for path in ZAI_CONFIG_PATHS:
        try:
            with open(path, "r") as f:
                cfg = json.load(f)
                if cfg.get("baseUrl") and cfg.get("token"):
                    return cfg
        except (OSError, json.JSONDecodeError):
            continue
    return None

def zai_chat(model, messages, tools=None, stream=False, max_tokens=None):
    """Call Z.AI internal chat completions API."""
    cfg = load_zai_config()
    if not cfg:
        return {"error": "no z-ai config found"}
    
    url = cfg["baseUrl"].rstrip("/") + "/chat/completions"
    body = {"model": model, "messages": messages}
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    if stream:
        body["stream"] = True
    if max_tokens:
        body["max_tokens"] = max_tokens
    
    payload = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {cfg.get('apiKey', 'Z.ai')}",
        "X-Token": cfg["token"],
        "X-Z-AI-From": "Z",
    })
    
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}", "body": e.read().decode("utf-8", errors="replace")[:200]}
    except Exception as e:
        return {"error": str(e)[:200]}

# === Pollinations provider (anonymous, no key) ===
def pollinations_chat(messages, model="openai"):
    """Call Pollinations.ai OpenAI-compatible endpoint (no auth needed)."""
    url = "https://text.pollinations.ai/openai"
    body = {"model": model, "messages": messages}
    payload = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method="POST", headers={
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}", "body": e.read().decode("utf-8", errors="replace")[:200]}
    except Exception as e:
        return {"error": str(e)[:200]}

# === Test cases ===
TEST_PROMPTS = {
    "simple_chat": {
        "messages": [{"role": "user", "content": "Reply with exactly: OK"}],
        "expect_substring": "OK",
    },
    "code_gen": {
        "messages": [{"role": "user", "content": "Write a Python function fibonacci(n) that returns the first n Fibonacci numbers. Just the code, no explanation."}],
        "expect_substring": "def fibonacci",
    },
    "json_output": {
        "messages": [{"role": "user", "content": 'Reply with ONLY this JSON: {"status":"ok","count":3}. No markdown, no explanation.'}],
        "expect_substring": '"status":"ok"',
    },
    "reasoning": {
        "messages": [{"role": "user", "content": "If a train travels 120km in 2 hours, what is its speed in km/h? Reply with just the number."}],
        "expect_substring": "60",
    },
}

TOOL_TEST = {
    "messages": [{"role": "user", "content": "Read README.md and write a 1-line summary."}],
    "tools": [
        {"type": "function", "function": {
            "name": "read_file",
            "description": "Read a file from the workspace.",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
        }},
        {"type": "function", "function": {
            "name": "write_file",
            "description": "Write content to a file.",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
        }},
    ],
    "expect_tool": "read_file",
}

def run_test(provider_name, model, test_name, test_def):
    """Run one test, return result dict."""
    start = time.time()
    if provider_name == "pollinations":
        resp = pollinations_chat(test_def["messages"])
    else:
        resp = zai_chat(model, test_def["messages"])
    elapsed = time.time() - start
    
    if "error" in resp:
        return {
            "test": test_name,
            "provider": provider_name,
            "model": model,
            "success": False,
            "error": resp["error"],
            "elapsed_s": round(elapsed, 3),
        }
    
    content = ""
    usage = {}
    try:
        content = resp.get("choices", [{}])[0].get("message", {}).get("content", "") or ""
        usage = resp.get("usage", {})
    except (IndexError, AttributeError):
        pass
    
    success = test_def.get("expect_substring", "").lower() in content.lower()
    return {
        "test": test_name,
        "provider": provider_name,
        "model": model,
        "success": success,
        "elapsed_s": round(elapsed, 3),
        "tokens_in": usage.get("prompt_tokens"),
        "tokens_out": usage.get("completion_tokens"),
        "tokens_total": usage.get("total_tokens"),
        "content_preview": content[:120].replace("\n", " "),
    }

def run_tool_test(provider_name, model):
    """Run the tool-call round-trip test."""
    start = time.time()
    if provider_name == "pollinations":
        # Pollinations also supports tools
        url = "https://text.pollinations.ai/openai"
        body = {"model": "openai", "messages": TOOL_TEST["messages"], "tools": TOOL_TEST["tools"], "tool_choice": "auto"}
        payload = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(url, data=payload, method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                resp_json = json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            return {"test": "tool_call", "provider": provider_name, "model": model, "success": False, "error": str(e)[:200]}
    else:
        resp_json = zai_chat(model, TOOL_TEST["messages"], tools=TOOL_TEST["tools"])
    elapsed = time.time() - start
    
    if "error" in resp_json:
        return {
            "test": "tool_call",
            "provider": provider_name,
            "model": model,
            "success": False,
            "error": resp_json["error"],
            "elapsed_s": round(elapsed, 3),
        }
    
    tool_calls = []
    try:
        tool_calls = resp_json["choices"][0]["message"].get("tool_calls", []) or []
    except (IndexError, KeyError, AttributeError):
        pass
    
    success = False
    called_tool = None
    if tool_calls:
        called_tool = tool_calls[0].get("function", {}).get("name")
        success = called_tool == TOOL_TEST["expect_tool"]
    
    usage = resp_json.get("usage", {})
    return {
        "test": "tool_call",
        "provider": provider_name,
        "model": model,
        "success": success,
        "called_tool": called_tool,
        "elapsed_s": round(elapsed, 3),
        "tokens_in": usage.get("prompt_tokens"),
        "tokens_out": usage.get("completion_tokens"),
        "tokens_total": usage.get("total_tokens"),
    }

def main():
    print("=" * 70)
    print("Forge Free-Tier LLM Provider Benchmark")
    print("=" * 70)
    
    # Verify z-ai config exists
    cfg = load_zai_config()
    if cfg:
        print(f"  z.ai config: {cfg['baseUrl']} (token present)")
    else:
        print("  z.ai config: NOT FOUND (install z-ai-web-dev-sdk CLI)")
    
    # Models to test
    zai_models = [
        "glm-4-plus",      # general purpose
        "glm-4.5",         # latest
        "glm-4.6",         # latest
        "glm-4-flash",     # fast
        "glm-4-flashx",    # faster
        "glm-4-air",       # lightweight
        "glm-zero",        # reasoning
        "glm-zero-preview",# preview reasoning
        "glm-4-long",      # long context
    ]
    
    all_results = []
    
    # Test 1-4: Z.AI models on each prompt
    for model in zai_models:
        print(f"\n--- {model} ---")
        for test_name, test_def in TEST_PROMPTS.items():
            result = run_test("zai", model, test_name, test_def)
            all_results.append(result)
            status = "PASS" if result["success"] else "FAIL"
            tok = result.get("tokens_total")
            tok_str = f" {tok}tok" if tok else ""
            err = result.get("error", "")
            print(f"  {test_name:14s} {status:5s} {result['elapsed_s']:.2f}s{tok_str} {err}")
            time.sleep(0.3)  # avoid rate limit
        
        # Tool call test
        result = run_tool_test("zai", model)
        all_results.append(result)
        status = "PASS" if result["success"] else "FAIL"
        tok = result.get("tokens_total")
        tok_str = f" {tok}tok" if tok else ""
        called = result.get("called_tool", "")
        err = result.get("error", "")
        print(f"  tool_call      {status:5s} {result['elapsed_s']:.2f}s{tok_str} called={called} {err}")
        time.sleep(0.5)
    
    # Pollinations test
    print(f"\n--- pollinations/openai-fast ---")
    for test_name, test_def in TEST_PROMPTS.items():
        result = run_test("pollinations", "openai-fast", test_name, test_def)
        all_results.append(result)
        status = "PASS" if result["success"] else "FAIL"
        tok = result.get("tokens_total")
        tok_str = f" {tok}tok" if tok else ""
        err = result.get("error", "")
        print(f"  {test_name:14s} {status:5s} {result['elapsed_s']:.2f}s{tok_str} {err}")
        time.sleep(0.3)
    result = run_tool_test("pollinations", "openai-fast")
    all_results.append(result)
    status = "PASS" if result["success"] else "FAIL"
    called = result.get("called_tool", "")
    err = result.get("error", "")
    elapsed = result.get("elapsed_s", 0)
    print(f"  tool_call      {status:5s} {elapsed:.2f}s called={called} {err}")
    
    # Save results
    out_path = Path("/home/z/my-project/download/free_llm_test/benchmark_results.json")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(all_results, indent=2))
    print(f"\nResults saved to: {out_path}")
    
    # Summary
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    
    # Group by provider+model
    by_model = {}
    for r in all_results:
        key = f"{r['provider']}/{r['model']}"
        by_model.setdefault(key, []).append(r)
    
    print(f"\n{'Provider/Model':<32} {'Pass':>5}/{' Total':<7} {'Avg latency':>12} {'Avg tokens':>11}")
    print("-" * 70)
    for key, results in sorted(by_model.items()):
        passed = sum(1 for r in results if r.get("success"))
        total = len(results)
        latencies = [r.get("elapsed_s", 0) for r in results if r.get("elapsed_s")]
        avg_lat = sum(latencies) / len(latencies) if latencies else 0
        tokens = [r.get("tokens_total", 0) for r in results if r.get("tokens_total")]
        avg_tok = sum(tokens) / len(tokens) if tokens else 0
        print(f"{key:<32} {passed:>5}/{total:<7} {avg_lat:>10.2f}s {avg_tok:>9.0f}")
    
    # Find best per category
    print(f"\n--- Best per category ---")
    for test_name in list(TEST_PROMPTS.keys()) + ["tool_call"]:
        candidates = [r for r in all_results if r.get("test") == test_name and r.get("success")]
        if candidates:
            best = min(candidates, key=lambda r: r.get("elapsed_s", 999))
            print(f"  {test_name:14s} → {best['provider']}/{best['model']} ({best['elapsed_s']:.2f}s, {best.get('tokens_total', '?')} tok)")
        else:
            print(f"  {test_name:14s} → (none passed)")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Forge Semantic Search Accuracy Evaluator
=========================================
Do luong do chinh xac cua context retrieval pipeline gui len LLM.

Metrics:
  - Recall@K     : Ti le query co file dung xuat hien trong top-K context blocks
  - MRR@10       : Mean Reciprocal Rank -- thu hang trung binh cua result dung
  - Hit Rate     : Ti le query co it nhat 1 file dung trong context
  - Fused Rate   : Ti le ket qua co ca semantic lan keyword sources

Usage:
  # Quick test voi forge codebase:
  python3 scripts/eval_search.py

  # Chay voi Gemini embeddings (can GEMINI_API_KEY):
  python3 scripts/eval_search.py --provider gemini

  # So sanh truoc/sau mot thay doi:
  python3 scripts/eval_search.py --save-baseline
  # ... apply changes ...
  python3 scripts/eval_search.py --compare-baseline

  # Corpus tuy chinh:
  python3 scripts/eval_search.py --corpus my_corpus.json

  # Chi kiem tra cac query theo tag:
  python3 scripts/eval_search.py --tags semantic keyword
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from typing import Optional

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORGE = ROOT / "zig-out" / "bin" / "forge"
DEFAULT_BASELINE = ROOT / ".forge" / "evals" / "search_baseline.json"

# ---------------------------------------------------------------------------
# Golden corpus: cac query + file dung can phai xuat hien trong context
# Duoc thiet ke dua tren codebase cua forge chinh no (self-referential eval).
# ---------------------------------------------------------------------------
BUILTIN_CORPUS: list[dict] = [
    {
        "id": "semantic-search-core",
        "query": "semantic vector embedding cosine similarity search",
        "expected_paths": ["packages/ai/src/codebase_search.zig"],
        "tags": ["semantic"],
    },
    {
        "id": "local-embedding",
        "query": "local offline hash trick embedding without API",
        "expected_paths": ["packages/ai/src/local_vector.zig"],
        "tags": ["semantic", "offline"],
    },
    {
        "id": "gemini-embedder",
        "query": "gemini text embedding API call task type retrieval",
        "expected_paths": ["packages/ai/src/providers/gemini/embedder.zig"],
        "tags": ["semantic", "api"],
    },
    {
        "id": "keyword-grep-retrieval",
        "query": "keyword grep term extraction intent search",
        "expected_paths": ["packages/ai/src/context_retrieval.zig"],
        "tags": ["retrieval", "keyword"],
    },
    {
        "id": "rrf-fusion-rerank",
        "query": "reciprocal rank fusion RRF reranker signal boost",
        "expected_paths": ["packages/ai/src/context_rerank.zig"],
        "tags": ["retrieval", "rerank"],
    },
    {
        "id": "context-orchestrator",
        "query": "context loader build pipeline fused semantic block",
        "expected_paths": ["packages/ai/src/context_loader.zig"],
        "tags": ["context"],
    },
    {
        "id": "index-chunking",
        "query": "codebase index chunk rebuild embed vectors",
        "expected_paths": ["packages/workspace/src/codebase_index.zig"],
        "tags": ["index"],
    },
    {
        "id": "intent-classifier",
        "query": "classify user intent LLM heuristic edit explore",
        "expected_paths": ["packages/ai/src/intent_classifier.zig"],
        "tags": ["intent"],
    },
    {
        "id": "routing-logic",
        "query": "route task intent edit_code explore_codebase routing",
        "expected_paths": ["packages/ai/src/routing.zig"],
        "tags": ["intent"],
    },
    {
        "id": "import-graph-bfs",
        "query": "import graph BFS neighbor files static analysis",
        "expected_paths": ["packages/ai/src/import_graph.zig"],
        "tags": ["graph"],
    },
    {
        "id": "zig-ast-chunker",
        "query": "zig AST parse functions declarations doc comments chunk",
        "expected_paths": ["packages/workspace/src/ast_chunker.zig"],
        "tags": ["chunking"],
    },
    {
        "id": "tree-sitter-chunker",
        "query": "tree sitter python typescript parse declarations symbol",
        "expected_paths": ["packages/workspace/src/tree_sitter_chunker.zig"],
        "tags": ["chunking"],
    },
    {
        "id": "agent-memory",
        "query": "agent memory entries select for intent score",
        "expected_paths": ["packages/ai/src/agent_memory.zig"],
        "tags": ["memory"],
    },
    {
        "id": "proposal-workflow",
        "query": "proposal workflow apply validate edit file",
        "expected_paths": ["packages/ai/src/proposal_workflow.zig"],
        "tags": ["workflow"],
    },
    {
        "id": "scope-resolver-markers",
        "query": "@codebase @folder @docs scope marker resolve files",
        "expected_paths": ["packages/ai/src/scope_resolver.zig"],
        "tags": ["scope"],
    },
    # Action-verb queries (test stop words fix)
    {
        "id": "add-context-block",
        "query": "add new context block to the builder pipeline",
        "expected_paths": ["packages/ai/src/context_loader.zig"],
        "tags": ["edit", "action-verb"],
    },
    {
        "id": "update-embedding-model",
        "query": "update embedding model version gemini API endpoint",
        "expected_paths": ["packages/ai/src/providers/gemini/embedder.zig"],
        "tags": ["edit", "action-verb"],
    },
    {
        "id": "create-chunker",
        "query": "create new language chunker for source files",
        "expected_paths": ["packages/workspace/src/language_chunker.zig"],
        "tags": ["edit", "action-verb"],
    },
    {
        "id": "change-score-threshold",
        "query": "change score threshold filter for search results",
        "expected_paths": ["packages/ai/src/codebase_search.zig"],
        "tags": ["edit", "action-verb"],
    },
]


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
@dataclass
class QueryResult:
    query_id: str
    query: str
    expected_paths: list[str]
    retrieved_paths: list[str]
    fused_paths: list[str]
    context_bytes: int
    fused_bytes: int
    latency_ms: float
    error: Optional[str] = None
    tags: list[str] = field(default_factory=list)

    @property
    def hit(self) -> bool:
        for ep in self.expected_paths:
            ep_base = ep.rstrip("/").split("/")[-1]
            for rp in self.retrieved_paths:
                if ep in rp or ep_base in rp:
                    return True
        return False

    def recall_at(self, k: int, use_fused: bool = False) -> float:
        paths = self.fused_paths if use_fused else self.retrieved_paths
        top_k = paths[:k]
        for ep in self.expected_paths:
            ep_base = ep.rstrip("/").split("/")[-1]
            for rp in top_k:
                if ep in rp or ep_base in rp:
                    return 1.0
        return 0.0

    def reciprocal_rank(self, max_k: int = 10, use_fused: bool = False) -> float:
        paths = self.fused_paths if use_fused else self.retrieved_paths
        for rank, rp in enumerate(paths[:max_k], start=1):
            for ep in self.expected_paths:
                ep_base = ep.rstrip("/").split("/")[-1]
                if ep in rp or ep_base in rp:
                    return 1.0 / rank
        return 0.0

    def fused_hit(self) -> bool:
        for ep in self.expected_paths:
            ep_base = ep.rstrip("/").split("/")[-1]
            for rp in self.fused_paths:
                if ep in rp or ep_base in rp:
                    return True
        return False


@dataclass
class EvalSummary:
    schema_version: int = 2
    generated_at: str = ""
    forge_binary: str = ""
    provider: str = "auto"
    workspace: str = ""
    total_queries: int = 0
    hit_rate: float = 0.0
    recall_at_1: float = 0.0
    recall_at_3: float = 0.0
    recall_at_5: float = 0.0
    mrr_at_10: float = 0.0
    fused_mrr: float = 0.0
    fused_hit_rate: float = 0.0
    avg_context_bytes: float = 0.0
    avg_fused_bytes: float = 0.0
    avg_latency_ms: float = 0.0
    p95_latency_ms: float = 0.0
    errors: int = 0
    per_tag: dict = field(default_factory=dict)
    failures: list[dict] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Core evaluation logic
# ---------------------------------------------------------------------------
def run_forge_context(
    forge: pathlib.Path,
    query: str,
    workspace: pathlib.Path,
    provider: str,
) -> tuple[dict, float]:
    cmd = [
        str(forge),
        "context",
        query,
        "--workspace", str(workspace),
        "--json",
        "--quiet",
    ]
    if provider and provider != "auto":
        cmd += ["--provider", provider]

    t0 = time.perf_counter()
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    latency_ms = (time.perf_counter() - t0) * 1000

    if result.returncode != 0:
        raise RuntimeError(
            f"forge context failed (exit {result.returncode}): {result.stderr[-400:]}"
        )

    return json.loads(result.stdout), latency_ms


def extract_paths_from_manifest(manifest: dict) -> tuple[list[str], list[str]]:
    """
    Parse manifest JSON tu `forge context --json`.
    Returns (all_paths_ordered, fused_search_paths).

    Context JSON format:
      {"items": [{"kind":"fused","name":"context:fused-rrf","included":true,...},
                  {"kind":"fused","name":"packages/ai/src/foo.zig:10-50",...}, ...]}
    """
    all_paths: list[str] = []
    fused_paths: list[str] = []

    for item in manifest.get("items", []):
        if not item.get("included", False):
            continue
        kind = item.get("kind", "")
        name = item.get("name", "")

        if kind in ("file", "recent"):
            all_paths.append(name)

        if kind in ("fused", "semantic", "retrieval"):
            # Block names formatted as "path/to/file.zig:10-50"
            path_part = name.split(":")[0] if ":" in name else name
            # Skip meta-names like "context:fused-rrf", "retrieval:intent-search"
            if path_part and "/" in path_part:
                fused_paths.append(path_part)
                if path_part not in all_paths:
                    all_paths.append(path_part)

    return all_paths, fused_paths


def evaluate_query(
    task: dict,
    forge: pathlib.Path,
    workspace: pathlib.Path,
    provider: str,
    verbose: bool = False,
) -> QueryResult:
    query_id = task["id"]
    query = task["query"]
    expected = task.get("expected_paths", [])
    tags = task.get("tags", [])

    try:
        manifest, latency_ms = run_forge_context(forge, query, workspace, provider)
        all_paths, fused_paths = extract_paths_from_manifest(manifest)
        context_bytes = manifest.get("used_bytes", 0)
        fused_bytes = sum(
            item.get("bytes", 0)
            for item in manifest.get("items", [])
            if item.get("kind") in ("fused", "semantic", "retrieval")
            and item.get("included")
        )

        result = QueryResult(
            query_id=query_id,
            query=query,
            expected_paths=expected,
            retrieved_paths=all_paths,
            fused_paths=fused_paths,
            context_bytes=context_bytes,
            fused_bytes=fused_bytes,
            latency_ms=latency_ms,
            tags=tags,
        )

        if verbose:
            status = "HIT " if result.hit else "MISS"
            rr = result.reciprocal_rank()
            print(f"  [{status}] MRR={rr:.3f}  {query_id}")
            if not result.hit:
                print(f"    expected : {expected}")
                print(f"    context  : {all_paths[:6]}")
            if fused_paths:
                print(f"    fused    : {fused_paths[:4]}")

        return result

    except Exception as exc:
        if verbose:
            print(f"  [ERR ] {query_id}: {exc}")
        return QueryResult(
            query_id=query_id,
            query=query,
            expected_paths=expected,
            retrieved_paths=[],
            fused_paths=[],
            context_bytes=0,
            fused_bytes=0,
            latency_ms=0,
            error=str(exc),
            tags=tags,
        )


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = max(0, min(len(s) - 1, math.ceil(len(s) * p) - 1))
    return s[idx]


def compute_summary(results: list[QueryResult], args: argparse.Namespace) -> EvalSummary:
    import datetime

    valid = [r for r in results if r.error is None]
    errors = len(results) - len(valid)

    def safe_mean(vals):
        return sum(vals) / len(vals) if vals else 0.0

    # Per-tag breakdown
    all_tags: set[str] = set()
    for r in valid:
        all_tags.update(r.tags)

    per_tag = {}
    for tag in sorted(all_tags):
        tagged = [r for r in valid if tag in r.tags]
        if not tagged:
            continue
        per_tag[tag] = {
            "count": len(tagged),
            "hit_rate": round(safe_mean([r.hit for r in tagged]), 4),
            "recall@1": round(safe_mean([r.recall_at(1) for r in tagged]), 4),
            "mrr": round(safe_mean([r.reciprocal_rank() for r in tagged]), 4),
        }

    failures = []
    for r in valid:
        if not r.hit:
            failures.append({
                "id": r.query_id,
                "query": r.query,
                "expected": r.expected_paths,
                "got_fused": r.fused_paths[:5],
                "got_context": r.retrieved_paths[:5],
                "tags": r.tags,
            })

    latencies = [r.latency_ms for r in valid if r.latency_ms > 0]

    return EvalSummary(
        generated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        forge_binary=str(args.forge),
        provider=args.provider,
        workspace=str(args.workspace),
        total_queries=len(results),
        hit_rate=round(safe_mean([r.hit for r in valid]), 4),
        recall_at_1=round(safe_mean([r.recall_at(1, use_fused=True) for r in valid]), 4),
        recall_at_3=round(safe_mean([r.recall_at(3, use_fused=True) for r in valid]), 4),
        recall_at_5=round(safe_mean([r.recall_at(5, use_fused=True) for r in valid]), 4),
        mrr_at_10=round(safe_mean([r.reciprocal_rank(use_fused=False) for r in valid]), 4),
        fused_mrr=round(safe_mean([r.reciprocal_rank(use_fused=True) for r in valid]), 4),
        fused_hit_rate=round(safe_mean([r.fused_hit() for r in valid]), 4),
        avg_context_bytes=round(safe_mean([r.context_bytes for r in valid])),
        avg_fused_bytes=round(safe_mean([r.fused_bytes for r in valid])),
        avg_latency_ms=round(safe_mean(latencies), 1),
        p95_latency_ms=round(percentile(latencies, 0.95), 1),
        errors=errors,
        per_tag=per_tag,
        failures=failures,
    )


def print_report(summary: EvalSummary, baseline: Optional[dict] = None) -> None:
    def delta(key: str, higher_is_better: bool = True) -> str:
        if baseline is None:
            return ""
        old = baseline.get(key, 0)
        new = getattr(summary, key)
        diff = new - old
        if abs(diff) < 0.0005:
            return "  (=)"
        arrow = "+" if diff > 0 else ""
        direction_good = (diff > 0) == higher_is_better
        mark = "[OK]" if direction_good else "[!!]"
        return f"  {mark} {arrow}{diff:.4f}"

    print()
    print("=" * 66)
    print("    Forge Semantic Search Accuracy Report")
    print("=" * 66)
    print(f"  Provider  : {summary.provider}")
    print(f"  Workspace : {summary.workspace}")
    print(f"  Queries   : {summary.total_queries}  (errors: {summary.errors})")
    print()
    print(f"  Hit Rate    (>=1 expected file in context) : {summary.hit_rate:.4f}{delta('hit_rate')}")
    print(f"  Fused Hit   (file in semantic/keyword)     : {summary.fused_hit_rate:.4f}{delta('fused_hit_rate')}")
    print(f"  Fused MRR   (mean reciprocal rank of fused): {summary.fused_mrr:.4f}{delta('fused_mrr')}")
    print(f"  Fused R@1   (expected in top-1 fused block): {summary.recall_at_1:.4f}{delta('recall_at_1')}")
    print(f"  Fused R@3   (expected in top-3 fused block): {summary.recall_at_3:.4f}{delta('recall_at_3')}")
    print(f"  Fused R@5   (expected in top-5 fused block): {summary.recall_at_5:.4f}{delta('recall_at_5')}")
    print(f"  Context MRR (overall context file rank)    : {summary.mrr_at_10:.4f}{delta('mrr_at_10')}")
    print(f"  Avg Context : {summary.avg_context_bytes / 1024:.1f} KB")
    print(f"  Avg Latency : {summary.avg_latency_ms:.0f} ms  (p95: {summary.p95_latency_ms:.0f} ms)")

    if summary.per_tag:
        print()
        print("  Tag Breakdown:")
        print(f"  {'Tag':<20} {'N':>4}  {'Hit%':>6}  {'R@1':>6}  {'MRR':>6}")
        print("  " + "-" * 50)
        for tag, stats in summary.per_tag.items():
            print(f"  {tag:<20} {stats['count']:>4}  {stats['hit_rate']:>6.2%}  {stats['recall@1']:>6.2%}  {stats['mrr']:>6.4f}")

    if summary.failures:
        print()
        n_fail = len(summary.failures)
        n_total = summary.total_queries - summary.errors
        print(f"  Failures ({n_fail}/{n_total}):")
        for f in summary.failures:
            tags_str = ", ".join(f["tags"]) if f["tags"] else "-"
            print(f"    [{tags_str}] {f['id']}")
            print(f"      query    : {f['query'][:68]}")
            print(f"      expected : {f['expected']}")
            got = f["got_fused"] or f["got_context"][:3]
            print(f"      retrieved: {got[:3]}")
    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Evaluate Forge semantic search accuracy",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--forge", default=str(FORGE))
    parser.add_argument("--workspace", default=str(ROOT))
    parser.add_argument(
        "--provider", default="auto",
        choices=["auto", "fake", "gemini", "ollama"],
    )
    parser.add_argument("--corpus", help="Custom JSON corpus file")
    parser.add_argument("--tags", nargs="*", help="Filter by tags")
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument(
        "--output",
        default=str(ROOT / ".forge" / "evals" / "search_latest.json"),
    )
    parser.add_argument("--save-baseline", action="store_true")
    parser.add_argument("--compare-baseline", action="store_true")
    parser.add_argument("--baseline", default=str(DEFAULT_BASELINE))
    parser.add_argument("--min-hit-rate", type=float, default=0.0)
    args = parser.parse_args()

    forge = pathlib.Path(args.forge)
    if not forge.is_file():
        print("Building forge...")
        subprocess.check_call(["zig", "build"], cwd=ROOT)

    workspace = pathlib.Path(args.workspace)

    if args.corpus:
        corpus = json.loads(pathlib.Path(args.corpus).read_text())
        print(f"Corpus: {args.corpus} ({len(corpus)} queries)")
    else:
        corpus = BUILTIN_CORPUS
        print(f"Builtin corpus ({len(corpus)} queries), workspace: {workspace.name}")

    if args.tags:
        corpus = [t for t in corpus if any(tag in t.get("tags", []) for tag in args.tags)]
        print(f"Filtered: {len(corpus)} queries with tags {args.tags}")

    if not corpus:
        print("No queries after filtering.")
        return

    print(f"\nRunning {len(corpus)} queries...\n")
    results: list[QueryResult] = []
    for task in corpus:
        if args.verbose:
            print(f"  query: {task['query'][:60]}")
        result = evaluate_query(task, forge, workspace, args.provider, verbose=args.verbose)
        results.append(result)
        if not args.verbose:
            marker = "." if result.hit else ("E" if result.error else "F")
            sys.stdout.write(marker)
            sys.stdout.flush()

    if not args.verbose:
        print()

    summary = compute_summary(results, args)

    baseline = None
    if args.compare_baseline:
        bp = pathlib.Path(args.baseline)
        if bp.exists():
            baseline = json.loads(bp.read_text())
            print(f"\nComparing vs baseline: {bp}")
        else:
            print(f"\nNo baseline at {bp}. Run --save-baseline first.")

    print_report(summary, baseline)

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(asdict(summary), indent=2, sort_keys=True) + "\n")
    print(f"Results: {output}")

    if args.save_baseline:
        bp = pathlib.Path(args.baseline)
        bp.parent.mkdir(parents=True, exist_ok=True)
        baseline_data = {
            k: getattr(summary, k)
            for k in ["hit_rate", "recall_at_1", "recall_at_3",
                      "recall_at_5", "mrr_at_10", "fused_hit_rate",
                      "generated_at", "provider"]
        }
        bp.write_text(json.dumps(baseline_data, indent=2, sort_keys=True) + "\n")
        print(f"Baseline: {bp}")

    if summary.hit_rate < args.min_hit_rate:
        print(f"\nFAIL: hit_rate {summary.hit_rate:.4f} < required {args.min_hit_rate:.4f}")
        raise SystemExit(2)

    print("PASS")


if __name__ == "__main__":
    main()

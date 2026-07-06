# AI Reliability Evaluation

Forge evaluates agent outcomes, not merely successful model responses. Each
task runs in a fresh workspace and records command success, proposal validity,
transaction apply, filesystem postconditions, tool steps, repair attempts,
provider-reported tokens, and wall-clock latency.

## Deterministic baseline

```bash
zig build
./scripts/eval_reliability.sh \
  --provider fake \
  --min-success-rate 0.66 \
  --output .forge/evals/fake.jsonl
```

The fake baseline intentionally scores 2/3: it proves the evaluator rejects a
valid proposal that does not satisfy the requested file postcondition.

## Live provider trial

```bash
./scripts/eval_reliability.sh \
  --provider gemini \
  --model <model> \
  --repeat 3 \
  --output .forge/evals/gemini.jsonl
```

Ollama uses the same command with `--provider ollama`. Live trials require the
provider credentials/runtime and are never part of `zig build test`.

## Regression gate

```bash
./scripts/eval_reliability.sh \
  --provider gemini \
  --baseline .forge/evals/baseline.summary.json \
  --max-success-regression 0.05 \
  --output .forge/evals/candidate.jsonl
```

The command exits with code 2 if success falls below `--min-success-rate` or
regresses beyond the allowed delta. JSONL retains per-task evidence; the sibling
`.summary.json` contains aggregate rates, p50/p95 latency, commit, and timestamp.

`reported_tokens` is the usage exposed by the provider after the run. Some
providers currently report only their latest request rather than cumulative
multi-turn usage, so the metric is explicitly named rather than presented as a
complete cost figure.

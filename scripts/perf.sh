#!/usr/bin/env bash

# Forge performance harness.
# Builds once, creates deterministic reference corpora, runs direct-binary
# timings, and writes JSONL for regression tracking.

set -euo pipefail

cd "$(dirname "$0")/.."

OPTIMIZE="${FORGE_OPTIMIZE:-Debug}"
OUT_DIR="${FORGE_PERF_OUT_DIR:-zig-out/perf}"
CORPUS_ROOT="${FORGE_PERF_CORPUS:-zig-out/perf-corpus}"
PERF_HOME="${FORGE_PERF_HOME:-$OUT_DIR/home}"
if [[ "$OUT_DIR" != /* ]]; then OUT_DIR="$PWD/$OUT_DIR"; fi
if [[ "$CORPUS_ROOT" != /* ]]; then CORPUS_ROOT="$PWD/$CORPUS_ROOT"; fi
if [[ "$PERF_HOME" != /* ]]; then PERF_HOME="$PWD/$PERF_HOME"; fi
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
MACHINE="$(uname -m -v | tr '"' "'")"
RESULTS="$OUT_DIR/perf-$TIMESTAMP.jsonl"

mkdir -p "$OUT_DIR" "$CORPUS_ROOT" "$PERF_HOME"
export FORGE_HOME="$PERF_HOME"

log() {
  printf '%s\n' "$*" >&2
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

make_corpus() {
  local name="$1"
  local files="$2"
  local lines="$3"
  local dir="$CORPUS_ROOT/$name"
  local marker="$dir/.forge-perf-corpus"

  if [[ -f "$marker" && -f "$dir/forge.toml" ]]; then
    return
  fi

  rm -rf "$dir"
  mkdir -p "$dir/src" "$dir/packages/core" "$dir/packages/ui" "$dir/docs"
  {
    printf '[project]\n'
    printf 'name = "forge-perf-%s"\n\n' "$name"
    printf '[ai]\n'
    printf 'embedding_provider = "local"\n'
  } > "$dir/forge.toml"

  local i line target subdir symbol
  i=0
  while [[ "$i" -lt "$files" ]]; do
    case $((i % 4)) in
      0) subdir="src" ;;
      1) subdir="packages/core" ;;
      2) subdir="packages/ui" ;;
      *) subdir="docs" ;;
    esac
    target="$dir/$subdir/file_$i.zig"
    symbol="forgePerfSymbol$i"
    {
      printf 'const std = @import("std");\n'
      printf 'pub fn %s(input: usize) usize {\n' "$symbol"
      printf '    var acc: usize = input;\n'
      line=0
      while [[ "$line" -lt "$lines" ]]; do
        printf '    acc +%%= %d; // std.testing searchable_token_%d forge_context\n' "$line" "$((line % 17))"
        line=$((line + 1))
      done
      printf '    return acc;\n'
      printf '}\n'
    } > "$target"
    i=$((i + 1))
  done

  printf 'forge perf corpus: %s files=%s lines=%s\n' "$name" "$files" "$lines" > "$marker"
}

run_case() {
  local name="$1"
  local workspace="$2"
  shift 2

  local tmp_time stdout_file
  tmp_time="$(mktemp)"
  stdout_file="$(mktemp)"

  set +e
  /usr/bin/time -l -o "$tmp_time" ./zig-out/bin/forge "$@" --workspace "$workspace" > "$stdout_file" 2>&1
  local exit_code=$?
  set -e

  local real_s rss_bytes peak_bytes
  real_s="$(awk '/ real / {print $1; exit}' "$tmp_time")"
  rss_bytes="$(awk '/maximum resident set size/ {print $1; exit}' "$tmp_time")"
  peak_bytes="$(awk '/peak memory footprint/ {print $1; exit}' "$tmp_time")"
  : "${real_s:=0}"
  : "${rss_bytes:=0}"
  : "${peak_bytes:=0}"

  local command
  command="$(json_escape "$*")"
  printf '{"timestamp":"%s","commit":"%s","machine":"%s","optimize":"%s","case":"%s","workspace":"%s","command":"%s","real_s":%s,"max_rss_bytes":%s,"peak_memory_bytes":%s,"exit_code":%s}\n' \
    "$TIMESTAMP" "$COMMIT" "$MACHINE" "$OPTIMIZE" "$name" "$workspace" "$command" "$real_s" "$rss_bytes" "$peak_bytes" "$exit_code" >> "$RESULTS"

  rm -f "$tmp_time" "$stdout_file"
  return 0
}

run_case_env() {
  local name="$1"
  local workspace="$2"
  local env_name="$3"
  local env_value="$4"
  shift 4

  local tmp_time stdout_file
  tmp_time="$(mktemp)"
  stdout_file="$(mktemp)"

  set +e
  env "$env_name=$env_value" /usr/bin/time -l -o "$tmp_time" ./zig-out/bin/forge "$@" --workspace "$workspace" > "$stdout_file" 2>&1
  local exit_code=$?
  set -e

  local real_s rss_bytes peak_bytes
  real_s="$(awk '/ real / {print $1; exit}' "$tmp_time")"
  rss_bytes="$(awk '/maximum resident set size/ {print $1; exit}' "$tmp_time")"
  peak_bytes="$(awk '/peak memory footprint/ {print $1; exit}' "$tmp_time")"
  : "${real_s:=0}"
  : "${rss_bytes:=0}"
  : "${peak_bytes:=0}"

  local command env_pair
  command="$(json_escape "$*")"
  env_pair="$(json_escape "$env_name=$env_value")"
  printf '{"timestamp":"%s","commit":"%s","machine":"%s","optimize":"%s","case":"%s","workspace":"%s","command":"%s","env":"%s","real_s":%s,"max_rss_bytes":%s,"peak_memory_bytes":%s,"exit_code":%s}\n' \
    "$TIMESTAMP" "$COMMIT" "$MACHINE" "$OPTIMIZE" "$name" "$workspace" "$command" "$env_pair" "$real_s" "$rss_bytes" "$peak_bytes" "$exit_code" >> "$RESULTS"

  rm -f "$tmp_time" "$stdout_file"
  return 0
}

log "Building Forge ($OPTIMIZE)"
zig build -Doptimize="$OPTIMIZE" >/dev/null

log "Preparing corpora in $CORPUS_ROOT"
make_corpus small 128 12
make_corpus medium 1500 24
if [[ "${FORGE_PERF_LARGE:-0}" == "1" ]]; then
  make_corpus large 8000 36
fi

log "Writing JSONL results to $RESULTS"

run_case cli_inspect_fixtures ./fixtures inspect
run_case cli_search_fixtures ./fixtures search std.testing
run_case cli_inspect_small "$CORPUS_ROOT/small" inspect
run_case cli_search_small "$CORPUS_ROOT/small" search searchable_token_7
run_case cli_inspect_medium "$CORPUS_ROOT/medium" inspect
run_case cli_search_medium "$CORPUS_ROOT/medium" search searchable_token_7

if [[ "${FORGE_PERF_COLD_INDEX:-1}" == "1" ]]; then
  rm -rf "$PERF_HOME/sessions"
fi
run_case cli_index_status_medium "$CORPUS_ROOT/medium" index status

if [[ "${FORGE_PERF_INDEX:-1}" == "1" ]]; then
  run_case cli_index_build_small "$CORPUS_ROOT/small" index --json
  run_case cli_index_build_medium "$CORPUS_ROOT/medium" index --json
  run_case cli_index_warm_medium "$CORPUS_ROOT/medium" index --json
fi

run_case_env cli_context_medium "$CORPUS_ROOT/medium" FORGE_SKIP_INDEX 1 context "find searchable token" --json

if [[ "${FORGE_PERF_LARGE:-0}" == "1" ]]; then
  run_case cli_inspect_large "$CORPUS_ROOT/large" inspect
  run_case cli_search_large "$CORPUS_ROOT/large" search searchable_token_7
  run_case cli_index_status_large "$CORPUS_ROOT/large" index status
  if [[ "${FORGE_PERF_INDEX:-1}" == "1" ]]; then
    run_case cli_index_build_large "$CORPUS_ROOT/large" index --json
  fi
fi

log "Done. Results:"
cat "$RESULTS"

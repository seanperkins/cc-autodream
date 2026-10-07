#!/bin/bash
# The production L1 call, for the model benchmark. Sourced by bench/run-one-l1*.sh.
#
# The argv comes from the claude adapter (adapters/claude/adapter.sh l1-argv), the command
# bin/run.sh starts for a nightly worker, so the benchmark measures what production runs and a
# change to the adapter reaches both. The prompt framing mirrors the worker block in bin/run.sh
# (l1_attempt); bench/tests/l1_prod.sh pins the two together.
#
# No apostrophes in any function body a caller embeds inside a single-quoted `bash -c '...'`.

: "${BENCH_REPO:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# l1_build_prompt TRANSCRIPT OUTPUT TRIAGE_MD [STATS_JSON] -> the L1 prompt on stdout.
# The paths are passed as LITERAL data so the worker hands them straight to Read/Write and
# never tries to $-expand them.
l1_build_prompt() {
  printf 'Session transcript to analyze (literal absolute path): %s\n' "$1"
  printf 'Write your findings JSON to this literal absolute path: %s\n\n' "$2"
  cat "$3"
  if [ -n "${4:-}" ] && [ -s "$4" ]; then
    printf '\n## Precomputed session stats (authoritative — copy these into your output)\n\n```json\n'
    cat "$4"
    printf '\n```\n'
  fi
}

# l1_argv MODEL EFFORT -> the adapter's NUL-delimited L1 argv. An empty EFFORT drops --effort
# (the adapter would otherwise apply its own default), so a candidate with no effort really has none.
l1_argv() {
  AUTODREAM_L1_EFFORT_CLAUDE="${2:-}" "$BENCH_REPO/adapters/claude/adapter.sh" l1-argv "$1"
}

# l1_system_prompt -> the worker system prompt, read back from the adapter's argv.
l1_system_prompt() {
  local a prev=""
  while IFS= read -r -d '' a; do
    [ "$prev" = "--append-system-prompt" ] && { printf '%s' "$a"; return 0; }
    prev="$a"
  done < <(l1_argv "bench-probe" "")
  return 1
}

# l1_invoke_claude MODEL EFFORT OUTPUT_FORMAT  (prompt on stdin)
# EFFORT and OUTPUT_FORMAT are omitted from the argv when empty. CLAUDE_BIN picks the binary.
l1_invoke_claude() {
  local model="$1" effort="${2:-}" fmt="${3:-}" a
  local -a argv=()
  while IFS= read -r -d '' a; do argv+=("$a"); done < <(l1_argv "$model" "$effort")
  [ "${#argv[@]}" -gt 0 ] || return 70
  [ -n "$fmt" ] && argv+=(--output-format "$fmt")
  "${argv[@]}"
}
